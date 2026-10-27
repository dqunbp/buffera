import Foundation
import CSQLite
import BufferaCore
import BufferaMCPKit
import BufferaSearch

final class HistoryReaderTests {
    private var directory: URL!
    private var access: MCPAccess!
    private var store: HistoryStore!
    private var reader: HistoryReader!

    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BufferaMCPTests-\(UUID().uuidString)")
        access = MCPAccess(directory: directory)
        store = try makeTestHistoryStore(url: access.databaseURL)
        try access.setEnabled(true)
        reader = HistoryReader(directory: directory)
    }

    func tearDownWithError() throws {
        reader = nil
        store = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func payload(_ text: String) -> ClipPayload {
        ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]])
    }

    @discardableResult
    private func insert(_ text: String, time: Double = 100, kind: ClipKind = .text,
                        source: String = "Fixture", hidden: Bool = false,
                        summary: String? = nil, remote: Bool = false) throws -> Int64 {
        try store.insert(payload: payload(text), kind: kind, title: text, text: summary ?? text, source: source,
                         isConcealed: hidden, isRemote: remote, date: Date(timeIntervalSince1970: time))
    }

    private func expectError(_ expected: HistoryReaderError,
                             operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await operation()
            try checkFail("Expected \(expected)", file: file, line: line)
        } catch {
            try checkEqual(error as? HistoryReaderError, expected, file: file, line: line)
        }
    }

    private func executeSQL(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(access.databaseURL.path, &db) == SQLITE_OK else {
            throw HistoryReaderError.storageUnavailable
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryReaderError.storageUnavailable
        }
    }

    func testDisabledAndRevokedAccessAreCheckedOnEveryRequest() async throws {
        let id = try insert("grant fixture")
        try access.setEnabled(false)
        try await expectError(.disabled) { _ = try await self.reader.search(filter: SearchFilter()) }
        try await expectError(.disabled) { _ = try await self.reader.read(id: id) }
        try await expectError(.disabled) { _ = try await self.reader.nearby(id: id) }
        try access.setEnabled(true)
        let first = try await reader.read(id: id)
        try checkEqual(first.text, "grant fixture")
        try access.setEnabled(false)
        try await expectError(.disabled) { _ = try await self.reader.read(id: id) }
        try access.setEnabled(true)
        let restored = try await reader.search(filter: SearchFilter())
        try checkEqual(restored.total, 1)
    }

    func testMissingDirectoryDoesNotCreateHistoryOrGrant() async throws {
        let absent = directory.appendingPathComponent("not-created")
        let absentReader = HistoryReader(directory: absent)
        try await expectError(.disabled) { _ = try await absentReader.search(filter: SearchFilter()) }
        try checkFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testEnabledMissingDatabaseFailsWithoutCreatingIt() async throws {
        let absent = directory.appendingPathComponent("empty")
        let absentAccess = MCPAccess(directory: absent)
        try absentAccess.setEnabled(true)
        let absentReader = HistoryReader(directory: absent)
        try await expectError(.storageUnavailable) { _ = try await absentReader.search(filter: SearchFilter()) }
        try checkFalse(FileManager.default.fileExists(atPath: absentAccess.databaseURL.path))
    }

    private func checkMaskedItem(_ item: HistoryItem) throws {
        try checkTrue(item.isConcealed)
        try checkEqual(item.title, "Скрытая запись")
        try checkNil(item.snippet)
        try checkNil(item.snippetTruncated)
        try checkNil(item.byteCount)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        for key in ["snippet", "snippetTruncated", "byteCount", "label"] {
            try checkNil(json?[key], "Masked metadata must omit \(key), including null values")
        }
    }

    func testSearchIncludesMaskedItemsAndSupportsConcealedFilters() async throws {
        let visible = try insert("visible needle", time: 1)
        let concealed = try insert("secret needle", time: 2, source: "Safari", hidden: true, remote: true)
        try store.setFavorite(id: concealed, isFavorite: true)
        // Masking must also hold for stale metadata left by an older writer or a damaged store.
        try executeSQL("UPDATE clips SET title='legacy-secret-title',text='legacy-secret-snippet' WHERE id=\(concealed)")
        let all = try await reader.search(filter: SearchFilter(), limit: 1)
        try checkEqual(all.items.map(\.id), [String(concealed)])
        try checkEqual(all.total, 2)
        try checkEqual(all.nextOffset, 1)
        try checkMaskedItem(all.items[0])
        try checkEqual(all.items[0].source, "Safari")
        try checkEqual(all.items[0].copiedAt, "1970-01-01T00:00:02.000Z")
        try checkTrue(all.items[0].isRemote)
        try checkTrue(all.items[0].isFavorite)
        let next = try await reader.search(filter: SearchFilter(), limit: 1, offset: 1)
        try checkEqual(next.items.map(\.id), [String(visible)])
        try checkFalse(next.items[0].isConcealed)
        var filter = SearchFilter()
        filter.concealedOnly = true
        filter.source = "Safari"
        filter.kind = .text
        filter.remoteOnly = true
        filter.favoritesOnly = true
        filter.from = Date(timeIntervalSince1970: 2)
        filter.until = Date(timeIntervalSince1970: 3)
        let hidden = try await reader.search(filter: filter)
        try checkEqual(hidden.items.map(\.id), [String(concealed)])
        try checkEqual(hidden.total, 1)
        filter.query = "secret"
        let secret = try await reader.search(filter: filter)
        try checkEqual(secret.total, 0)
        try checkTrue(secret.items.isEmpty)
        filter = SearchFilter()
        filter.query = "needle"
        let matches = try await reader.search(filter: filter)
        try checkEqual(matches.items.map(\.id), [String(visible)])
    }

    func testSearchFiltersAndPaginationHaveStableMetadata() async throws {
        try insert("target old", time: 1, source: "Terminal", remote: true)
        let middle = try insert("target middle", time: 2, source: "Terminal", remote: true)
        let newest = try insert("target new", time: 3, source: "Terminal", remote: true)
        try insert("wrong app", time: 4, source: "Safari", remote: true)
        try store.setFavorite(id: middle, isFavorite: true)
        try store.setFavorite(id: newest, isFavorite: true)
        var filter = SearchFilter()
        filter.query = "target"
        filter.source = "Terminal"
        filter.kind = .text
        filter.remoteOnly = true
        filter.favoritesOnly = true
        filter.from = Date(timeIntervalSince1970: 2)
        filter.until = Date(timeIntervalSince1970: 4)
        let first = try await reader.search(filter: filter, limit: 1)
        try checkEqual(first.total, 2)
        try checkEqual(first.items.map(\.id), [String(newest)])
        try checkEqual(first.nextOffset, 1)
        try checkEqual(first.items[0].copiedAt, "1970-01-01T00:00:03.000Z")
        try checkTrue(first.items[0].isRemote)
        try checkTrue(first.items[0].isFavorite)
        let second = try await reader.search(filter: filter, limit: 1, offset: 1)
        try checkEqual(second.items.map(\.id), [String(middle)])
        try checkNil(second.nextOffset)
        let beyond = try await reader.search(filter: filter, offset: 10)
        try checkEqual(beyond.total, 2)
        try checkTrue(beyond.items.isEmpty)
        try checkNil(beyond.nextOffset)
    }

    func testSearchReportsActualModeAndKeepsLiteralModeIndependentOfInference() async throws {
        let id = try insert("exact words", time: 1)
        var filter = SearchFilter()
        filter.query = "exact"
        let unavailable = try await reader.search(filter: filter, mode: .hybrid)
        try checkEqual(unavailable.searchMode, "literal")
        try checkNotNil(unavailable.fallbackReason)
        try checkEqual(unavailable.items.map(\.id), [String(id)])

        let literalOnly = HistoryReader(directory: directory, searchService: HybridSearchService(queryProvider: { _ in
            throw HistoryReaderError.invalidArgument("Literal search must not compute an embedding")
        }))
        let literal = try await literalOnly.search(filter: filter, mode: .literal)
        try checkEqual(literal.searchMode, "literal")
        try checkNil(literal.fallbackReason)
        try checkEqual(literal.items.map(\.id), [String(id)])
        let browse = try await literalOnly.search(filter: SearchFilter())
        try checkNil(browse.fallbackReason)
        try checkEqual(browse.total, 1)
    }

    func testRevokingAccessDuringQueryInferenceDiscardsResults() async throws {
        try insert("still private", time: 1)
        let directory = self.directory!
        let delayed = HistoryReader(directory: directory, searchService: HybridSearchService(queryProvider: { _ in
            try MCPAccess(directory: directory).setEnabled(false)
            throw HistoryReaderError.invalidArgument("An inference failure cannot override revocation")
        }))
        var filter = SearchFilter()
        filter.query = "private"
        try await expectError(.disabled) { _ = try await delayed.search(filter: filter, mode: .hybrid) }
    }

    func testModelUnloadFallsBackButRequestCancellationPropagates() async throws {
        let id = try insert("query survives model unload")
        var filter = SearchFilter()
        filter.query = "query"
        let unloaded = HistoryReader(directory: directory, searchService: HybridSearchService(queryProvider: { _ in
            // Runtime unload cancels its continuation without cancelling the caller's Task.
            throw CancellationError()
        }))
        let fallback = try await unloaded.search(filter: filter, mode: .hybrid)
        try checkEqual(fallback.searchMode, "literal")
        try checkNotNil(fallback.fallbackReason)
        try checkEqual(fallback.items.map(\.id), [String(id)])

        let invocation = QueryInvocation()
        let delayed = HistoryReader(directory: directory, searchService: HybridSearchService(queryProvider: { _ in
            await invocation.start()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw HistoryReaderError.invalidArgument("The cancelled request must not finish")
        }))
        let request = Task { try await delayed.search(filter: filter, mode: .hybrid) }
        for _ in 0..<100 {
            if await invocation.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await invocation.started
        request.cancel()
        try checkTrue(started, "Cancellation fixture reached inference")
        do {
            _ = try await request.value
            try checkFail("Cancelling the actual request must not publish a literal fallback")
        } catch is CancellationError {
            try checkTrue(true)
        }
    }

    func testHybridSearchUsesSharedIndexFiltersPaginationAndMasks() async throws {
        let literalID = try insert("database error", time: 3, source: "Terminal")
        let semanticID = try insert("connection refused", time: 2, source: "Terminal")
        try insert("unrelated document", time: 4, source: "Safari")
        let hiddenID = try insert("database secret", time: 5, source: "Terminal", hidden: true)
        let identity = EmbeddingIndexIdentity(fingerprint: "reader-fixture-v1", dimensions: 2)
        try store.configureEmbeddingIndex(identity)
        while let job = try store.nextPendingEmbedding() {
            let vector: [Float] = job.clipID == semanticID ? [1, 0] : [0, 1]
            try checkTrue(store.completeEmbedding(job, vectors: [vector]))
        }
        let service = HybridSearchService(queryProvider: { _ in SemanticQuery(vector: [1, 0], identity: identity) })
        let hybrid = HistoryReader(directory: directory, searchService: service)
        var filter = SearchFilter()
        filter.query = "database"
        filter.source = "Terminal"
        let first = try await hybrid.search(filter: filter, limit: 1)
        try checkEqual(first.searchMode, "hybrid")
        try checkNil(first.fallbackReason)
        try checkEqual(first.total, 2)
        try checkEqual(first.items.map(\.id), [String(literalID)])
        try checkEqual(first.nextOffset, 1)
        try checkEqual(first.indexed, 3)
        try checkEqual(first.eligible, 3)
        let second = try await hybrid.search(filter: filter, limit: 1, offset: 1)
        try checkEqual(second.items.map(\.id), [String(semanticID)])
        try checkNil(second.nextOffset)
        let literal = try await hybrid.search(filter: filter, mode: .literal)
        try checkEqual(literal.items.map(\.id), [String(literalID)])

        filter.query = ""
        filter.concealedOnly = true
        let hidden = try await hybrid.search(filter: filter, mode: .hybrid)
        try checkEqual(hidden.searchMode, "literal")
        try checkEqual(hidden.items.map(\.id), [String(hiddenID)])
        try checkMaskedItem(hidden.items[0])

        try store.conceal(id: semanticID)
        filter.query = "database"; filter.concealedOnly = false
        let concealed = try await hybrid.search(filter: filter)
        try checkEqual(concealed.items.map(\.id), [String(literalID)],
                       "A previous semantic match disappears once concealed")
    }

    func testMetadataIsBoundedAndIDDoesNotLoseIntegerPrecision() async throws {
        try executeSQL("INSERT INTO sqlite_sequence(name,seq) VALUES('clips',9007199254740992)")
        let long = String(repeating: "Ж", count: 700)
        let id = try insert(long)
        try checkEqual(id, 9_007_199_254_740_993)
        let result = try await reader.search(filter: SearchFilter())
        try checkEqual(result.items[0].id, "9007199254740993")
        try checkEqual(result.items[0].title.count, 240)
        try checkEqual(result.items[0].snippet?.count, 600)
        try checkEqual(result.items[0].snippetTruncated, true)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        try checkTrue(json.contains("\"id\":\"9007199254740993\""))
    }

    func testReadUsesFullPayloadAndUnicodeCharacterOffsets() async throws {
        let text = "👨‍👩‍👧‍👦e\u{301}Я\ncontinued"
        let id = try insert(text, summary: "capped summary")
        let first = try await reader.read(id: id, limit: 2)
        try checkEqual(first.text, "👨‍👩‍👧‍👦e\u{301}")
        try checkEqual(first.totalCharacters, text.count)
        try checkEqual(first.nextOffset, 2)
        try checkTrue(first.isComplete)
        try checkEqual(first.contentKind, .text)
        let second = try await reader.read(id: id, offset: 2, limit: 32_000)
        try checkEqual(first.text + second.text, text)
        try checkNil(second.nextOffset)
        let end = try await reader.read(id: id, offset: text.count)
        try checkEqual(end.text, "")
        try checkNil(end.nextOffset)
    }

    func testReadDoesNotTreatCappedSummaryAsCompleteText() async throws {
        let full = String(repeating: "x", count: 200_010)
        let id = try insert(full, summary: String(full.prefix(200_000)))
        let tail = try await reader.read(id: id, offset: 200_000)
        try checkEqual(tail.text, "xxxxxxxxxx")
        try checkEqual(tail.totalCharacters, 200_010)
        try checkTrue(tail.isComplete)
    }

    func testMetadataAndReadPagesRespectUTF8ByteCapsWithoutSplittingCharacters() async throws {
        let character = "👨‍👩‍👧‍👦"
        let full = String(repeating: character, count: 6_000)
        let id = try insert(full, source: String(repeating: character, count: 240))
        let search = try await reader.search(filter: SearchFilter())
        try checkTrue(search.items[0].title.utf8.count <= 1_024)
        try checkTrue((search.items[0].snippet?.utf8.count ?? Int.max) <= 4_096)
        try checkTrue(search.items[0].source.utf8.count <= 1_024)
        try checkEqual(search.items[0].snippetTruncated, true)
        let first = try await reader.read(id: id, limit: 32_000)
        let expectedCharacters = (128 * 1_024) / character.utf8.count
        try checkEqual(first.text.count, expectedCharacters)
        try checkEqual(first.nextOffset, expectedCharacters)
        try checkTrue(first.text.utf8.count <= 128 * 1_024)
        let second = try await reader.read(id: id, offset: expectedCharacters)
        try checkEqual(first.text + second.text, full)
        try checkNil(second.nextOffset)
        try store.conceal(id: id)
        let masked = try await reader.read(id: id, offset: expectedCharacters, limit: 32_000)
        try checkEqual(masked.contentKind, .masked)
        try checkEqual(masked.text, "")
        try checkNil(masked.nextOffset)
        try checkMaskedItem(masked.item)
    }

    func testOversizedSingleGraphemeHasExplicitErrorAndCannotOverflowMetadata() async throws {
        let oversized = "a" + String(repeating: "\u{301}", count: 70_000)
        try checkEqual(oversized.count, 1)
        let id = try insert(oversized, source: oversized)
        let search = try await reader.search(filter: SearchFilter())
        try checkEqual(search.items[0].title, "")
        try checkEqual(search.items[0].snippet, "")
        try checkEqual(search.items[0].source, "")
        try checkEqual(search.items[0].snippetTruncated, true)
        try await expectError(.oversizedCharacter) { _ = try await self.reader.read(id: id) }
        try store.conceal(id: id)
        let masked = try await reader.read(id: id)
        try checkEqual(masked.contentKind, .masked)
    }

    func testReadRequiresEveryItemToDecode() async throws {
        let combined = ClipPayload(items: [
            [Representation(type: "public.utf8-plain-text", data: Data("first".utf8))],
            [Representation(type: "public.utf8-plain-text", data: Data("second".utf8))]
        ])
        let id = try store.insert(payload: combined, kind: .text, title: "multi", text: "short", source: "Fixture")
        let result = try await reader.read(id: id)
        try checkEqual(result.text, "first\nsecond")
        let partial = ClipPayload(items: combined.items + [[Representation(type: "custom", data: Data([1, 2]))]])
        let broken = try store.insert(payload: partial, kind: .text, title: "broken", text: "fallback forbidden", source: "Fixture")
        try await expectError(.unreadableContent) { _ = try await self.reader.read(id: broken) }
    }

    func testLinkUsesOriginalURLPayload() async throws {
        let url = "https://example.invalid/a?x=%2B&utm_source=original"
        let id = try insert(url, kind: .link, summary: "short link")
        let result = try await reader.read(id: id)
        try checkEqual(result.text, url)
        try checkEqual(result.contentKind, .text)
    }

    func testHiddenReadMasksPayloadAndMissingRecordsStillFail() async throws {
        let hidden = try insert("concealed fixture", hidden: true)
        // A masked read must not decode payloads or validate offsets against the secret length.
        try executeSQL("UPDATE payloads SET data=X'00' WHERE clip_id=\(hidden)")
        try executeSQL("UPDATE clips SET title='legacy-secret-title',text='legacy-secret-snippet' WHERE id=\(hidden)")
        let result = try await reader.read(id: hidden, offset: Int.max)
        try checkMaskedItem(result.item)
        try checkEqual(result.contentKind, .masked)
        try checkEqual(result.text, "")
        try checkEqual(result.offset, 0)
        try checkNil(result.totalCharacters)
        try checkNil(result.nextOffset)
        try checkFalse(result.isComplete)
        try checkEqual(result.note, "Содержимое скрытой записи недоступно через MCP.")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        try checkNil(json?["totalCharacters"])
        try checkNil(json?["nextOffset"])
        try await expectError(.missing) { _ = try await self.reader.read(id: Int64.max) }
        try await expectError(.missing) { _ = try await self.reader.nearby(id: Int64.max) }
        let visible = try insert("will be concealed")
        _ = try await reader.read(id: visible)
        try store.conceal(id: visible)
        let newlyHidden = try await reader.read(id: visible)
        try checkEqual(newlyHidden.contentKind, .masked)
        try checkEqual(newlyHidden.text, "")
    }

    func testNeighborsUseCaptureTimeAndIncludeMaskedItemsInLimitsAndAnchors() async throws {
        let older = try insert("older", time: 1)
        let olderHidden = try insert("older hidden", time: 2, hidden: true)
        let anchor = try insert("anchor", time: 3)
        let newerHidden = try insert("newer hidden", time: 4, hidden: true)
        try executeSQL("UPDATE clips SET title='legacy-secret-title',text='legacy-secret-snippet' WHERE id IN (\(olderHidden),\(newerHidden))")
        try insert("newer", time: 5)
        try store.markUsed(id: older, date: Date(timeIntervalSince1970: 99))
        let result = try await reader.nearby(id: anchor, before: 1, after: 1)
        try checkEqual(result.anchorID, String(anchor))
        try checkEqual(result.items.map(\.id), [newerHidden, anchor, olderHidden].map(String.init))
        try checkMaskedItem(result.items[0])
        try checkMaskedItem(result.items[2])
        let hiddenAnchor = try await reader.nearby(id: olderHidden, before: 1, after: 1)
        try checkEqual(hiddenAnchor.anchorID, String(olderHidden))
        try checkEqual(hiddenAnchor.items.map(\.id), [anchor, olderHidden, older].map(String.init))
        try checkMaskedItem(hiddenAnchor.items[1])
        let only = try await reader.nearby(id: olderHidden, before: 0, after: 0)
        try checkEqual(only.items.map(\.id), [String(olderHidden)])
    }

    func testConcealedReadsNeverExposeContentOrChangeHistory() async throws {
        let text = "private-secret-needle" + String(repeating: "Я", count: 60_000)
        let id = try insert(text, time: 1, hidden: true)
        try store.setFavorite(id: id, isFavorite: true)
        try store.setLabel(id: id, label: "Router label private metadata")
        let originalPayload = try store.payload(id: id)
        let originalSummary = try store.summary(id: id)
        let order = try store.search(SearchFilter()).map(\.id)
        for offset in [0, 2, 32_002, Int.max] {
            let result = try await reader.read(id: id, offset: offset, limit: 32_000)
            try checkEqual(result.contentKind, .masked)
            try checkEqual(result.text, "")
            try checkEqual(result.offset, 0)
            try checkNil(result.totalCharacters)
            try checkNil(result.nextOffset)
            try checkMaskedItem(result.item)
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            try checkFalse(encoded.contains("Router label private metadata"))
        }
        var query = SearchFilter()
        query.query = "private-secret-needle"
        let searched = try await reader.search(filter: query)
        try checkTrue(searched.items.isEmpty)
        try checkEqual(try store.payload(id: id), originalPayload)
        let summary = try store.summary(id: id)
        try checkTrue(summary.isConcealed)
        try checkEqual(summary.date, originalSummary.date)
        try checkEqual(summary.text, originalSummary.text)
        try checkEqual(summary.title, originalSummary.title)
        try checkTrue(summary.isFavorite)
        try checkEqual(try store.search(SearchFilter()).map(\.id), order)
    }

    func testImageReadsOnlyCachedOCRAndReportsTruncation() async throws {
        let pending = try insert("image pending", kind: .image)
        let empty = try insert("image empty", kind: .image)
        let ready = try insert("image ready", kind: .image)
        let capped = try insert("image capped", kind: .image)
        try store.completeImageText(id: empty, text: "")
        try store.completeImageText(id: ready, text: "recognized text")
        try store.completeImageText(id: capped, text: String(repeating: "а", count: 200_001))
        // A corrupt binary payload must never be loaded for an image.
        try executeSQL("UPDATE payloads SET data=X'00' WHERE clip_id IN (\(pending),\(empty),\(ready),\(capped))")
        let unavailable = try await reader.read(id: pending)
        try checkEqual(unavailable.contentKind, .unavailableOCR)
        try checkEqual(unavailable.text, "")
        try checkFalse(unavailable.isComplete)
        let emptyResult = try await reader.read(id: empty)
        try checkEqual(emptyResult.contentKind, .cachedOCR)
        try checkEqual(emptyResult.text, "")
        try checkTrue(emptyResult.isComplete)
        let readyResult = try await reader.read(id: ready)
        try checkEqual(readyResult.text, "recognized text")
        try checkTrue(readyResult.isComplete)
        let cappedResult = try await reader.read(id: capped, offset: 199_999)
        try checkEqual(cappedResult.text, "а")
        try checkEqual(cappedResult.totalCharacters, 200_000)
        try checkFalse(cappedResult.isComplete)
        try checkNotNil(cappedResult.note)
        try checkNil(try store.imageText(id: pending))
    }

    func testFilesExposePathsWithoutReadingFiles() async throws {
        let names = ["file:///nonexistent/first%20name.txt", "file:///nonexistent/second.txt"]
        let files = ClipPayload(items: names.map { [Representation(type: "public.file-url", data: Data($0.utf8))] })
        let id = try store.insert(payload: files, kind: .file, title: "Files", text: "summary paths", source: "Finder")
        let result = try await reader.read(id: id)
        try checkEqual(result.text, "/nonexistent/first name.txt\n/nonexistent/second.txt")
        try checkEqual(result.contentKind, .filePaths)
        try checkTrue(result.isComplete)
        try store.conceal(id: id)
        let masked = try await reader.read(id: id)
        try checkEqual(masked.text, "")
        try checkEqual(masked.contentKind, .masked)
        try checkMaskedItem(masked.item)
        let wrong = ClipPayload(items: [[Representation(type: "public.file-url", data: Data("https://example.invalid/secret".utf8))]])
        let wrongID = try store.insert(payload: wrong, kind: .file, title: "Wrong URL", text: "", source: "Fixture")
        try await expectError(.unreadableContent) { _ = try await self.reader.read(id: wrongID) }
    }

    func testOtherTypesOnlyReturnMetadataEvenIfPayloadIsCorrupt() async throws {
        let id = try insert("unknown representation", kind: .other)
        try executeSQL("UPDATE payloads SET data=X'00' WHERE clip_id=\(id)")
        let result = try await reader.read(id: id)
        try checkEqual(result.contentKind, .unsupported)
        try checkEqual(result.text, "")
        try checkFalse(result.isComplete)
    }

    func testCorruptTextPayloadHasActionableErrorWithoutSummaryFallback() async throws {
        let id = try insert("must not substitute summary")
        try executeSQL("UPDATE payloads SET data=X'00' WHERE clip_id=\(id)")
        try await expectError(.unreadableContent) { _ = try await self.reader.read(id: id) }
    }

    func testReadingDoesNotChangeCaptureRecencyFavoritesOrPayload() async throws {
        let id = try insert("older capture", time: 1)
        try insert("newer capture", time: 2)
        try store.setFavorite(id: id, isFavorite: true)
        let originalPayload = try store.payload(id: id)
        let before = try store.search(SearchFilter()).map(\.id)
        _ = try await reader.read(id: id)
        _ = try await reader.search(filter: SearchFilter())
        _ = try await reader.nearby(id: id)
        try checkEqual(try store.search(SearchFilter()).map(\.id), before)
        try checkEqual(try store.payload(id: id), originalPayload)
        try checkEqual(try store.summary(id: id).date, Date(timeIntervalSince1970: 1))
        try checkTrue(try store.summary(id: id).isFavorite)
    }

    func testRuntimeBoundsRejectInvalidArguments() async throws {
        let id = try insert("bounds")
        for limit in [0, 51] {
            try await expectError(.invalidArgument("limit должен быть от 1 до 50.")) {
                _ = try await self.reader.search(filter: SearchFilter(), limit: limit)
            }
        }
        for offset in [-1, 100_001] {
            try await expectError(.invalidArgument("offset должен быть от 0 до 100000.")) {
                _ = try await self.reader.search(filter: SearchFilter(), offset: offset)
            }
        }
        for limit in [0, 32_001] {
            try await expectError(.invalidArgument("limit должен быть от 1 до 32000.")) {
                _ = try await self.reader.read(id: id, limit: limit)
            }
        }
        try await expectError(.invalidArgument("offset должен быть не меньше 0.")) {
            _ = try await self.reader.read(id: id, offset: -1)
        }
        try await expectError(.invalidArgument("offset превышает длину текста (6 символов).")) {
            _ = try await self.reader.read(id: id, offset: Int.max)
        }
        for badID in [Int64(0), Int64(-1)] {
            try await expectError(.invalidArgument("id должен быть положительным целым числом.")) {
                _ = try await self.reader.read(id: badID)
            }
            try await expectError(.invalidArgument("id должен быть положительным целым числом.")) {
                _ = try await self.reader.nearby(id: badID)
            }
        }
        for count in [-1, 21] {
            try await expectError(.invalidArgument("before должен быть от 0 до 20.")) {
                _ = try await self.reader.nearby(id: id, before: count)
            }
            try await expectError(.invalidArgument("after должен быть от 0 до 20.")) {
                _ = try await self.reader.nearby(id: id, after: count)
            }
        }
    }
}

func runHistoryReaderChecks() async throws {
    let checks: [(String, (HistoryReaderTests) -> () async throws -> Void)] = [
        ("testDisabledAndRevokedAccessAreCheckedOnEveryRequest", HistoryReaderTests.testDisabledAndRevokedAccessAreCheckedOnEveryRequest),
        ("testMissingDirectoryDoesNotCreateHistoryOrGrant", HistoryReaderTests.testMissingDirectoryDoesNotCreateHistoryOrGrant),
        ("testEnabledMissingDatabaseFailsWithoutCreatingIt", HistoryReaderTests.testEnabledMissingDatabaseFailsWithoutCreatingIt),
        ("testSearchIncludesMaskedItemsAndSupportsConcealedFilters", HistoryReaderTests.testSearchIncludesMaskedItemsAndSupportsConcealedFilters),
        ("testSearchFiltersAndPaginationHaveStableMetadata", HistoryReaderTests.testSearchFiltersAndPaginationHaveStableMetadata),
        ("testSearchReportsActualModeAndKeepsLiteralModeIndependentOfInference", HistoryReaderTests.testSearchReportsActualModeAndKeepsLiteralModeIndependentOfInference),
        ("testRevokingAccessDuringQueryInferenceDiscardsResults", HistoryReaderTests.testRevokingAccessDuringQueryInferenceDiscardsResults),
        ("testModelUnloadFallsBackButRequestCancellationPropagates", HistoryReaderTests.testModelUnloadFallsBackButRequestCancellationPropagates),
        ("testHybridSearchUsesSharedIndexFiltersPaginationAndMasks", HistoryReaderTests.testHybridSearchUsesSharedIndexFiltersPaginationAndMasks),
        ("testMetadataIsBoundedAndIDDoesNotLoseIntegerPrecision", HistoryReaderTests.testMetadataIsBoundedAndIDDoesNotLoseIntegerPrecision),
        ("testReadUsesFullPayloadAndUnicodeCharacterOffsets", HistoryReaderTests.testReadUsesFullPayloadAndUnicodeCharacterOffsets),
        ("testReadDoesNotTreatCappedSummaryAsCompleteText", HistoryReaderTests.testReadDoesNotTreatCappedSummaryAsCompleteText),
        ("testMetadataAndReadPagesRespectUTF8ByteCapsWithoutSplittingCharacters", HistoryReaderTests.testMetadataAndReadPagesRespectUTF8ByteCapsWithoutSplittingCharacters),
        ("testOversizedSingleGraphemeHasExplicitErrorAndCannotOverflowMetadata", HistoryReaderTests.testOversizedSingleGraphemeHasExplicitErrorAndCannotOverflowMetadata),
        ("testReadRequiresEveryItemToDecode", HistoryReaderTests.testReadRequiresEveryItemToDecode),
        ("testLinkUsesOriginalURLPayload", HistoryReaderTests.testLinkUsesOriginalURLPayload),
        ("testHiddenReadMasksPayloadAndMissingRecordsStillFail", HistoryReaderTests.testHiddenReadMasksPayloadAndMissingRecordsStillFail),
        ("testNeighborsUseCaptureTimeAndIncludeMaskedItemsInLimitsAndAnchors", HistoryReaderTests.testNeighborsUseCaptureTimeAndIncludeMaskedItemsInLimitsAndAnchors),
        ("testConcealedReadsNeverExposeContentOrChangeHistory", HistoryReaderTests.testConcealedReadsNeverExposeContentOrChangeHistory),
        ("testImageReadsOnlyCachedOCRAndReportsTruncation", HistoryReaderTests.testImageReadsOnlyCachedOCRAndReportsTruncation),
        ("testFilesExposePathsWithoutReadingFiles", HistoryReaderTests.testFilesExposePathsWithoutReadingFiles),
        ("testOtherTypesOnlyReturnMetadataEvenIfPayloadIsCorrupt", HistoryReaderTests.testOtherTypesOnlyReturnMetadataEvenIfPayloadIsCorrupt),
        ("testCorruptTextPayloadHasActionableErrorWithoutSummaryFallback", HistoryReaderTests.testCorruptTextPayloadHasActionableErrorWithoutSummaryFallback),
        ("testReadingDoesNotChangeCaptureRecencyFavoritesOrPayload", HistoryReaderTests.testReadingDoesNotChangeCaptureRecencyFavoritesOrPayload),
        ("testRuntimeBoundsRejectInvalidArguments", HistoryReaderTests.testRuntimeBoundsRejectInvalidArguments),
    ]
    for (name, test) in checks {
        let suite = HistoryReaderTests()
        try suite.setUpWithError()
        do {
            try await test(suite)()
            try suite.tearDownWithError()
            print("PASS \(name)")
        } catch {
            try? suite.tearDownWithError()
            throw error
        }
    }
}

private actor QueryInvocation {
    private(set) var started = false
    func start() { started = true }
}
