import BufferaCore
import BufferaModels
import Foundation

/// Executes only synthetic probe scripts; never opens a user's weights or history.
func checkProbeCacheLifecycle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-probe-check-\(UUID())")
    let bin = root.appendingPathComponent("Fixture.app/Contents/MacOS")
    let caches = root.appendingPathComponent("caches")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = bin.appendingPathComponent("BufferaLiteRTEmbeddingWorker")
    let record = bin.appendingPathComponent("cache-path")
    let controller = ModelProbeController(bundleURL: root.appendingPathComponent("Fixture.app"), cacheRootURL: caches)
    defer { controller.shutdown() }
    var finished = false
    controller.onChange = { _, _, running in if !running { finished = true } }
    func wait(_ phase: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard condition() else { throw HistoryError.database("Probe cache lifecycle timed out: \(phase)") }
    }
    func prepare(_ ending: String) throws {
        finished = false
        try? FileManager.default.removeItem(at: record)
        let source = """
        #!/bin/sh
        printf '%s' "$3" > "$(dirname "$0")/cache-path"
        touch "$3/compiled"
        \(ending)
        """
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func cachePath() -> String? {
        guard let value = try? String(contentsOf: record, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
    func checkCacheRemoved(_ phase: String) throws {
        try wait("cache removal after \(phase)") { cachePath().map { !FileManager.default.fileExists(atPath: $0) } == true }
    }
    try prepare("printf '%s' '{\"success\":true,\"summary\":\"Fixture OK\"}'")
    controller.check(.embedding, modelURL: root.appendingPathComponent("unused"), engine: .liteRT)
    try wait("probe completion") { finished }
    try checkCacheRemoved("success")
    let firstCache = cachePath()
    try prepare("exec /bin/sleep 30")
    controller.check(.embedding, modelURL: root.appendingPathComponent("unused"), engine: .liteRT)
    try wait("probe launch") { cachePath() != nil }
    guard cachePath() != firstCache else { throw HistoryError.database("Probes reuse a shared cache") }
    controller.cancel(.embedding)
    try wait("probe completion") { finished }
    try checkCacheRemoved("cancel")
    try prepare("exec /bin/sleep 30")
    controller.check(.embedding, modelURL: root.appendingPathComponent("unused"), engine: .liteRT)
    try wait("probe launch") { cachePath() != nil }
    controller.shutdown()
    try checkCacheRemoved("shutdown")
    // Executable permissions pass the availability check, but the image cannot launch.
    try "invalid executable".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    finished = false
    controller.check(.embedding, modelURL: root.appendingPathComponent("unused"), engine: .liteRT)
    try wait("probe completion") { finished }
    let remaining = try FileManager.default.contentsOfDirectory(atPath: caches.appendingPathComponent("embedding").path)
    guard remaining.isEmpty else { throw HistoryError.database("Failed probe launch leaves a cache") }
}
