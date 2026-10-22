import Foundation
import BufferaCore
import BufferaSearch

/// Bounded metadata shared by all MCP history results. IDs are strings to preserve Int64 precision.
public struct HistoryItem: Codable, Sendable, Equatable {
    public let id: String
    public let copiedAt: String
    public let kind: String
    public let title: String
    public let snippet: String?
    public let snippetTruncated: Bool?
    public let source: String
    public let byteCount: Int?
    public let isConcealed: Bool
    public let isFavorite: Bool
    public let isRemote: Bool

    init(_ clip: ClipSummary) {
        id = String(clip.id)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        copiedAt = formatter.string(from: clip.date)
        kind = clip.kind.rawValue
        isConcealed = clip.isConcealed
        if clip.isConcealed {
            // Mask at the serialization boundary as well as in storage.
            title = HistoryStore.concealedTitle
            snippet = nil
            snippetTruncated = nil
            byteCount = nil
        } else {
            title = boundedPrefix(clip.title[...], characters: 240, bytes: 1_024).text
            let preview = boundedPrefix(clip.text[...], characters: 600, bytes: 4_096)
            snippet = preview.text
            snippetTruncated = preview.endIndex != clip.text.endIndex
            byteCount = clip.byteCount
        }
        source = boundedPrefix(clip.source[...], characters: 240, bytes: 1_024).text
        isFavorite = clip.isFavorite
        isRemote = clip.isRemote
    }
}

public struct HistorySearchResult: Codable, Sendable, Equatable {
    public let items: [HistoryItem]
    public let total: Int
    public let offset: Int
    public let nextOffset: Int?
    public let searchMode: String
    public let fallbackReason: String?
    public let indexed: Int?
    public let eligible: Int?
}

public enum HistoryContentKind: String, Codable, Sendable {
    case masked
    case text
    case cachedOCR
    case filePaths
    case unavailableOCR
    case unsupported
}

public struct HistoryReadResult: Codable, Sendable, Equatable {
    public let item: HistoryItem
    public let text: String
    public let contentKind: HistoryContentKind
    /// Character offsets count Swift Characters (extended grapheme clusters), not bytes.
    public let offset: Int
    /// Omitted for a masked record, whose content has not been read.
    public let totalCharacters: Int?
    public let nextOffset: Int?
    /// Whether the source text is complete. Use nextOffset to determine whether more chunks remain.
    public let isComplete: Bool
    public let note: String?
}

public struct HistoryNeighborsResult: Codable, Sendable, Equatable {
    public let anchorID: String
    /// Newest capture first, including the anchor. Before means older; after means newer.
    public let items: [HistoryItem]
}

public enum HistoryReaderError: LocalizedError, Equatable {
    case disabled
    case missing
    case invalidArgument(String)
    case unreadableContent
    case oversizedCharacter
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Доступ через MCP выключен. Включите его в настройках Buffera."
        case .missing:
            return "Запись недоступна. Найдите актуальную запись в истории Buffera."
        case .invalidArgument(let description):
            return description
        case .unreadableContent:
            return "Не удалось прочитать полное содержимое записи. Попробуйте скопировать источник заново."
        case .oversizedCharacter:
            return "Один символ текста превышает лимит ответа 128 КиБ. Его нельзя передать без разрыва символа."
        case .storageUnavailable:
            return "Не удалось открыть историю для чтения. Запустите актуальную Buffera и проверьте путь к истории."
        }
    }
}

/// Serial, read-only access to history. Every request checks the on-disk grant and opens a fresh connection.
public actor HistoryReader {
    private let directory: URL
    private let searchService: HybridSearchService

    public init(directory: URL = MCPAccess.defaultDirectory, searchService: HybridSearchService? = nil) {
        self.directory = directory
        self.searchService = searchService ?? HybridSearchService(
            modelRootURL: directory.appendingPathComponent("Models", isDirectory: true),
            bundleURL: Self.helperBundleURL
        )
    }

    public func search(filter: SearchFilter, mode: HistorySearchMode = .automatic,
                       limit: Int = 20, offset: Int = 0) async throws -> HistorySearchResult {
        try validate(limit, in: 1...50, name: "limit")
        try validate(offset, in: 0...100_000, name: "offset")
        let access = MCPAccess(directory: directory)
        guard access.isEnabled() else { throw HistoryReaderError.disabled }
        do {
            let result = try await searchService.search(databaseURL: access.databaseURL, filter: filter,
                                                        mode: mode, limit: limit, offset: offset)
            try Task.checkCancellation()
            return try withAccess { store in
                try store.withReadSnapshot {
                    // Inference can outlive a concealment or deletion. Refresh metadata after it;
                    // a newly concealed semantic match must not reveal even its membership.
                    let clips = try result.rows.compactMap { previous -> ClipSummary? in
                        do {
                            let current = try store.summary(id: previous.id)
                            guard previous.isConcealed || !current.isConcealed else { return nil }
                            return current
                        } catch HistoryError.missing { return nil }
                    }
                    let end = offset + result.rows.count
                    return HistorySearchResult(
                        items: clips.map(HistoryItem.init), total: result.total, offset: offset,
                        nextOffset: end < result.total ? end : nil,
                        searchMode: result.mode.rawValue, fallbackReason: result.fallbackReason,
                        indexed: result.progress?.complete, eligible: result.progress?.total
                    )
                }
            }
        } catch {
            guard access.isEnabled() else { throw HistoryReaderError.disabled }
            if error is CancellationError { throw CancellationError() }
            if let error = error as? HistoryReaderError { throw error }
            throw HistoryReaderError.storageUnavailable
        }
    }

    private static var helperBundleURL: URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let macOS = executable.deletingLastPathComponent()
        if macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" {
            return macOS.deletingLastPathComponent().deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
    }

    public func read(id: Int64, offset: Int = 0, limit: Int = 8_000) throws -> HistoryReadResult {
        try validateID(id)
        try validate(limit, in: 1...32_000, name: "limit")
        guard offset >= 0 else { throw HistoryReaderError.invalidArgument("offset должен быть не меньше 0.") }
        return try withAccess { store in
            let summary = try store.summary(id: id)
            if summary.isConcealed { return masked(summary) }
            do {
                let content = try store.visibleContent(id: id)
                let decoded = try decode(content)
                let total = decoded.text.count
                guard offset <= total else {
                    throw HistoryReaderError.invalidArgument("offset превышает длину текста (\(total) символов).")
                }
                let start = decoded.text.index(decoded.text.startIndex, offsetBy: offset)
                let chunk = boundedPrefix(decoded.text[start...], characters: limit, bytes: 128 * 1_024)
                guard chunk.characters > 0 || offset == total else { throw HistoryReaderError.oversizedCharacter }
                let next = offset + chunk.characters
                // Decoding may take time. Recheck deletion/concealment before releasing content.
                let current = try store.summary(id: id)
                if current.isConcealed { return masked(current) }
                return HistoryReadResult(
                    item: HistoryItem(current), text: chunk.text,
                    contentKind: decoded.kind, offset: offset, totalCharacters: total,
                    nextOffset: next < total ? next : nil, isComplete: decoded.isComplete, note: decoded.note
                )
            } catch {
                // Concurrent concealment also masks decoding/offset errors, which can reveal a length.
                if let current = try? store.summary(id: id), current.isConcealed {
                    return masked(current)
                }
                throw error
            }
        }
    }

    private func masked(_ summary: ClipSummary) -> HistoryReadResult {
        HistoryReadResult(item: HistoryItem(summary), text: "", contentKind: .masked, offset: 0,
                          totalCharacters: nil, nextOffset: nil, isComplete: false,
                          note: "Содержимое скрытой записи недоступно через MCP.")
    }

    public func nearby(id: Int64, before: Int = 10, after: Int = 10) throws -> HistoryNeighborsResult {
        try validateID(id)
        try validate(before, in: 0...20, name: "before")
        try validate(after, in: 0...20, name: "after")
        return try withAccess { store in
            let clips = try store.nearby(anchorID: id, before: before, after: after, includeConcealed: true)
            return HistoryNeighborsResult(anchorID: String(id), items: clips.map(HistoryItem.init))
        }
    }

    private func withAccess<T>(_ body: (HistoryStore) throws -> T) throws -> T {
        let access = MCPAccess(directory: directory)
        guard access.isEnabled() else { throw HistoryReaderError.disabled }
        do {
            let store = try HistoryStore(url: access.databaseURL, mode: .readOnly)
            let result = try body(store)
            guard access.isEnabled() else { throw HistoryReaderError.disabled }
            return result
        } catch {
            // Revocation also takes precedence over an in-flight storage or decoding failure.
            guard access.isEnabled() else { throw HistoryReaderError.disabled }
            switch error {
            case let readerError as HistoryReaderError: throw readerError
            case HistoryError.missing: throw HistoryReaderError.missing
            case HistoryError.invalidPayload, is DecodingError: throw HistoryReaderError.unreadableContent
            default: throw HistoryReaderError.storageUnavailable
            }
        }
    }

    private struct DecodedContent {
        let text: String
        let kind: HistoryContentKind
        let isComplete: Bool
        let note: String?
    }

    private func decode(_ content: ClipContent) throws -> DecodedContent {
        let decoded = try HistoryTextContent.decode(content)
        guard let kind = HistoryContentKind(rawValue: decoded.kind.rawValue) else {
            throw HistoryReaderError.unreadableContent
        }
        return DecodedContent(text: decoded.text, kind: kind, isComplete: decoded.isComplete,
                              note: decoded.note)
    }

    private func validate(_ value: Int, in range: ClosedRange<Int>, name: String) throws {
        guard range.contains(value) else {
            throw HistoryReaderError.invalidArgument("\(name) должен быть от \(range.lowerBound) до \(range.upperBound).")
        }
    }

    private func validateID(_ id: Int64) throws {
        guard id > 0 else { throw HistoryReaderError.invalidArgument("id должен быть положительным целым числом.") }
    }
}

/// Bound both user-perceived characters and UTF-8 bytes without splitting a grapheme cluster.
private func boundedPrefix(_ value: Substring, characters maximumCharacters: Int,
                           bytes maximumBytes: Int) -> (text: String, characters: Int, endIndex: String.Index) {
    var end = value.startIndex
    var characters = 0
    var bytes = 0
    while end < value.endIndex, characters < maximumCharacters {
        let next = value.index(after: end)
        let size = value[end..<next].utf8.count
        guard size <= maximumBytes - bytes else { break }
        bytes += size
        characters += 1
        end = next
    }
    return (String(value[..<end]), characters, end)
}
