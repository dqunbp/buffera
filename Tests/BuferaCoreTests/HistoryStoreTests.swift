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
        try check(records.allSatisfy { !$0.isConcealed })
        for index in 1...8 { try checkEqual(try store.payload(id: Int64(index)), payload("legacy \(index)")) }
        try checkEqual(try rawSchemaVersion(at: url), 2)
        store = nil; store = try HistoryStore(url: url)
        try checkEqual(try store.count(), 8)
        try checkEqual(try rawSchemaVersion(at: url), 2)
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
            try checkEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        }
        try checkThrows(try HistoryStore(url: url))
        try checkEqual(try rawSchemaVersion(at: url), 99)
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
