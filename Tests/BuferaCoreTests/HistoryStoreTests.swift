import Foundation
import BuferaCore
import CSQLite

final class HistoryStoreTests {
    private var directory: URL!
    private var store: HistoryStore!

    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    }
    func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: directory) }
    private func payload(_ value: String) -> ClipPayload {
        ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(value.utf8))]])
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
        store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.payload(id: id), original)
    }

    func testDuplicateMovesToTopWithoutNewRecord() throws {
        let id = try insert("один", time: 1)
        try insert("два", time: 2)
        try checkEqual(try insert("один", time: 3), id)
        try checkEqual(try store.count(), 2)
        try checkEqual(try store.search(SearchFilter()).map(\.title), ["один", "два"])
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
        store = nil; store = try HistoryStore(url: url)
        try checkEqual(try store.count(), 8)
        let records = try store.search(SearchFilter())
        try checkEqual(records.map(\.title), (1...8).reversed().map { "legacy \($0)" })
        try check(records.allSatisfy { !$0.isConcealed && !$0.isFavorite })
        for index in 1...8 { try checkEqual(try store.payload(id: Int64(index)), payload("legacy \(index)")) }
        try checkEqual(try rawSchemaVersion(at: url), 3)
        store = nil; store = try HistoryStore(url: url)
        try checkEqual(try store.count(), 8)
        try checkEqual(try rawSchemaVersion(at: url), 3)
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
        store = nil; store = try HistoryStore(url: url)
        let record = try store.search(SearchFilter())[0]
        try checkEqual(try store.count(), 1)
        try checkEqual(record.id, 42); try checkEqual(record.date, Date(timeIntervalSince1970: 123))
        try checkEqual(record.title, "Скрытая запись"); try checkEqual(record.text, "")
        try checkEqual(record.source, "Old App"); try checkEqual(record.byteCount, encoded.count)
        try check(record.isConcealed && !record.isFavorite)
        try checkEqual(try store.payload(id: 42), original)
        try checkEqual(try rawSchemaVersion(at: url), 3)
        try store.setFavorite(id: 42, isFavorite: true)
        store = nil; store = try HistoryStore(url: url)
        try check(try store.search(SearchFilter())[0].isFavorite)
        try checkEqual(try store.payload(id: 42), original)
    }

    func testFavoriteSurvivesRepeatSetReopenDeduplicationAndConcealment() throws {
        let id = try insert("favorite-fixture", time: 100)
        try check(!store.search(SearchFilter())[0].isFavorite)
        try checkEqual(try rawSchemaVersion(at: directory.appendingPathComponent("history.sqlite")), 3)
        try store.setFavorite(id: id, isFavorite: true)
        try store.setFavorite(id: id, isFavorite: true)
        try checkEqual(try store.search(SearchFilter())[0].date, Date(timeIntervalSince1970: 100))
        store = nil; store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try check(try store.search(SearchFilter())[0].isFavorite)
        try checkEqual(try insert("favorite-fixture", time: 200, source: "New App"), id)
        try store.conceal(id: id)
        let record = try store.search(SearchFilter())[0]
        try check(record.isFavorite && record.isConcealed)
        try checkEqual(record.id, id); try checkEqual(record.source, "New App")
        try checkEqual(try store.payload(id: id), payload("favorite-fixture"))
        try store.setFavorite(id: id, isFavorite: false)
        try store.setFavorite(id: id, isFavorite: false)
        store = nil; store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
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
        store = nil; store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try check(try store.search(SearchFilter())[0].isConcealed)
        try checkEqual(try store.payload(id: id), original)
    }

    func testDeduplicationCannotRemoveConcealment() throws {
        let secret = "sticky-mask-fixture"
        let id = try insert(secret, time: 100, source: "Notes")
        try check(!store.search(SearchFilter())[0].isConcealed)
        try checkEqual(try store.insert(payload: payload(secret), kind: .text, title: secret, text: secret,
                                       source: "Password App", isConcealed: true, date: Date(timeIntervalSince1970: 200)), id)
        store = nil; store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
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
            try checkEqual(sqlite3_exec(db, "PRAGMA user_version=4", nil, nil, nil), SQLITE_OK)
        }
        try checkThrows(try HistoryStore(url: url))
        try checkEqual(try rawSchemaVersion(at: url), 4)
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
        store = nil; store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try checkEqual(try store.count(filter), 0)
        filter.query = "скрытая браузер"; filter.source = "БРАУЗЕР"
        let concealed = try store.search(filter)[0]
        try check(concealed.isConcealed)
        try checkEqual(concealed.title, "Скрытая запись"); try checkEqual(concealed.text, "")
        try checkEqual(concealed.id, original.id); try checkEqual(concealed.date, original.date)
        try checkEqual(concealed.kind, original.kind); try checkEqual(concealed.byteCount, original.byteCount)
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
