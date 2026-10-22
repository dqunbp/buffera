import BufferaCore
import Foundation

/// Exercises scheduling with controlled recognition delays; real Vision fixtures have a separate check.
func runImageTextIndexerChecks() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Buffera-indexer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"),
                                     secretCipher: SecretPayloadCipher { _, _ in Data(repeating: 0x42, count: 32) })
    let storage = DispatchQueue(label: "app.buffera.indexer-check.storage")
    let callbacks = DispatchQueue(label: "app.buffera.indexer-check.callbacks")
    let firstStarted = DispatchSemaphore(value: 0), firstRelease = DispatchSemaphore(value: 0)
    let stopStarted = DispatchSemaphore(value: 0), stopRelease = DispatchSemaphore(value: 0)
    defer { firstRelease.signal(); stopRelease.signal() }
    let calls = ImageTextCheckCalls()
    let recognize: (ClipPayload) throws -> String = { payload in
        let key = String(data: payload.items[0][0].data, encoding: .utf8)!
        let attempt = calls.increment(key)
        if key == "hidden" {
            firstStarted.signal()
            guard firstRelease.wait(timeout: .now() + 10) == .success else { throw HistoryError.missing }
        }
        if key == "stopped", attempt == 1 {
            stopStarted.signal()
            guard stopRelease.wait(timeout: .now() + 10) == .success else { throw HistoryError.missing }
        }
        if key == "retry", attempt == 1 { throw ImageTextRecognitionError.recognitionFailed }
        return "needle \(key)"
    }
    func insert(_ key: String) throws -> Int64 {
        try store.insert(payload: ClipPayload(items: [[Representation(type: "public.png", data: Data(key.utf8))]]),
                         kind: .image, title: "Картинка", text: "", source: "Indexer fixture")
    }
    func waitUntil(_ label: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try storage.sync(execute: condition) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw HistoryError.database("Image indexer check failed: \(label)")
    }
    func makeIndexer() -> ImageTextIndexer {
        ImageTextIndexer(store: store, storageQueue: storage, recognize: recognize, callbackQueue: callbacks,
                         onProgress: { _ in }, onIndexed: { _ = calls.increment("indexed") },
                         onError: { _ in _ = calls.increment("errors") })
    }
    let hidden = try insert("hidden")
    let indexer = makeIndexer()
    defer { indexer.stop() }
    indexer.start()
    guard firstStarted.wait(timeout: .now() + 5) == .success else {
        throw HistoryError.database("Image indexer check failed: initial job")
    }
    // These DB operations must finish while recognition is blocked on the other queue.
    let good = try storage.sync { () throws -> Int64 in
        let id = try insert("good")
        _ = try insert("retry")
        try store.conceal(id: hidden)
        return id
    }
    for _ in 0..<5 { indexer.schedule() }
    firstRelease.signal()
    try waitUntil("failed job does not block subsequent images") {
        try store.imageTextProgress() == ImageTextProgress(pending: 0, complete: 1, failed: 1)
    }
    var filter = SearchFilter(); filter.query = "needle"
    guard try storage.sync(execute: { try store.search(filter).map(\.id) }) == [good],
          calls.count("hidden") == 1, calls.count("good") == 1, calls.count("retry") == 1 else {
        throw HistoryError.database("Image indexer check failed: duplicate or hidden result")
    }
    indexer.retryFailed()
    try waitUntil("explicit retry completes") {
        try store.imageTextProgress() == ImageTextProgress(pending: 0, complete: 2, failed: 0)
    }
    guard calls.count("good") == 1, calls.count("retry") == 2 else {
        throw HistoryError.database("Image indexer check failed: completed images were retried")
    }
    _ = try storage.sync { try insert("stopped") }
    indexer.schedule()
    guard stopStarted.wait(timeout: .now() + 5) == .success else {
        throw HistoryError.database("Image indexer check failed: stop fixture")
    }
    indexer.stop()
    stopRelease.signal()
    guard try storage.sync(execute: { try store.imageTextProgress().pending }) == 1 else {
        throw HistoryError.database("Image indexer check failed: shutdown did not leave pending work")
    }
    let resumed = makeIndexer()
    defer { resumed.stop() }
    resumed.start()
    try waitUntil("pending work resumes on next launch") {
        try store.imageTextProgress() == ImageTextProgress(pending: 0, complete: 3, failed: 0)
    }
    callbacks.sync {}
    guard calls.count("stopped") == 2, calls.count("indexed") == 3, calls.count("errors") == 1 else {
        throw HistoryError.database("Image indexer check failed: result notifications")
    }
}

private final class ImageTextCheckCalls {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        values[key, default: 0] += 1
        return values[key]!
    }
    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return values[key, default: 0]
    }
}
