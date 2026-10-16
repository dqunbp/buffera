import Foundation
import BuferaCore

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
                                          maxCount: Int = 50_000, maxBytes: Int = 5_000_000_000) throws -> Int64 {
        try store.insert(payload: payload(value), kind: kind, title: value, text: value, source: "Тест",
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
