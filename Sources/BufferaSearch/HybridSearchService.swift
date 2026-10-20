import Foundation
import BufferaCore
import BufferaModels

public struct SemanticQuery: Sendable {
    public let vector: [Float]
    public let identity: EmbeddingIndexIdentity

    public init(vector: [Float], identity: EmbeddingIndexIdentity) {
        self.vector = vector
        self.identity = identity
    }
}

public struct HybridSearchResponse: Sendable {
    public let rows: [ClipSummary]
    public let total: Int
    public let mode: ActualSearchMode
    public let fallbackReason: String?
    public let progress: EmbeddingProgress?
}

/// Shared by the app and MCP. Inference happens before opening a database snapshot.
/// This service never writes the history, model preferences, or downloaded files.
public actor HybridSearchService {
    private struct PageKey: Equatable {
        let database: String
        let query: String
        let kind: String?
        let source: String?
        let favorites: Bool
        let remote: Bool
        let concealed: Bool
        let excludesConcealed: Bool
        let from: Date?
        let until: Date?

        init(databaseURL: URL, filter: SearchFilter) {
            database = databaseURL.path; query = filter.query
            kind = filter.kind?.rawValue; source = filter.source
            favorites = filter.favoritesOnly; remote = filter.remoteOnly
            concealed = filter.concealedOnly; excludesConcealed = filter.excludesConcealed
            from = filter.from; until = filter.until
        }
    }

    private struct CachedVector {
        let text: String
        let value: SemanticQuery
    }

    private let runtime: EmbeddingRuntime?
    private let ownsRuntime: Bool
    private let access: LocalModelReadAccess?
    private let queryProvider: (@Sendable (String) async throws -> SemanticQuery)?
    private var cachedVector: CachedVector?
    private var pageKey: PageKey?
    private var pageIdentity: EmbeddingIndexIdentity?
    private var semanticIDs: [Int64]?

    public init(modelRootURL: URL, bundleURL: URL = Bundle.main.bundleURL,
                embeddingRuntime: EmbeddingRuntime? = nil) {
        runtime = embeddingRuntime ?? EmbeddingRuntime(modelRootURL: modelRootURL, bundleURL: bundleURL)
        ownsRuntime = embeddingRuntime == nil
        access = LocalModelReadAccess(rootURL: modelRootURL)
        queryProvider = nil
    }

    /// Test boundary supplies deterministic vectors without enabling a real model or touching user data.
    public init(queryProvider: @escaping @Sendable (String) async throws -> SemanticQuery) {
        runtime = nil; access = nil
        ownsRuntime = false
        self.queryProvider = queryProvider
    }

    public func search(databaseURL: URL, filter: SearchFilter, mode: HistorySearchMode = .automatic,
                       limit: Int = 150, offset: Int = 0) async throws -> HybridSearchResponse {
        try Task.checkCancellation()
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode != .literal, !query.isEmpty, !filter.concealedOnly else {
            return try literal(databaseURL, filter: filter, limit: limit, offset: offset)
        }

        let semantic: SemanticQuery
        do {
            if let access, let runtime {
                let installed = try access.enabledEmbedding()
                // No GPU load is needed until there are compatible document vectors.
                let existing = try HistoryStore(url: databaseURL, mode: .readOnly)
                let ready = try existing.withReadSnapshot {
                    let progress = try existing.embeddingProgress()
                    return (try existing.embeddingIndexIdentity()?.fingerprint == installed.modelKey,
                            progress)
                }
                guard ready.0, ready.1.complete > 0 else {
                    return try literal(databaseURL, filter: filter, limit: limit, offset: offset,
                                       reason: "Индекс ещё готовится. Пока ищем по словам.")
                }
                if let cache = cachedVector, cache.text == query,
                   cache.value.identity.fingerprint == installed.modelKey {
                    semantic = cache.value
                } else {
                    let output = try await runtime.embed([query], kind: .query)
                    guard let vector = output.first?.vectors.first else {
                        throw SearchFailure.invalidEmbedding
                    }
                    semantic = SemanticQuery(vector: vector,
                        identity: EmbeddingIndexIdentity(fingerprint: installed.modelKey,
                                                         dimensions: EmbeddingConfiguration.dimensions))
                }
                // Disabling/removing/changing a model while inference runs wins over its result.
                guard try access.enabledEmbedding().modelKey == semantic.identity.fingerprint else {
                    throw SearchFailure.modelChanged
                }
            } else if let queryProvider {
                semantic = try await queryProvider(query)
            } else {
                throw SearchFailure.modelChanged
            }
            try Task.checkCancellation()
            cachedVector = CachedVector(text: query, value: semantic)
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            // Unloading a model cancels its worker without cancelling the UI request.
            return try literal(databaseURL, filter: filter, limit: limit, offset: offset,
                               reason: "Поиск по смыслу остановлен. Пока ищем по словам.")
        } catch {
            cachedVector = nil; semanticIDs = nil
            return try literal(databaseURL, filter: filter, limit: limit, offset: offset,
                               reason: error.localizedDescription)
        }

        let store = try HistoryStore(url: databaseURL, mode: .readOnly)
        let key = PageKey(databaseURL: databaseURL, filter: filter)
        let candidates = offset > 0 && pageKey == key &&
            pageIdentity?.fingerprint == semantic.identity.fingerprint ? semanticIDs : nil
        return try store.withReadSnapshot {
            let progress = try store.embeddingProgress()
            guard progress.complete > 0 else {
                return try literal(store, filter: filter, limit: limit, offset: offset,
                                   reason: "Индекс ещё готовится. Пока ищем по словам.", progress: progress)
            }
            let page = try store.hybridSearch(filter, vector: semantic.vector, identity: semantic.identity,
                                             limit: limit, offset: offset, semanticIDs: candidates)
            guard page.modelMatched else {
                return try literal(store, filter: filter, limit: limit, offset: offset,
                                   reason: "История готовится для поиска по смыслу. Пока ищем по словам.",
                                   progress: progress)
            }
            pageKey = key; pageIdentity = semantic.identity; semanticIDs = page.semanticIDs
            return HybridSearchResponse(rows: page.rows, total: page.total, mode: .hybrid,
                                        fallbackReason: nil, progress: progress)
        }
    }

    /// Clear this client's caches. An injected worker belongs to its application owner;
    /// closing a chat or resetting a search must not stop other users of that worker.
    public func unload() {
        cachedVector = nil; semanticIDs = nil; pageKey = nil; pageIdentity = nil
        if ownsRuntime { runtime?.unload() }
    }

    public nonisolated func shutdown() { if ownsRuntime { runtime?.shutdown() } }

    private func literal(_ databaseURL: URL, filter: SearchFilter, limit: Int, offset: Int,
                         reason: String? = nil) throws -> HybridSearchResponse {
        let store = try HistoryStore(url: databaseURL, mode: .readOnly)
        return try store.withReadSnapshot {
            try literal(store, filter: filter, limit: limit, offset: offset, reason: reason)
        }
    }

    private func literal(_ store: HistoryStore, filter: SearchFilter, limit: Int, offset: Int,
                         reason: String?, progress: EmbeddingProgress? = nil) throws -> HybridSearchResponse {
        HybridSearchResponse(rows: try store.search(filter, limit: limit, offset: offset),
                             total: try store.count(filter), mode: .literal,
                             fallbackReason: reason, progress: progress)
    }
}

private enum SearchFailure: LocalizedError {
    case invalidEmbedding, modelChanged
    var errorDescription: String? {
        switch self {
        case .invalidEmbedding: return "Не удалось выполнить поиск по смыслу. Пока ищем по словам."
        case .modelChanged: return "Поиск по смыслу выключен или ещё не готов. Пока ищем по словам."
        }
    }
}
