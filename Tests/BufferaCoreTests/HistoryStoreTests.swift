import Foundation
import BufferaCore
import CSQLite

final class HistoryStoreTests {
    private var directory: URL!
    private var store: HistoryStore!

    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    }
    func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: directory) }
    private func payload(_ value: String) -> ClipPayload {
        ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(value.utf8))]])
    }
    private func imagePayload(_ value: String) -> ClipPayload {
        ClipPayload(items: [[Representation(type: "public.png", data: Data(value.utf8))]])
    }
    @discardableResult private func insertImage(_ value: String, time: Double = 100, title: String = "Картинка",
                                               source: String = "Тест", concealed: Bool = false,
                                               maxCount: Int = 50_000, maxBytes: Int = 5_000_000_000) throws -> Int64 {
        try store.insert(payload: imagePayload(value), kind: .image, title: title, text: "", source: source,
                         isConcealed: concealed, date: Date(timeIntervalSince1970: time),
                         maxCount: maxCount, maxBytes: maxBytes)
    }
    @discardableResult private func insert(_ value: String, time: Double = 100, kind: ClipKind = .text,
                                          source: String = "Тест",
                                          maxCount: Int = 50_000, maxBytes: Int = 5_000_000_000) throws -> Int64 {
        try store.insert(payload: payload(value), kind: kind, title: value, text: value, source: source,
                         date: Date(timeIntervalSince1970: time), maxCount: maxCount, maxBytes: maxBytes)
    }

    func testAllFormatsAndItemsSurviveReopen() throws {
        let original = ClipPayload(items: [[Representation(type: "custom", data: Data([0, 255])), Representation(type: "text", data: Data("hi".utf8))],
                                          [Representation(type: "url", data: Data("file:///tmp/a".utf8))]])
        let id = try store.insert(payload: original, kind: .file, title: "Файлы", text: "", source: "Finder")
        store = nil
        store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.payload(id: id), original)
    }

    func testSummaryGetterReflectsCurrentMetadataAndDoesNotLoadPayload() throws {
        let id = try insert("summary fixture", time: 12, source: "Original app")
        try store.setFavorite(id: id, isFavorite: true)
        try store.markUsed(id: id, date: Date(timeIntervalSince1970: 30))
        let summary = try store.summary(id: id)
        try checkEqual(summary.id, id); try checkEqual(summary.date, Date(timeIntervalSince1970: 12))
        try checkEqual(summary.source, "Original app"); try checkEqual(summary.text, "summary fixture")
        try check(summary.isFavorite && !summary.isConcealed)
        try store.conceal(id: id)
        let concealed = try store.summary(id: id)
        try check(concealed.isConcealed); try checkEqual(concealed.title, "Скрытая запись"); try checkEqual(concealed.text, "")
        try withRawDatabase(at: directory.appendingPathComponent("history.sqlite")) { db in
            try checkEqual(sqlite3_exec(db, "DELETE FROM payloads WHERE clip_id=\(id)", nil, nil, nil), SQLITE_OK)
        }
        try checkEqual(try store.summary(id: id).id, id)
        try checkThrows(try store.payload(id: id))
        try store.delete(id: id)
        do {
            _ = try store.summary(id: id)
            throw CheckFailure(description: "Expected missing summary")
        } catch HistoryError.missing { }
    }

    func testImageTextGetterDistinguishesCompletedEmptyPendingFailedAndHidden() throws {
        let pending = try insertImage("pending getter")
        let failed = try insertImage("failed getter")
        let complete = try insertImage("completed getter")
        let empty = try insertImage("empty getter")
        let hidden = try insertImage("hidden getter", concealed: true)
        let text = try insert("not an image")
        try store.failImageText(id: failed)
        try store.completeImageText(id: complete, text: "Recognized full text\nSecond line")
        try store.completeImageText(id: empty, text: "")
        try checkEqual(try store.imageText(id: pending), nil)
        try checkEqual(try store.imageText(id: failed), nil)
        try checkEqual(try store.imageText(id: complete), "Recognized full text\nSecond line")
        try checkEqual(try store.imageText(id: empty), "")
        try checkEqual(try store.imageText(id: hidden), nil)
        try checkEqual(try store.imageText(id: text), nil)
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.imageText(id: complete), "Recognized full text\nSecond line")
        try store.conceal(id: complete)
        try checkEqual(try store.imageText(id: complete), nil)
        try store.delete(id: empty)
        do {
            _ = try store.imageText(id: empty)
            throw CheckFailure(description: "Expected missing image text record")
        } catch HistoryError.missing { }
        try checkEqual(try rawSchemaVersion(at: directory.appendingPathComponent("history.sqlite")), 8)
    }

    func testDuplicateMovesToTopWithoutNewRecord() throws {
        let id = try insert("один", time: 1)
        try insert("два", time: 2)
        try checkEqual(try insert("один", time: 3), id)
        try checkEqual(try store.count(), 2)
        try checkEqual(try store.search(SearchFilter()).map(\.title), ["один", "два"])
    }

    func testMarkUsedPromotesWithoutChangingCapturedMetadata() throws {
        let original = imagePayload("used-image")
        let id = try store.insert(payload: original, kind: .image, title: "Original image", text: "Original metadata",
                                  source: "Original App", isRemote: true, date: Date(timeIntervalSince1970: 10))
        try store.setFavorite(id: id, isFavorite: true)
        try store.completeImageText(id: id, text: "recognized fixture")
        let secret = try store.insert(payload: payload("concealed-use"), kind: .text, title: "Secret", text: "Secret",
                                      source: "Password App", isConcealed: true, isRemote: true,
                                      date: Date(timeIntervalSince1970: 15))
        let newest = try insert("newer", time: 20)
        let before = try store.search(SearchFilter()).first { $0.id == id }!
        try store.markUsed(id: id, date: Date(timeIntervalSince1970: 30))
        try checkEqual(try store.search(SearchFilter()).map(\.id), [id, newest, secret])
        try checkEqual(try store.count(), 3)
        let after = try store.search(SearchFilter())[0]
        try checkEqual(after.date, before.date); try checkEqual(after.source, before.source)
        try checkEqual(after.kind, before.kind); try checkEqual(after.byteCount, before.byteCount)
        try checkEqual(after.title, before.title); try checkEqual(after.text, before.text)
        try checkEqual(after.isRemote, before.isRemote); try checkEqual(after.isFavorite, before.isFavorite)
        try checkEqual(after.isConcealed, before.isConcealed)
        try checkEqual(try store.payload(id: id), original)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(complete: 1))
        var filter = SearchFilter(); filter.query = "recognized fixture"; filter.remoteOnly = true; filter.favoritesOnly = true
        try checkEqual(try store.search(filter).map(\.id), [id])
        try store.markUsed(id: secret, date: Date(timeIntervalSince1970: 40))
        let hidden = try store.search(SearchFilter())[0]
        try checkEqual(hidden.id, secret); try checkEqual(hidden.date, Date(timeIntervalSince1970: 15))
        try check(hidden.isConcealed && hidden.isRemote && !hidden.isFavorite)
        try checkEqual(hidden.source, "Password App"); try checkEqual(hidden.title, "Скрытая запись")
        try checkEqual(hidden.text, ""); try checkEqual(try store.payload(id: secret), payload("concealed-use"))
    }

    func testMarkUsedPreservesDateFiltersAndPersistsAfterReopen() throws {
        let old = try insert("old capture", time: 10)
        let new = try insert("new capture", time: 20)
        try store.markUsed(id: old, date: Date(timeIntervalSince1970: 30))
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.search(SearchFilter()).map(\.id), [old, new])
        var filter = SearchFilter()
        filter.from = Date(timeIntervalSince1970: 10); filter.until = Date(timeIntervalSince1970: 20)
        try checkEqual(try store.search(filter).map(\.id), [old])
        try checkEqual(try store.count(filter), 1)
        filter.from = Date(timeIntervalSince1970: 20); filter.until = Date(timeIntervalSince1970: 30)
        try checkEqual(try store.search(filter).map(\.id), [new])
        filter.from = Date(timeIntervalSince1970: 30); filter.until = nil
        try checkEqual(try store.count(filter), 0)
    }

    func testUseRecencyPaginationHasStableTies() throws {
        var ids: [Int64] = []
        for index in 1...5 { ids.append(try insert("page \(index)", time: Double(index))) }
        for id in ids.prefix(2) { try store.markUsed(id: id, date: Date(timeIntervalSince1970: 10)) }
        let expected = [ids[1], ids[0], ids[4], ids[3], ids[2]]
        try checkEqual(try store.search(SearchFilter()).map(\.id), expected)
        var pages: [Int64] = []
        for offset in stride(from: 0, to: 6, by: 2) {
            pages += try store.search(SearchFilter(), limit: 2, offset: offset).map(\.id)
        }
        try checkEqual(pages, expected)
        try checkEqual(Set(pages).count, expected.count)
    }

    func testPruningKeepsRecentlyUsedRecordsAndCascadesUnusedPayloads() throws {
        let reused = try insertImage("old reused image", time: 1)
        let unused = try insertImage("newer unused image", time: 2)
        let favorite = try insertImage("favorite image", time: 0)
        try store.setFavorite(id: favorite, isFavorite: true)
        try store.completeImageText(id: reused, text: "retained OCR")
        try store.completeImageText(id: unused, text: "removed OCR")
        try store.markUsed(id: reused, date: Date(timeIntervalSince1970: 3))
        let latest = try insert("latest capture", time: 4, maxCount: 2)
        try checkEqual(try store.search(SearchFilter()).map(\.id), [latest, reused, favorite])
        try checkThrows(try store.payload(id: unused))
        try checkEqual(try store.payload(id: reused), imagePayload("old reused image"))
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1))
        var filter = SearchFilter(); filter.query = "removed OCR"
        try checkEqual(try store.count(filter), 0)
    }

    func testBytePruningKeepsRecentlyUsedRecords() throws {
        let reused = try insert("old reused", time: 1)
        let unused = try insert(String(repeating: "x", count: 5000), time: 2)
        try store.markUsed(id: reused, date: Date(timeIntervalSince1970: 3))
        let latest = try insert("latest", time: 4, maxBytes: 1000)
        try checkEqual(try store.search(SearchFilter()).map(\.id), [latest, reused])
        try checkThrows(try store.payload(id: unused))
    }

    func testRepeatCaptureAfterUseUpdatesRecencyAndSource() throws {
        let id = try insert("same payload", time: 10, source: "First App")
        let other = try insert("other payload", time: 20)
        try store.markUsed(id: id, date: Date(timeIntervalSince1970: 30))
        try store.markUsed(id: other, date: Date(timeIntervalSince1970: 40))
        try checkEqual(try store.search(SearchFilter()).map(\.id), [other, id])
        try checkEqual(try insert("same payload", time: 50, source: "Last App"), id)
        try checkEqual(try store.search(SearchFilter()).map(\.id), [id, other])
        let updated = try store.search(SearchFilter())[0]
        try checkEqual(updated.date, Date(timeIntervalSince1970: 50)); try checkEqual(updated.source, "Last App")
        try checkEqual(try store.count(), 2)
        // Explicit capture dates remain authoritative, including when they predate a prior use.
        try checkEqual(try insert("same payload", time: 35, source: "Earlier App"), id)
        try checkEqual(try store.search(SearchFilter()).map(\.id), [other, id])
    }

    func testMissingMarkUsedThrowsMissingAndLeavesStoreUsable() throws {
        do {
            try store.markUsed(id: 9999)
            throw CheckFailure(description: "Expected HistoryError.missing")
        } catch HistoryError.missing { }
        let id = try insert("usable after failed use", time: 1)
        try store.markUsed(id: id)
        try checkEqual(try store.count(), 1)
        try checkEqual(try store.search(SearchFilter())[0].date, Date(timeIntervalSince1970: 1))
    }

    func testNearbyUsesCaptureOrderAcrossSearchFilters() throws {
        let oldest = try insert("terminal error", time: 10, source: "Terminal")
        let older = try insert("a command", time: 20, source: "Terminal")
        let anchor = try insert("documentation", time: 30, kind: .link, source: "Safari")
        let newer = try insertImage("screenshot", time: 40, source: "Preview")
        try insert("latest note", time: 50, source: "Notes")
        try store.setFavorite(id: anchor, isFavorite: true)
        try store.markUsed(id: oldest, date: Date(timeIntervalSince1970: 100))
        var filter = SearchFilter(); filter.query = "documentation"; filter.kind = .link
        filter.source = "Safari"; filter.favoritesOnly = true
        filter.from = Date(timeIntervalSince1970: 30); filter.until = Date(timeIntervalSince1970: 31)
        try checkEqual(try store.search(filter).map(\.id), [anchor])
        try checkEqual(try store.search(SearchFilter()).first?.id, oldest)
        try checkEqual(try store.nearby(anchorID: anchor, before: 1, after: 1).map(\.id), [newer, anchor, older])
        try checkEqual(try store.nearby(anchorID: anchor, before: 2, after: 0).map(\.id), [anchor, older, oldest])
        // Browsing neighboring captures must not change the normal history order.
        try checkEqual(try store.search(SearchFilter()).first?.id, oldest)
    }

    func testNearbyEqualDatesHaveStableSidesWithoutDuplicates() throws {
        var ids: [Int64] = []
        for index in 0..<7 { ids.append(try insert("same time \(index)", time: 42)) }
        let anchor = ids[3]
        try checkEqual(try store.nearby(anchorID: anchor, before: 2, after: 1).map(\.id),
                       [ids[4], anchor, ids[2], ids[1]])
        let all = try store.nearby(anchorID: anchor).map(\.id)
        try checkEqual(all, Array(ids.reversed()))
        try checkEqual(Set(all).count, ids.count)
        try checkEqual(try store.nearby(anchorID: anchor, before: 0, after: 0).map(\.id), [anchor])
    }

    func testNearbyBoundsDefaultWindowAndCounts() throws {
        var ids: [Int64] = []
        for index in 0..<205 { ids.append(try insert("window \(index)", time: Double(index))) }
        let anchor = ids[102]
        try checkEqual(try store.nearby(anchorID: anchor).map(\.id), Array(ids[92...112].reversed()))
        try checkEqual(try store.nearby(anchorID: anchor, before: Int.min, after: -1).map(\.id), [anchor])
        try checkEqual(try store.nearby(anchorID: anchor, before: Int.max, after: Int.max).map(\.id),
                       Array(ids[2...202].reversed()))
        try checkEqual(try store.nearby(anchorID: ids[0], before: 7, after: 2).map(\.id), [ids[2], ids[1], ids[0]])
        try checkEqual(try store.nearby(anchorID: ids[204], before: 2, after: 7).map(\.id), [ids[204], ids[203], ids[202]])
    }

    func testNearbyRefreshesRepeatedCaptureDateAndSource() throws {
        let older = try insert("older", time: 5, source: "Terminal")
        let anchor = try insert("anchor", time: 10, source: "First App")
        let newer = try insert("newer", time: 15)
        let newest = try insert("newest", time: 20)
        try checkEqual(try store.nearby(anchorID: anchor, before: 1, after: 1).map(\.id), [newer, anchor, older])
        try checkEqual(try insert("anchor", time: 17, source: "Last App"), anchor)
        let updated = try store.nearby(anchorID: anchor, before: 1, after: 1)
        try checkEqual(updated.map(\.id), [newest, anchor, newer])
        try checkEqual(updated[1].date, Date(timeIntervalSince1970: 17))
        try checkEqual(updated[1].source, "Last App")
        try checkEqual(try insert("older", time: 18, source: "New Source"), older)
        let movedNeighbor = try store.nearby(anchorID: anchor, before: 1, after: 1)
        try checkEqual(movedNeighbor.map(\.id), [older, anchor, newer])
        try checkEqual(movedNeighbor[0].source, "New Source")
        try checkEqual(try store.count(), 4)
    }

    func testNearbyPreservesConcealmentWithoutLoadingPayloads() throws {
        let concealed = try store.insert(payload: payload("hidden payload"), kind: .text,
                                         title: "secret title", text: "secret text", source: "Password App",
                                         isConcealed: true, isRemote: true, date: Date(timeIntervalSince1970: 1))
        try store.setFavorite(id: concealed, isFavorite: true)
        let anchor = try insert("anchor", time: 2)
        let image = try insertImage("pixels", time: 3)
        try store.completeImageText(id: image, text: "recognized content")
        // Summaries remain available even when no encoded payload can be read.
        try withRawDatabase(at: directory.appendingPathComponent("history.sqlite")) { db in
            try checkEqual(sqlite3_exec(db, "DELETE FROM payloads", nil, nil, nil), SQLITE_OK)
        }
        let nearby = try store.nearby(anchorID: anchor)
        try checkEqual(nearby.map(\.id), [image, anchor, concealed])
        try checkEqual(nearby[2].title, "Скрытая запись"); try checkEqual(nearby[2].text, "")
        try check(nearby[2].isConcealed && nearby[2].isFavorite && nearby[2].isRemote)
        try checkEqual(nearby[2].source, "Password App")
        try checkEqual(nearby[0].text, "")
        try store.conceal(id: anchor)
        let hiddenAnchor = try store.nearby(anchorID: anchor, before: 0, after: 0)[0]
        try check(hiddenAnchor.isConcealed)
        try checkEqual(hiddenAnchor.title, "Скрытая запись"); try checkEqual(hiddenAnchor.text, "")
    }

    func testNearbyMissingOrDeletedAnchorThrowsAndLeavesStoreUsable() throws {
        let deleted = try insert("deleted anchor", time: 1)
        let remaining = try insert("remaining", time: 2)
        try store.delete(id: deleted)
        for id in [deleted, 9999] {
            do {
                _ = try store.nearby(anchorID: id)
                throw CheckFailure(description: "Expected HistoryError.missing")
            } catch HistoryError.missing { }
        }
        try checkEqual(try store.nearby(anchorID: remaining).map(\.id), [remaining])
        let latest = try insert("after missing anchor", time: 3)
        try checkEqual(try store.nearby(anchorID: remaining).map(\.id), [latest, remaining])
    }

    func testDateTypeAndCaseInsensitiveWordsCombine() throws {
        try insert("Проект ССЫЛКА", time: 100, kind: .link)
        try insert("проект ссылка", time: 200)
        try insert("проект ссылка", time: 300, kind: .text)
        var filter = SearchFilter(); filter.query = "ссылка ПРОЕКТ"; filter.kind = .link
        filter.from = Date(timeIntervalSince1970: 100); filter.until = Date(timeIntervalSince1970: 200)
        try checkEqual(try store.search(filter).map(\.title), ["Проект ССЫЛКА"])
        filter.until = Date(timeIntervalSince1970: 100)
        try checkEqual(try store.count(filter), 0)
    }

    func testSearchTreatsSQLWildcardsLiterally() throws {
        try insert("100%_done\\path")
        try insert("100xxdoneXpath")
        var filter = SearchFilter(); filter.query = "%_done\\"
        try checkEqual(try store.count(filter), 1)
        filter.query = "' OR 1=1 --"
        try checkEqual(try store.count(filter), 0)
    }

    func testSourceCombinesWithQueryTypeAndDate() throws {
        let wanted = try insert("Проект ссылка выбранная", time: 100, kind: .link, source: "Safari")
        try insert("проект ссылка другое приложение", time: 150, kind: .link, source: "Notes")
        try insert("проект ссылка другой тип", time: 150, kind: .text, source: "Safari")
        try insert("проект ссылка до периода", time: 99, kind: .link, source: "Safari")
        try insert("проект ссылка после периода", time: 200, kind: .link, source: "Safari")
        try insert("совсем другая запись", time: 150, kind: .link, source: "Safari")
        var filter = SearchFilter()
        filter.query = "ссылка ПРОЕКТ"; filter.kind = .link; filter.source = "Safari"
        filter.from = Date(timeIntervalSince1970: 100); filter.until = Date(timeIntervalSince1970: 200)
        try checkEqual(try store.search(filter).map(\.id), [wanted])
        try checkEqual(try store.count(filter), 1)
        filter.source = nil
        try checkEqual(try store.search(filter).count, 2)
        try checkEqual(try store.count(filter), 2)
    }

    func testSourceMatchesExactNamesAndBindsQuotesLiterally() throws {
        let source = "Editor's app ' OR 1=1 -- %_"
        let wanted = try insert("one", source: source)
        try insert("two", source: "Safari")
        try insert("three", source: "safari")
        var filter = SearchFilter(); filter.source = source
        try checkEqual(try store.search(filter).map(\.id), [wanted])
        try checkEqual(try store.count(filter), 1)
        filter.source = "Safari"
        try checkEqual(try store.search(filter).map(\.title), ["two"])
        try checkEqual(try store.count(filter), 1)
        filter.source = "' OR 1=1 --"
        try checkEqual(try store.search(filter).count, 0)
        try checkEqual(try store.count(filter), 0)
    }

    func testSourcesAreDistinctNonemptyAndSortedIgnoringCase() throws {
        try checkEqual(try store.sources(), [])
        let sources = ["браузер", "safari", "Bravo", "alpha", "Safari", "Блокнот", "", "Bravo"]
        for (index, source) in sources.enumerated() { try insert("row \(index)", source: source) }
        try checkEqual(try store.sources(), ["alpha", "Bravo", "Safari", "safari", "Блокнот", "браузер"])
    }

    func testSourceListTracksLastCopyAndDeletedRecords() throws {
        let id = try insert("same content", source: "Safari")
        try checkEqual(try insert("same content", source: "Notes"), id)
        try checkEqual(try store.sources(), ["Notes"])
        var filter = SearchFilter(); filter.source = "Safari"
        try checkEqual(try store.count(filter), 0)
        filter.source = "Notes"
        try checkEqual(try store.search(filter).map(\.id), [id])
        try store.delete(id: id)
        try checkEqual(try store.sources(), [])
    }

    func testVersionOneMigrationPreservesRecordsAndPayloads() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                    text TEXT NOT NULL, source TEXT NOT NULL, search TEXT NOT NULL, bytes INTEGER NOT NULL
                );
                CREATE TABLE payloads (clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE, data BLOB NOT NULL);
                CREATE INDEX clips_date ON clips(date DESC,id DESC);
                PRAGMA user_version=1;
                """, nil, nil, nil), SQLITE_OK)
            for index in 1...8 {
                let original = payload("legacy \(index)")
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let encoded = try encoder.encode(original)
                let hex = encoded.map { String(format: "%02x", $0) }.joined()
                try checkEqual(sqlite3_exec(db, """
                    INSERT INTO clips VALUES(\(index),'\(original.fingerprint)',\(index),'text','legacy \(index)','legacy \(index)','Old App','legacy \(index) old app',\(encoded.count));
                    INSERT INTO payloads VALUES(\(index),X'\(hex)');
                    """, nil, nil, nil), SQLITE_OK)
            }
        }
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try store.count(), 8)
        let records = try store.search(SearchFilter())
        try checkEqual(records.map(\.title), (1...8).reversed().map { "legacy \($0)" })
        try check(records.allSatisfy { !$0.isConcealed && !$0.isFavorite && !$0.isRemote })
        for index in 1...8 { try checkEqual(try store.payload(id: Int64(index)), payload("legacy \(index)")) }
        try checkEqual(try rawSchemaVersion(at: url), 8)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress())
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try store.count(), 8)
        try checkEqual(try rawSchemaVersion(at: url), 8)
    }

    func testVersionTwoMigrationPreservesConcealmentAndPayloads() throws {
        let url = directory.appendingPathComponent("version-two.sqlite")
        let original = payload("concealed-v2-fixture")
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let encoded = try encoder.encode(original)
        let hex = encoded.map { String(format: "%02x", $0) }.joined()
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                    text TEXT NOT NULL, source TEXT NOT NULL, search TEXT NOT NULL, bytes INTEGER NOT NULL,
                    is_concealed INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE payloads (clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE, data BLOB NOT NULL);
                CREATE INDEX clips_date ON clips(date DESC,id DESC);
                INSERT INTO clips VALUES(42,'\(original.fingerprint)',123,'text','Скрытая запись','','Old App','скрытая запись old app',\(encoded.count),1);
                INSERT INTO payloads VALUES(42,X'\(hex)');
                PRAGMA user_version=2;
                """, nil, nil, nil), SQLITE_OK)
        }
        store = nil; store = try makeTestHistoryStore(url: url)
        let record = try store.search(SearchFilter())[0]
        try checkEqual(try store.count(), 1)
        try checkEqual(record.id, 42); try checkEqual(record.date, Date(timeIntervalSince1970: 123))
        try checkEqual(record.title, "Скрытая запись"); try checkEqual(record.text, "")
        try checkEqual(record.source, "Old App"); try checkEqual(record.byteCount, encoded.count + 28)
        try check(record.isConcealed && !record.isFavorite && !record.isRemote)
        try checkEqual(try store.payload(id: 42), original)
        try checkEqual(try rawSchemaVersion(at: url), 8)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress())
        try store.setFavorite(id: 42, isFavorite: true)
        store = nil; store = try makeTestHistoryStore(url: url)
        try check(try store.search(SearchFilter())[0].isFavorite)
        try checkEqual(try store.payload(id: 42), original)
    }

    func testFavoriteSurvivesRepeatSetReopenDeduplicationAndConcealment() throws {
        let id = try insert("favorite-fixture", time: 100)
        try check(!store.search(SearchFilter())[0].isFavorite)
        try checkEqual(try rawSchemaVersion(at: directory.appendingPathComponent("history.sqlite")), 8)
        try store.setFavorite(id: id, isFavorite: true)
        try store.setFavorite(id: id, isFavorite: true)
        try checkEqual(try store.search(SearchFilter())[0].date, Date(timeIntervalSince1970: 100))
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try check(try store.search(SearchFilter())[0].isFavorite)
        try checkEqual(try insert("favorite-fixture", time: 200, source: "New App"), id)
        try store.conceal(id: id)
        let record = try store.search(SearchFilter())[0]
        try check(record.isFavorite && record.isConcealed)
        try checkEqual(record.id, id); try checkEqual(record.source, "New App")
        try checkEqual(try store.payload(id: id), payload("favorite-fixture"))
        try store.setFavorite(id: id, isFavorite: false)
        try store.setFavorite(id: id, isFavorite: false)
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try check(!store.search(SearchFilter())[0].isFavorite)
        try check(try store.search(SearchFilter())[0].isConcealed)
        try checkEqual(try store.count(), 1)
    }

    func testFavoriteFilterCombinesWithOtherFiltersAndPagination() throws {
        let wanted = try insert("Проект ссылка выбранная", time: 100, kind: .link, source: "Safari")
        let second = try insert("Проект ссылка вторая", time: 101, kind: .link, source: "Safari")
        let otherSource = try insert("Проект ссылка Notes", time: 150, kind: .link, source: "Notes")
        let otherKind = try insert("Проект ссылка текст", time: 150, source: "Safari")
        let otherDate = try insert("Проект ссылка поздняя", time: 200, kind: .link, source: "Safari")
        let otherQuery = try insert("Иное содержимое", time: 150, kind: .link, source: "Safari")
        try insert("Проект ссылка обычная", time: 150, kind: .link, source: "Safari")
        for id in [wanted, second, otherSource, otherKind, otherDate, otherQuery] {
            try store.setFavorite(id: id, isFavorite: true)
        }
        var filter = SearchFilter()
        filter.query = "ссылка ПРОЕКТ"; filter.kind = .link; filter.source = "Safari"
        filter.from = Date(timeIntervalSince1970: 100); filter.until = Date(timeIntervalSince1970: 200)
        filter.favoritesOnly = true
        try checkEqual(try store.count(filter), 2)
        try checkEqual(try store.search(filter).map(\.id), [second, wanted])
        try checkEqual(try store.search(filter, limit: 1).map(\.id), [second])
        try checkEqual(try store.search(filter, limit: 1, offset: 1).map(\.id), [wanted])
        filter.favoritesOnly = false
        try checkEqual(try store.count(filter), 3)
        try checkEqual(try store.search(filter).count, 3)
    }

    func testFavoriteExcludedFromCountLimitUntilNextCaptureAfterUnstar() throws {
        let favorite = try insert("old favorite", time: 1)
        try store.setFavorite(id: favorite, isFavorite: true)
        let old = try insert("old ordinary", time: 2)
        try insert("middle", time: 3)
        try insert("new", time: 4, maxCount: 2)
        try checkEqual(try store.search(SearchFilter()).map(\.title), ["new", "middle", "old favorite"])
        try checkThrows(try store.payload(id: old))
        try checkEqual(try store.payload(id: favorite), payload("old favorite"))
        try store.setFavorite(id: favorite, isFavorite: false)
        try checkEqual(try store.count(), 3)
        try checkEqual(try store.payload(id: favorite), payload("old favorite"))
        try insert("next capture", time: 5, maxCount: 2)
        try checkEqual(try store.search(SearchFilter()).map(\.title), ["next capture", "new"])
        try checkThrows(try store.payload(id: favorite))
    }

    func testFavoriteExcludedFromByteLimitAndExplicitDeletionStillCascades() throws {
        let large = String(repeating: "x", count: 5000)
        let favorite = try insert(large, time: 1)
        try store.setFavorite(id: favorite, isFavorite: true)
        let old = try insert("small old", time: 2)
        let budget = try store.search(SearchFilter()).first { $0.id == old }!.byteCount
        let newest = try insert("small new", time: 3, maxBytes: budget)
        try checkEqual(try store.search(SearchFilter()).map(\.id), [newest, favorite])
        try checkThrows(try store.payload(id: old))
        try checkEqual(try store.payload(id: favorite), payload(large))
        try store.delete(id: favorite)
        try checkEqual(try store.count(), 1)
        try checkThrows(try store.payload(id: favorite))
    }

    func testSettingMissingFavoriteThrowsMissingAndLeavesStoreUsable() throws {
        for value in [true, false] {
            do {
                try store.setFavorite(id: 42, isFavorite: value)
                throw CheckFailure(description: "Expected missing record")
            } catch HistoryError.missing { }
        }
        let id = try insert("after missing favorite")
        try store.setFavorite(id: id, isFavorite: true)
        try check(try store.search(SearchFilter())[0].isFavorite)
    }

    func testConcealedMetadataNeverContainsPayloadText() throws {
        let original = payload("sensitive-fixture-password")
        let id = try store.insert(payload: original, kind: .text, title: "private-title-fixture",
                                  text: "private-body-fixture", source: "Password App", isConcealed: true)
        let record = try store.search(SearchFilter())[0]
        try check(record.isConcealed)
        try checkEqual(record.title, "Скрытая запись")
        try checkEqual(record.text, "")
        try checkEqual(try store.payload(id: id), original)
        for secret in ["private-title-fixture", "private-body-fixture", "sensitive-fixture-password"] {
            var filter = SearchFilter(); filter.query = secret
            try checkEqual(try store.count(filter), 0)
            try checkEqual(try store.search(filter).count, 0)
        }
        var filter = SearchFilter(); filter.query = "скрытая запись"; filter.source = "Password App"
        try checkEqual(try store.search(filter).map(\.id), [id])
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try check(try store.search(SearchFilter())[0].isConcealed)
        try checkEqual(try store.payload(id: id), original)
    }

    func testDeduplicationCannotRemoveConcealment() throws {
        let secret = "sticky-mask-fixture"
        let id = try insert(secret, time: 100, source: "Notes")
        try check(!store.search(SearchFilter())[0].isConcealed)
        try checkEqual(try store.insert(payload: payload(secret), kind: .text, title: secret, text: secret,
                                       source: "Password App", isConcealed: true, date: Date(timeIntervalSince1970: 200)), id)
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try insert(secret, time: 300, source: "Safari"), id)
        let record = try store.search(SearchFilter())[0]
        try check(record.isConcealed)
        try checkEqual(record.title, "Скрытая запись"); try checkEqual(record.text, "")
        try checkEqual(record.source, "Safari"); try checkEqual(record.date, Date(timeIntervalSince1970: 300))
        try checkEqual(try store.count(), 1)
        var filter = SearchFilter(); filter.query = secret
        try checkEqual(try store.count(filter), 0)
        filter.query = "скрытая"; filter.source = "Safari"
        try checkEqual(try store.search(filter).map(\.id), [id])
        try checkEqual(try store.payload(id: id), payload(secret))
    }

    func testNewerSchemaIsNotDowngraded() throws {
        let url = directory.appendingPathComponent("future.sqlite")
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, "PRAGMA user_version=9", nil, nil, nil), SQLITE_OK)
        }
        try checkThrows(try makeTestHistoryStore(url: url))
        try checkEqual(try rawSchemaVersion(at: url), 9)
    }

    func testVersionThreeMigrationBackfillsOnlyVisibleImagesWithoutChangingHistory() throws {
        let url = directory.appendingPathComponent("version-three.sqlite")
        let entries: [(id: Int64, kind: ClipKind, concealed: Bool, favorite: Bool)] = [
            (7, .image, false, true), (9, .image, true, false), (11, .text, false, false), (12, .image, false, false)
        ]
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                    text TEXT NOT NULL, source TEXT NOT NULL, search TEXT NOT NULL, bytes INTEGER NOT NULL,
                    is_concealed INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE payloads (clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE, data BLOB NOT NULL);
                CREATE INDEX clips_date ON clips(date DESC,id DESC);
                PRAGMA user_version=3;
                """, nil, nil, nil), SQLITE_OK)
            for entry in entries {
                let original = entry.kind == .image ? imagePayload("v3-\(entry.id)") : payload("v3-\(entry.id)")
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let encoded = try encoder.encode(original)
                let hex = encoded.map { String(format: "%02x", $0) }.joined()
                let title = entry.concealed ? "Скрытая запись" : "legacy \(entry.id)"
                try checkEqual(sqlite3_exec(db, """
                    INSERT INTO clips VALUES(\(entry.id),'\(original.fingerprint)',\(entry.id),'\(entry.kind.rawValue)','\(title)','','Old App','\(SearchFilter.normalize(title)) old app',\(encoded.count),\(entry.concealed ? 1 : 0),\(entry.favorite ? 1 : 0));
                    INSERT INTO payloads VALUES(\(entry.id),X'\(hex)');
                    """, nil, nil, nil), SQLITE_OK)
            }
        }
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try rawSchemaVersion(at: url), 8)
        try checkEqual(try store.count(), 4)
        let records = try store.search(SearchFilter())
        for entry in entries {
            let record = records.first { $0.id == entry.id }!
            try checkEqual(record.kind, entry.kind); try checkEqual(record.isConcealed, entry.concealed)
            try checkEqual(record.isFavorite, entry.favorite); try checkEqual(record.source, "Old App")
            try checkEqual(record.date, Date(timeIntervalSince1970: Double(entry.id)))
            let original = entry.kind == .image ? imagePayload("v3-\(entry.id)") : payload("v3-\(entry.id)")
            try checkEqual(try store.payload(id: entry.id), original)
        }
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 2))
        try checkEqual(try store.nextPendingImageTextID(), 12)
        try check(try store.completeImageText(id: 12, text: "migrated image"))
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1))
        try checkEqual(try store.nextPendingImageTextID(), 7)
        try checkEqual(try store.count(), 4)
    }

    func testImageTextQueueEligibilityAndNewestOrdering() throws {
        try checkEqual(try store.nextPendingImageTextID(), nil)
        var ineligible: [Int64] = []
        for kind in [ClipKind.text, .link, .file, .other] {
            ineligible.append(try insert("not-image-\(kind.rawValue)", time: 900, kind: kind))
        }
        ineligible.append(try insertImage("hidden-image", time: 900, concealed: true))
        let old = try insertImage("old-image", time: 1)
        let first = try insertImage("first-tie", time: 2)
        let second = try insertImage("second-tie", time: 2)
        for id in ineligible + [9999] {
            try check(!store.completeImageText(id: id, text: "ineligible text"))
            try check(!store.failImageText(id: id))
        }
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 3))
        try checkEqual(try store.nextPendingImageTextID(), second)
        try check(try store.failImageText(id: second))
        try checkEqual(try store.nextPendingImageTextID(), first)
        try checkEqual(try insertImage("old-image", time: 3), old)
        try checkEqual(try store.nextPendingImageTextID(), old)
        try check(try store.completeImageText(id: old, text: "old result"))
        try checkEqual(try store.nextPendingImageTextID(), first)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1, failed: 1))
    }

    func testVersionFourMigrationPreservesUnknownOriginsPayloadsAndOCR() throws {
        let url = directory.appendingPathComponent("version-four.sqlite")
        let entries: [(id: Int64, concealed: Bool, favorite: Bool, status: String?)] = [
            (21, false, true, "complete"), (22, false, false, "pending"),
            (23, false, false, "failed"), (24, true, true, nil)
        ]
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                    text TEXT NOT NULL, source TEXT NOT NULL, search TEXT NOT NULL, bytes INTEGER NOT NULL,
                    is_concealed INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE payloads (clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE, data BLOB NOT NULL);
                CREATE INDEX clips_date ON clips(date DESC,id DESC);
                CREATE TABLE clip_ocr (
                    clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
                    status TEXT NOT NULL CHECK(status IN ('pending','complete','failed')),
                    text TEXT NOT NULL DEFAULT '', search TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX clip_ocr_pending ON clip_ocr(clip_id) WHERE status='pending';
                PRAGMA user_version=4;
                """, nil, nil, nil), SQLITE_OK)
            for entry in entries {
                let original = imagePayload("v4-\(entry.id)")
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let encoded = try encoder.encode(original)
                let hex = encoded.map { String(format: "%02x", $0) }.joined()
                let title = entry.concealed ? "Скрытая запись" : "legacy \(entry.id)"
                try checkEqual(sqlite3_exec(db, """
                    INSERT INTO clips VALUES(\(entry.id),'\(original.fingerprint)',\(entry.id),'image','\(title)','','loginwindow','\(SearchFilter.normalize(title)) loginwindow',\(encoded.count),\(entry.concealed ? 1 : 0),\(entry.favorite ? 1 : 0));
                    INSERT INTO payloads VALUES(\(entry.id),X'\(hex)');
                    """, nil, nil, nil), SQLITE_OK)
                if let status = entry.status {
                    let recognized = status == "complete" ? "сохранившийся текст" : ""
                    try checkEqual(sqlite3_exec(db, "INSERT INTO clip_ocr VALUES(\(entry.id),'\(status)','\(recognized)','\(SearchFilter.normalize(recognized))')", nil, nil, nil), SQLITE_OK)
                }
            }
        }
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try rawSchemaVersion(at: url), 8)
        let records = try store.search(SearchFilter())
        try checkEqual(records.count, entries.count)
        for entry in entries {
            let record = records.first { $0.id == entry.id }!
            try check(!record.isRemote)
            try checkEqual(record.source, "loginwindow")
            try checkEqual(record.date, Date(timeIntervalSince1970: Double(entry.id)))
            try checkEqual(record.isConcealed, entry.concealed); try checkEqual(record.isFavorite, entry.favorite)
            try checkEqual(try store.payload(id: entry.id), imagePayload("v4-\(entry.id)"))
        }
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1, failed: 1))
        try checkEqual(try store.nextPendingImageTextID(), 22)
        var filter = SearchFilter(); filter.query = "сохранившийся текст"
        try checkEqual(try store.search(filter).map(\.id), [21])
        filter.remoteOnly = true
        try checkEqual(try store.count(filter), 0)
        filter.query = ""
        try checkEqual(try store.count(filter), 0)
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try rawSchemaVersion(at: url), 8)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1, failed: 1))
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, "UPDATE clips SET is_remote=2 WHERE id=21", nil, nil, nil), SQLITE_CONSTRAINT)
        }
        try check(try store.search(SearchFilter()).allSatisfy { !$0.isRemote })
    }

    func testVersionFiveMigrationPreservesOrderingMetadataPayloadsAndOCR() throws {
        let url = directory.appendingPathComponent("version-five.sqlite")
        let entries: [(id: Int64, date: Double, remote: Bool, concealed: Bool, favorite: Bool, status: String?)] = [
            (31, 0, true, false, true, "complete"), (32, -20, false, false, false, "pending"),
            (33, 20, true, false, false, "failed"), (34, 20, true, true, true, nil)
        ]
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                    text TEXT NOT NULL, source TEXT NOT NULL, search TEXT NOT NULL, bytes INTEGER NOT NULL,
                    is_concealed INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0,
                    is_remote INTEGER NOT NULL DEFAULT 0 CHECK(is_remote IN (0,1))
                );
                CREATE TABLE payloads (clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE, data BLOB NOT NULL);
                CREATE INDEX clips_date ON clips(date DESC,id DESC);
                CREATE TABLE clip_ocr (
                    clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
                    status TEXT NOT NULL CHECK(status IN ('pending','complete','failed')),
                    text TEXT NOT NULL DEFAULT '', search TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX clip_ocr_pending ON clip_ocr(clip_id) WHERE status='pending';
                PRAGMA user_version=5;
                """, nil, nil, nil), SQLITE_OK)
            for entry in entries {
                let original = imagePayload("v5-\(entry.id)")
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let encoded = try encoder.encode(original)
                let hex = encoded.map { String(format: "%02x", $0) }.joined()
                let title = entry.concealed ? "Скрытая запись" : "legacy \(entry.id)"
                try checkEqual(sqlite3_exec(db, """
                    INSERT INTO clips VALUES(\(entry.id),'\(original.fingerprint)',\(entry.date),'image','\(title)','','Old App','\(SearchFilter.normalize(title)) old app',\(encoded.count),\(entry.concealed ? 1 : 0),\(entry.favorite ? 1 : 0),\(entry.remote ? 1 : 0));
                    INSERT INTO payloads VALUES(\(entry.id),X'\(hex)');
                    """, nil, nil, nil), SQLITE_OK)
                if let status = entry.status {
                    let recognized = status == "complete" ? "migration OCR fixture" : ""
                    try checkEqual(sqlite3_exec(db, "INSERT INTO clip_ocr VALUES(\(entry.id),'\(status)','\(recognized)','\(SearchFilter.normalize(recognized))')", nil, nil, nil), SQLITE_OK)
                }
            }
        }
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try rawSchemaVersion(at: url), 8)
        let records = try store.search(SearchFilter())
        try checkEqual(records.map(\.id), [34, 33, 31, 32])
        for entry in entries {
            let record = records.first { $0.id == entry.id }!
            try checkEqual(record.date, Date(timeIntervalSince1970: entry.date))
            try checkEqual(record.kind, .image); try checkEqual(record.source, "Old App")
            try checkEqual(record.title, entry.concealed ? "Скрытая запись" : "legacy \(entry.id)")
            try checkEqual(record.text, ""); try checkEqual(record.isRemote, entry.remote)
            try checkEqual(record.isConcealed, entry.concealed); try checkEqual(record.isFavorite, entry.favorite)
            try checkEqual(try store.payload(id: entry.id), imagePayload("v5-\(entry.id)"))
        }
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1, failed: 1))
        var filter = SearchFilter(); filter.query = "migration OCR fixture"
        try checkEqual(try store.search(filter).map(\.id), [31])
        try store.markUsed(id: 31, date: Date(timeIntervalSince1970: 100))
        store = nil; store = try makeTestHistoryStore(url: url)
        try checkEqual(try store.search(SearchFilter()).map(\.id), [31, 34, 33, 32])
        try checkEqual(try store.search(filter)[0].date, Date(timeIntervalSince1970: 0))
        try checkEqual(try store.count(), entries.count)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1, failed: 1))
    }

    func testRemoteAndConcealedFiltersCombineWithPaginationAndExistingFilters() throws {
        @discardableResult func add(_ value: String, remote: Bool = true, concealed: Bool = true, favorite: Bool = true,
                 kind: ClipKind = .text, source: String = "Safari", time: Double = 100) throws -> Int64 {
            let id = try store.insert(payload: payload(value), kind: kind, title: "Скрытая запись", text: value,
                                      source: source, isConcealed: concealed, isRemote: remote,
                                      date: Date(timeIntervalSince1970: time))
            if favorite { try store.setFavorite(id: id, isFavorite: true) }
            return id
        }
        let first = try add("first-secret-fixture")
        let second = try add("second-secret-fixture")
        let local = try add("local-secret-fixture", remote: false)
        let visible = try add("visible-fixture", concealed: false)
        try add("not-favorite-fixture", favorite: false)
        try add("other-kind-fixture", kind: .link)
        try add("other-source-fixture", source: "Safari Other")
        try add("early-fixture", time: 99)
        try add("late-fixture", time: 200)
        var filter = SearchFilter()
        filter.remoteOnly = true; filter.concealedOnly = true; filter.favoritesOnly = true
        filter.kind = .text; filter.source = "Safari"; filter.query = "скрытая SAFARI"
        filter.from = Date(timeIntervalSince1970: 100); filter.until = Date(timeIntervalSince1970: 200)
        try checkEqual(try store.count(filter), 2)
        try checkEqual(try store.search(filter).map(\.id), [second, first])
        try checkEqual(try store.search(filter, limit: 1).map(\.id), [second])
        try checkEqual(try store.search(filter, limit: 1, offset: 1).map(\.id), [first])
        try checkEqual(try store.search(filter, limit: 1, offset: 2).count, 0)
        filter.remoteOnly = false
        try checkEqual(try store.search(filter).map(\.id), [local, second, first])
        filter.remoteOnly = true; filter.concealedOnly = false
        try checkEqual(try store.search(filter).map(\.id), [visible, second, first])
        filter.concealedOnly = true; filter.query = "secret-fixture"
        try checkEqual(try store.count(filter), 0)
        try checkEqual(try store.search(filter).count, 0)
        filter = SearchFilter(); filter.concealedOnly = true
        try checkEqual(try store.count(filter), 8)
        try checkEqual(try store.count(), 9)
    }

    func testOriginFollowsLatestCaptureWhileConcealmentFavoriteAndOCRPersist() throws {
        let original = imagePayload("origin-switch-pixels")
        func capture(remote: Bool, source: String, concealed: Bool = false, time: Double) throws -> Int64 {
            try store.insert(payload: original, kind: .image, title: "Картинка", text: "", source: source,
                             isConcealed: concealed, isRemote: remote, date: Date(timeIntervalSince1970: time))
        }
        let id = try capture(remote: false, source: "Safari", time: 1)
        try store.setFavorite(id: id, isFavorite: true)
        try check(try store.completeImageText(id: id, text: "recognized origin fixture"))
        try checkEqual(try capture(remote: true, source: "Device source", time: 2), id)
        var filter = SearchFilter(); filter.remoteOnly = true; filter.query = "recognized origin fixture"
        try checkEqual(try store.search(filter).map(\.id), [id]); try checkEqual(try store.count(filter), 1)
        try checkEqual(try store.sources(), [])
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(complete: 1))
        try checkEqual(try capture(remote: false, source: "Notes", time: 3), id)
        try checkEqual(try store.count(filter), 0)
        filter.remoteOnly = false
        let local = try store.search(filter)[0]
        try check(!local.isRemote && local.isFavorite && !local.isConcealed)
        try checkEqual(local.source, "Notes"); try checkEqual(local.date, Date(timeIntervalSince1970: 3))
        try checkEqual(try store.sources(), ["Notes"])
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(complete: 1))
        try checkEqual(try capture(remote: true, source: "", concealed: true, time: 4), id)
        try checkEqual(try capture(remote: false, source: "Notes", time: 5), id)
        try checkEqual(try capture(remote: true, source: "", time: 6), id)
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let hidden = try store.search(SearchFilter())[0]
        try check(hidden.isRemote && hidden.isConcealed && hidden.isFavorite)
        try checkEqual(hidden.id, id); try checkEqual(hidden.source, "")
        try checkEqual(hidden.title, "Скрытая запись"); try checkEqual(hidden.text, "")
        try checkEqual(try store.imageTextProgress(), ImageTextProgress())
        try checkEqual(try store.count(filter), 0)
        filter = SearchFilter(); filter.remoteOnly = true; filter.concealedOnly = true; filter.favoritesOnly = true
        try checkEqual(try store.search(filter).map(\.id), [id])
        try checkEqual(try store.payload(id: id), original)
        try checkEqual(try store.count(), 1)
    }

    func testSourcesExcludeRemoteRowsWithoutHidingSharedLocalApps() throws {
        let remote = try store.insert(payload: payload("remote-row"), kind: .text, title: "remote", text: "",
                                      source: "Remote Only", isRemote: true)
        try store.insert(payload: payload("remote-shared-row"), kind: .text, title: "remote", text: "",
                         source: "Shared", isRemote: true)
        let local = try insert("local-shared-row", source: "Shared")
        try insert("unknown-row", source: "")
        try checkEqual(try store.sources(), ["Shared"])
        try store.delete(id: local)
        try checkEqual(try store.sources(), [])
        try checkEqual(try insert("remote-row", source: "Now Local"), remote)
        try checkEqual(try store.sources(), ["Now Local"])
        var filter = SearchFilter(); filter.remoteOnly = true
        try checkEqual(try store.count(filter), 1)
    }

    func testImageTextSearchCombinesBaseWordsFiltersAndLiteralWildcards() throws {
        let wanted = try insertImage("wanted-pixels", time: 100, title: "Документ", source: "Safari")
        try store.setFavorite(id: wanted, isFavorite: true)
        let recognized = "ПРОЕКТ Invoice СЧЁТ café"
        try check(try store.completeImageText(id: wanted, text: recognized + " 100%_done\\path"))
        let otherSource = try insertImage("other-source", time: 150, title: "Документ", source: "Notes")
        let otherDate = try insertImage("other-date", time: 200, title: "Документ", source: "Safari")
        let ordinary = try insertImage("ordinary", time: 150, title: "Документ", source: "Safari")
        for id in [otherSource, otherDate, ordinary] { try store.completeImageText(id: id, text: recognized) }
        for id in [otherSource, otherDate] { try store.setFavorite(id: id, isFavorite: true) }
        let plainText = try insert("Документ " + recognized, time: 150, source: "Safari")
        try store.setFavorite(id: plainText, isFavorite: true)
        try insertImage("pending", time: 150, title: "Документ", source: "Safari")
        var filter = SearchFilter()
        filter.query = "документ проект INVOICE счет CAFE"; filter.kind = .image; filter.source = "Safari"
        filter.favoritesOnly = true
        filter.from = Date(timeIntervalSince1970: 100); filter.until = Date(timeIntervalSince1970: 200)
        try checkEqual(try store.search(filter).map(\.id), [wanted])
        try checkEqual(try store.count(filter), 1)
        filter.query = "SAFARI проект"
        try checkEqual(try store.search(filter).map(\.id), [wanted])
        filter = SearchFilter(); filter.query = "%_done\\path"
        try checkEqual(try store.search(filter).map(\.id), [wanted])
        try checkEqual(try store.count(filter), 1)
        filter.query = "' OR 1=1 --"
        try checkEqual(try store.count(filter), 0)
        filter.query = "проект"; filter.kind = .image
        try checkEqual(try store.count(filter), 4)
        try checkEqual(try store.search(filter).count, 4)
        let unchanged = try store.search(SearchFilter()).first { $0.id == wanted }!
        try checkEqual(unchanged.title, "Документ"); try checkEqual(unchanged.text, "")
        try checkEqual(try store.payload(id: wanted), imagePayload("wanted-pixels"))
    }

    func testImageTextDeduplicationPreservesResultButConcealmentRemovesIt() throws {
        let id = try insertImage("same-pixels", time: 1, source: "Old App")
        try check(try store.completeImageText(id: id, text: "recognized-secret-fixture"))
        try store.setFavorite(id: id, isFavorite: true)
        try checkEqual(try insertImage("same-pixels", time: 2, source: "New App"), id)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(complete: 1))
        try checkEqual(try store.nextPendingImageTextID(), nil)
        var filter = SearchFilter(); filter.query = "recognized-secret-fixture NEW"; filter.favoritesOnly = true
        try checkEqual(try store.search(filter).map(\.id), [id])
        filter.query = "recognized-secret-fixture OLD"
        try checkEqual(try store.count(filter), 0)
        try checkEqual(try insertImage("same-pixels", time: 3, source: "Password App", concealed: true), id)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress())
        try checkEqual(try insertImage("same-pixels", time: 4, source: "Another App"), id)
        try check(!store.completeImageText(id: id, text: "late-result-fixture"))
        try check(!store.failImageText(id: id))
        try checkEqual(try store.nextPendingImageTextID(), nil)
        filter = SearchFilter(); filter.query = "recognized-secret-fixture"
        try checkEqual(try store.count(filter), 0)
        let record = try store.search(SearchFilter())[0]
        try check(record.isConcealed && record.isFavorite)
        try checkEqual(try store.payload(id: id), imagePayload("same-pixels"))
    }

    func testConcealedAndDeletedImagesRejectLateTextResults() throws {
        let hiddenPending = try insertImage("will-hide-pending")
        let hiddenComplete = try insertImage("will-hide-complete")
        try check(try store.completeImageText(id: hiddenComplete, text: "erase-index-fixture"))
        try store.conceal(id: hiddenPending); try store.conceal(id: hiddenComplete)
        for id in [hiddenPending, hiddenComplete] {
            try check(!store.completeImageText(id: id, text: "late-hidden-fixture"))
            try check(!store.failImageText(id: id))
        }
        let deletedPending = try insertImage("will-delete-pending")
        let deletedComplete = try insertImage("will-delete-complete")
        try check(try store.completeImageText(id: deletedComplete, text: "delete-index-fixture"))
        try store.delete(id: deletedPending); try store.delete(id: deletedComplete)
        for id in [deletedPending, deletedComplete] {
            try check(!store.completeImageText(id: id, text: "late-deleted-fixture"))
            try check(!store.failImageText(id: id))
        }
        try store.retryFailedImageText()
        try checkEqual(try store.imageTextProgress(), ImageTextProgress())
        try checkEqual(try store.nextPendingImageTextID(), nil)
        for query in ["erase-index", "delete-index", "late-hidden", "late-deleted"] {
            var filter = SearchFilter(); filter.query = query
            try checkEqual(try store.count(filter), 0)
            try checkEqual(try store.search(filter).count, 0)
        }
        try checkEqual(try store.payload(id: hiddenPending), imagePayload("will-hide-pending"))
        try checkEqual(try store.count(), 2)
    }

    func testPruningCascadesImageTextButKeepsFavorites() throws {
        let favorite = try insertImage("favorite-pixels", time: 1)
        try store.setFavorite(id: favorite, isFavorite: true)
        try store.completeImageText(id: favorite, text: "favorite OCR")
        let oldComplete = try insertImage("old-complete", time: 2)
        try store.completeImageText(id: oldComplete, text: "pruned-complete-fixture")
        let oldPending = try insertImage("old-pending", time: 3)
        try insert("new text", time: 4, maxCount: 1)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(complete: 1))
        for id in [oldComplete, oldPending] {
            try check(!store.completeImageText(id: id, text: "late-pruned-fixture"))
            try checkThrows(try store.payload(id: id))
        }
        let large = try insertImage(String(repeating: "x", count: 5000), time: 5)
        try store.completeImageText(id: large, text: "byte-pruned-fixture")
        try insert("new small", time: 6, maxBytes: 1000)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(complete: 1))
        try check(!store.completeImageText(id: large, text: "late-byte-pruned-fixture"))
        var filter = SearchFilter(); filter.query = "pruned"
        try checkEqual(try store.count(filter), 0)
        filter.query = "favorite OCR"
        try checkEqual(try store.search(filter).map(\.id), [favorite])
        try store.delete(id: favorite)
        try checkEqual(try store.imageTextProgress().total, 0)
    }

    func testEmptyImageTextFailureRetryAndPendingJobsSurviveReopen() throws {
        let empty = try insertImage("empty", time: 1)
        let failed = try insertImage("failed", time: 2)
        let pending = try insertImage("pending", time: 3)
        try check(try store.completeImageText(id: empty, text: ""))
        try check(!store.completeImageText(id: empty, text: "must-not-replace"))
        try check(!store.failImageText(id: empty))
        try check(try store.failImageText(id: failed))
        try check(!store.failImageText(id: failed))
        try check(!store.completeImageText(id: failed, text: "must-retry-first"))
        try checkEqual(try insertImage("failed", time: 4), failed)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1, failed: 1))
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.nextPendingImageTextID(), pending)
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 1, complete: 1, failed: 1))
        try store.retryFailedImageText(); try store.retryFailedImageText()
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(pending: 2, complete: 1))
        try checkEqual(try store.nextPendingImageTextID(), failed)
        try check(try store.completeImageText(id: failed, text: "retried result"))
        try check(try store.completeImageText(id: pending, text: "pending result"))
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.imageTextProgress(), ImageTextProgress(complete: 3))
        try checkEqual(try store.nextPendingImageTextID(), nil)
        var filter = SearchFilter(); filter.query = "must-not-replace"
        try checkEqual(try store.count(filter), 0)
        filter.query = "retried result"
        try checkEqual(try store.search(filter).map(\.id), [failed])
    }

    func testImageTextBoundsRawAndNormalizedIndexWithoutChangingPayload() throws {
        let id = try insertImage("bounded-pixels")
        let before = try store.search(SearchFilter())[0]
        let recognized = String(repeating: "ß", count: 200_000) + "outside-index-limit"
        try check(try store.completeImageText(id: id, text: recognized))
        var raw = "", normalized = ""
        try withRawDatabase(at: directory.appendingPathComponent("history.sqlite")) { db in
            var statement: OpaquePointer?
            try checkEqual(sqlite3_prepare_v2(db, "SELECT text,search FROM clip_ocr WHERE clip_id=\(id)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try checkEqual(sqlite3_step(statement), SQLITE_ROW)
            raw = String(cString: sqlite3_column_text(statement, 0))
            normalized = String(cString: sqlite3_column_text(statement, 1))
        }
        try checkEqual(raw, String(recognized.prefix(200_000)))
        try checkEqual(normalized, String(SearchFilter.normalize(raw).prefix(200_000)))
        try check(raw.count <= 200_000 && normalized.count <= 200_000)
        var filter = SearchFilter(); filter.query = "outside-index-limit"
        try checkEqual(try store.count(filter), 0)
        let after = try store.search(SearchFilter())[0]
        try checkEqual(before.byteCount, after.byteCount); try checkEqual(before.title, after.title)
        try checkEqual(before.text, after.text); try checkEqual(before.date, after.date)
        try checkEqual(try store.payload(id: id), imagePayload("bounded-pixels"))
    }

    func testManualConcealmentPreservesPayloadAndSurvivesReopen() throws {
        let secret = "manually-hidden-fixture"
        let id = try insert(secret, source: "БРАУЗЕР")
        var filter = SearchFilter(); filter.query = secret
        try checkEqual(try store.count(filter), 1)
        let original = try store.search(filter)[0]
        try store.conceal(id: id)
        try checkEqual(try store.search(filter).count, 0)
        try checkEqual(try store.count(filter), 0)
        try checkEqual(try store.payload(id: id), payload(secret))
        try store.conceal(id: id)
        store = nil; store = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.count(filter), 0)
        filter.query = "скрытая браузер"; filter.source = "БРАУЗЕР"
        let concealed = try store.search(filter)[0]
        try check(concealed.isConcealed)
        try checkEqual(concealed.title, "Скрытая запись"); try checkEqual(concealed.text, "")
        try checkEqual(concealed.id, original.id); try checkEqual(concealed.date, original.date)
        try checkEqual(concealed.kind, original.kind); try checkEqual(concealed.byteCount, original.byteCount + 28)
        try checkEqual(try store.count(), 1)
        try checkEqual(try store.payload(id: id), payload(secret))
    }

    func testConcealingMissingRecordLeavesStoreUsable() throws {
        try checkThrows(try store.conceal(id: 42))
        let id = try insert("after failed conceal")
        try checkEqual(try store.count(), 1)
        try store.conceal(id: id)
        try check(try store.search(SearchFilter())[0].isConcealed)
    }

    func testReadOnlyDoesNotCreateOrMigrateHistory() throws {
        let absent = directory.appendingPathComponent("missing/history.sqlite")
        try checkThrows(try makeTestHistoryStore(url: absent, mode: .readOnly))
        try check(!FileManager.default.fileExists(atPath: absent.deletingLastPathComponent().path))

        let url = directory.appendingPathComponent("history.sqlite")
        let id = try insert("read-only version fixture")
        for version in [0, 5, 6, 7, 9] {
            try withRawDatabase(at: url) { db in
                try checkEqual(sqlite3_exec(db, "PRAGMA user_version=\(version)", nil, nil, nil), SQLITE_OK)
            }
            try checkThrows(try makeTestHistoryStore(url: url, mode: .readOnly))
            try checkEqual(try rawSchemaVersion(at: url), version)
            try checkEqual(try store.payload(id: id), payload("read-only version fixture"))
        }
        try withRawDatabase(at: url) { db in
            try checkEqual(sqlite3_exec(db, "PRAGMA user_version=8", nil, nil, nil), SQLITE_OK)
        }
        let reader = try makeTestHistoryStore(url: url, mode: .readOnly)
        try checkEqual(try reader.summary(id: id).text, "read-only version fixture")
    }

    func testReadOnlyRejectsWritesAndSeesNewWriterCommits() throws {
        let first = try insert("first read-only record", time: 1)
        let reader = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"), mode: .readOnly)
        try checkEqual(try reader.count(), 1)
        try checkThrows(try reader.delete(id: first))
        try checkThrows(try reader.markUsed(id: first))
        try checkThrows(try reader.setFavorite(id: first, isFavorite: true))
        try checkThrows(try reader.conceal(id: first))
        try checkThrows(try reader.insert(payload: payload("forbidden"), kind: .text,
                                         title: "forbidden", text: "forbidden", source: "Test"))
        try checkEqual(try reader.count(), 1)
        let second = try insert("second read-only record", time: 2)
        try checkEqual(try reader.search(SearchFilter()).map(\.id), [second, first])
        try checkEqual(try reader.summary(id: first).date, Date(timeIntervalSince1970: 1))
        try check(!reader.summary(id: first).isFavorite)
        try check(!reader.summary(id: first).isConcealed)
    }

    func testReadSnapshotIsCoherentAcrossConcurrentCommitsAndEndsAfterFailure() throws {
        let first = try insert("snapshot first", time: 1)
        let reader = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"), mode: .readOnly)
        var second: Int64 = 0
        try reader.withReadSnapshot {
            try checkEqual(try reader.search(SearchFilter()).map(\.id), [first])
            second = try insert("snapshot second", time: 2)
            try checkEqual(try reader.count(), 1)
            try checkEqual(try reader.nearby(anchorID: first).map(\.id), [first])
            try checkEqual(try reader.withReadSnapshot { try reader.visibleContent(id: first).summary.id }, first)
        }
        try checkEqual(try reader.search(SearchFilter()).map(\.id), [second, first])
        try checkThrows(try reader.withReadSnapshot {
            _ = try reader.count()
            throw CheckFailure(description: "Expected snapshot rollback")
        })
        try store.delete(id: second)
        try checkEqual(try reader.count(), 1)
        try checkEqual(try reader.nearby(anchorID: first).map(\.id), [first])
    }

    func testVisibleSearchFiltersConcealedRowsBeforePagination() throws {
        let first = try insert("visible row first", time: 1)
        let hidden = try insert("visible row hidden", time: 2)
        let third = try insert("visible row third", time: 3)
        try store.conceal(id: hidden)
        var filter = SearchFilter(); filter.excludesConcealed = true
        try checkEqual(try store.search(filter, limit: 1).map(\.id), [third])
        try checkEqual(try store.search(filter, limit: 1, offset: 1).map(\.id), [first])
        try checkEqual(try store.count(filter), 2)
        filter.query = "скрытая"
        try checkEqual(try store.search(filter).count, 0)
        filter.query = ""; filter.concealedOnly = true
        try checkEqual(try store.count(filter), 0)
        filter.excludesConcealed = false
        try checkEqual(try store.search(filter).map(\.id), [hidden])
    }

    func testVisibleNearbySkipsHiddenNeighborsAndRejectsHiddenAnchor() throws {
        let older = try insert("nearby visible older", time: 1)
        let hiddenOlder = try insert("nearby hidden older", time: 2)
        let anchor = try insert("nearby visible anchor", time: 3)
        let hiddenNewer = try insert("nearby hidden newer", time: 4)
        let newer = try insert("nearby visible newer", time: 5)
        try store.conceal(id: hiddenOlder); try store.conceal(id: hiddenNewer)
        try checkEqual(try store.nearby(anchorID: anchor, before: 1, after: 1, includeConcealed: false).map(\.id),
                       [newer, anchor, older])
        try checkEqual(try store.nearby(anchorID: anchor, before: 1, after: 1).map(\.id),
                       [hiddenNewer, anchor, hiddenOlder])
        do {
            _ = try store.nearby(anchorID: hiddenOlder, includeConcealed: false)
            throw CheckFailure(description: "Expected hidden anchor to be missing")
        } catch HistoryError.missing { }
        try checkEqual(try store.nearby(anchorID: anchor, includeConcealed: false).count, 3)
    }

    func testVisibleContentReturnsOnlyEligiblePayloadAndCompletedOCR() throws {
        let text = try insert("complete text payload", time: 1)
        let link = try insert("https://example.test", time: 2, kind: .link)
        let file = try insert("/tmp/fixture.txt", time: 3, kind: .file)
        let other = try insert("opaque payload fixture", time: 4, kind: .other)
        let image = try insertImage("image bytes")
        let pending = try insertImage("pending image bytes")
        let empty = try insertImage("empty image bytes")
        let failed = try insertImage("failed image bytes")
        try store.completeImageText(id: image, text: "Completed recognition")
        try store.completeImageText(id: empty, text: "")
        try store.failImageText(id: failed)
        for id in [text, link, file] {
            let content = try store.visibleContent(id: id)
            try checkEqual(content.summary.id, id)
            try checkEqual(content.payload, try store.payload(id: id))
            try checkEqual(content.imageText, nil)
        }
        try checkEqual(try store.visibleContent(id: image).imageText, "Completed recognition")
        try checkEqual(try store.visibleContent(id: empty).imageText, "")
        for id in [pending, failed, other] { try checkEqual(try store.visibleContent(id: id).imageText, nil) }
        // Missing binary payloads do not affect metadata/OCR reads for image and other records.
        try withRawDatabase(at: directory.appendingPathComponent("history.sqlite")) { db in
            try checkEqual(sqlite3_exec(db, "DELETE FROM payloads WHERE clip_id IN (\(image),\(other))", nil, nil, nil), SQLITE_OK)
        }
        for id in [image, pending, empty, failed, other] {
            try checkEqual(try store.visibleContent(id: id).payload, nil)
        }
        try store.conceal(id: text); try store.conceal(id: image)
        for id in [text, image, 999_999] {
            do {
                _ = try store.visibleContent(id: id)
                throw CheckFailure(description: "Expected concealed or absent content to be missing")
            } catch HistoryError.missing { }
        }
        try checkEqual(try store.payload(id: text), payload("complete text payload"))
    }

    func testExplicitRevealReadsOriginalWithoutRemovingConcealment() throws {
        let secret = try insert("original concealed payload", time: 1)
        let image = try insertImage("concealed image bytes")
        try store.completeImageText(id: image, text: "recognition to be removed")
        try store.setFavorite(id: secret, isFavorite: true)
        try store.conceal(id: secret)
        try store.conceal(id: image)
        let originalPayload = try store.payload(id: secret)
        let order = try store.search(SearchFilter()).map(\.id)
        let reader = try makeTestHistoryStore(url: directory.appendingPathComponent("history.sqlite"), mode: .readOnly)

        let content = try reader.revealedContent(id: secret)
        try checkEqual(content.payload, originalPayload)
        try checkEqual(content.summary.title, HistoryStore.concealedTitle)
        try checkEqual(content.summary.text, "")
        try check(content.summary.isConcealed)
        try check(content.summary.isFavorite)
        try checkEqual(content.summary.date, Date(timeIntervalSince1970: 1))
        try checkEqual(content.imageText, nil)
        try checkEqual(try reader.revealedContent(id: image).payload, nil)
        try checkEqual(try reader.revealedContent(id: image).imageText, nil)
        try checkThrows(try reader.visibleContent(id: secret))
        try checkThrows(try reader.revealedContent(id: Int64.max))
        try checkEqual(try store.search(SearchFilter()).map(\.id), order)
        try checkEqual(try store.payload(id: secret), originalPayload)
        try check(try store.summary(id: secret).isConcealed)
        var query = SearchFilter()
        query.query = "original concealed payload"
        try checkEqual(try store.count(query), 0)
    }

    private func withRawDatabase(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        let status = sqlite3_open(url.path, &db)
        defer { sqlite3_close(db) }
        try checkEqual(status, SQLITE_OK)
        guard let db else { throw CheckFailure(description: "SQLite fixture connection unavailable") }
        try body(db)
    }

    private func rawSchemaVersion(at url: URL) throws -> Int {
        var version = -1
        try withRawDatabase(at: url) { db in
            var statement: OpaquePointer?
            try checkEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try checkEqual(sqlite3_step(statement), SQLITE_ROW)
            version = Int(sqlite3_column_int(statement, 0))
        }
        return version
    }

    func testPruningRemovesOldestPayloadAndRetainsNewest() throws {
        let old = try insert("old", time: 1)
        try insert("middle", time: 2)
        try insert("new", time: 3, maxCount: 2)
        try checkEqual(try store.count(), 2)
        try checkThrows(try store.payload(id: old))
        try checkEqual(try store.search(SearchFilter()).map(\.title), ["new", "middle"])
    }

    func testByteLimitPrunesAndDeleteCascades() throws {
        try insert(String(repeating: "x", count: 5000), time: 1)
        let id = try insert("small", time: 2, maxBytes: 1000)
        try checkEqual(try store.count(), 1)
        try store.delete(id: id)
        try checkEqual(try store.count(), 0)
        try checkThrows(try store.payload(id: id))
    }

    func testPaginationHasStableTieOrdering() throws {
        for index in 0..<25 { try insert("row \(index)") }
        let first = try store.search(SearchFilter(), limit: 10)
        let second = try store.search(SearchFilter(), limit: 10, offset: 10)
        try checkEqual(first.count, 10); try checkEqual(second.count, 10)
        try check(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        try checkEqual(first.first?.title, "row 24")
    }

    func testFingerprintPreservesGroupingButIgnoresTypeOrdering() throws {
        let a = Representation(type: "a", data: Data([1])); let b = Representation(type: "b", data: Data([2]))
        try checkEqual(ClipPayload(items: [[a, b]]).fingerprint, ClipPayload(items: [[b, a]]).fingerprint)
        try checkNotEqual(ClipPayload(items: [[a, b]]).fingerprint, ClipPayload(items: [[a], [b]]).fingerprint)
    }

    func testInvalidPayloadDoesNotAlterHistory() throws {
        try insert("existing")
        try checkThrows(try store.insert(payload: ClipPayload(items: [[]]), kind: .other, title: "", text: "", source: ""))
        try checkEqual(try store.count(), 1)
    }
}
