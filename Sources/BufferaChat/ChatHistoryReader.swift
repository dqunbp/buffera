import Foundation
import BufferaCore
import BufferaSearch

struct ChatHistoryItem: Encodable, Sendable {
    let id: String
    let title: String
    let copiedAt: String
    let application: String
    let kind: String
    let snippet: String

    init(_ summary: ClipSummary) {
        id = String(summary.id)
        title = chatPrefix(summary.title, characters: 160, bytes: 640)
        copiedAt = ISO8601DateFormatter().string(from: summary.date)
        application = chatPrefix(summary.source, characters: 128, bytes: 512)
        kind = summary.kind.rawValue
        snippet = chatPrefix(summary.text, characters: 280, bytes: 1120)
    }
}

struct ChatSearchPage: Sendable {
    let rows: [ClipSummary]
    let query: String
}

struct ChatEvidence: Encodable, Sendable {
    let citation: Int
    let item: ChatHistoryItem
    let text: String
    let contentKind: String
    let truncated: Bool
    let nextOffset: Int?
    let note: String?
    let source: ChatSource

    enum CodingKeys: CodingKey {
        case citation, item, text, contentKind, truncated, nextOffset, note
    }

    func bounded(bytes: Int) -> ChatEvidence {
        let shorter = chatPrefix(text, characters: 8000, bytes: bytes)
        return ChatEvidence(citation: citation, item: item, text: shorter, contentKind: contentKind,
                            truncated: truncated || shorter != text, nextOffset: nextOffset,
                            note: note, source: source)
    }
}

/// Opens fresh read-only connections, sharing the canonical search and text projection.
/// The external MCP access grant does not apply to the user's built-in local chat.
struct ChatHistoryReader: Sendable {
    let databaseURL: URL
    let searchService: HybridSearchService

    func search(_ filter: SearchFilter, limit: Int = 8, offset: Int = 0) async throws -> ChatSearchPage {
        var visible = filter
        visible.concealedOnly = false
        visible.excludesConcealed = true
        var result = try await searchService.search(databaseURL: databaseURL, filter: visible,
                                                   mode: .automatic, limit: limit, offset: offset)
        // A local chat must still retrieve useful evidence when the embedding model is off.
        // Literal search has no stemming: "проекта Borealis" does not match "Проект Borealis".
        // Relax only the text, at most twice, retaining every explicit metadata filter.
        if result.rows.isEmpty, offset == 0 {
            let words = filter.query.split(whereSeparator: \.isWhitespace).map {
                String($0).trimmingCharacters(in: .punctuationCharacters)
            }.filter { !$0.isEmpty }
            let alternatives: [String]
            if words.count >= 3 {
                alternatives = [words.suffix(2).joined(separator: " "), words.last!]
            } else if words.count == 2 {
                alternatives = [words[1], words[0]]
            } else { alternatives = [] }
            for query in alternatives where query != visible.query {
                try Task.checkCancellation()
                visible.query = query
                result = try await searchService.search(databaseURL: databaseURL, filter: visible,
                                                         mode: .automatic, limit: limit, offset: offset)
                if !result.rows.isEmpty { break }
            }
        }
        try Task.checkCancellation()
        let store = try HistoryStore(url: databaseURL, mode: .readOnly)
        let rows = try store.withReadSnapshot {
            try result.rows.compactMap { previous in
                do {
                    let current = try store.summary(id: previous.id)
                    return current.isConcealed ? nil : current
                } catch HistoryError.missing { return nil }
            }
        }
        return ChatSearchPage(rows: rows, query: visible.query)
    }

    func neighbors(id: Int64, before: Int, after: Int) throws -> [ClipSummary] {
        let store = try HistoryStore(url: databaseURL, mode: .readOnly)
        return try store.nearby(anchorID: id, before: before, after: after, includeConcealed: false)
    }

    func read(id: Int64, number: Int, offset: Int = 0, limit: Int = 8000,
              bytes: Int = 16_000) throws -> ChatEvidence {
        let store = try HistoryStore(url: databaseURL, mode: .readOnly)
        let content = try store.visibleContent(id: id)
        let decoded = try HistoryTextContent.decode(content)
        guard offset >= 0, offset <= decoded.text.count else { throw ChatPlanError.invalid }
        let start = decoded.text.index(decoded.text.startIndex, offsetBy: offset)
        let text = chatPrefix(String(decoded.text[start...]), characters: limit, bytes: bytes)
        // No snapshot is held while payloads are decoded.
        let current = try store.summary(id: id)
        guard !current.isConcealed else { throw ChatSessionError.historyChanged }
        let next = offset + text.count
        return ChatEvidence(citation: number, item: ChatHistoryItem(current), text: text,
                            contentKind: decoded.kind.rawValue,
                            truncated: !decoded.isComplete || offset > 0 || next < decoded.text.count,
                            nextOffset: next < decoded.text.count ? next : nil, note: decoded.note,
                            source: ChatSource(number: number, id: id,
                                title: chatPrefix(current.title, characters: 160, bytes: 640),
                                copiedAt: current.date, application: current.source))
    }

    func sourceNames() throws -> [String] {
        try HistoryStore(url: databaseURL, mode: .readOnly).sources().prefix(40).map {
            chatPrefix($0, characters: 128, bytes: 512)
        }
    }

    func validate(ids: Set<Int64>) throws {
        guard !ids.isEmpty else { return }
        let store = try HistoryStore(url: databaseURL, mode: .readOnly)
        try store.withReadSnapshot {
            for id in ids {
                guard let current = try? store.summary(id: id), !current.isConcealed else {
                    throw ChatSessionError.historyChanged
                }
            }
        }
    }
}

/// A synchronous streaming gate prevents delayed worker callbacks from releasing text
/// after a source is pruned, deleted or concealed. The owning task checks the gate again at EOF.
final class ChatStreamGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let reader: ChatHistoryReader
    private let ids: Set<Int64>
    private var invalid = false
    private var store: HistoryStore?

    init(reader: ChatHistoryReader, ids: Set<Int64>) { self.reader = reader; self.ids = ids }

    func permits() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid else { return false }
        do {
            if store == nil { store = try HistoryStore(url: reader.databaseURL, mode: .readOnly) }
            try store!.withReadSnapshot {
                for id in ids {
                    guard let current = try? store!.summary(id: id), !current.isConcealed else {
                        throw ChatSessionError.historyChanged
                    }
                }
            }
            return true
        }
        catch { invalid = true; return false }
    }

    var isInvalid: Bool {
        lock.lock(); defer { lock.unlock() }
        return invalid
    }
}
