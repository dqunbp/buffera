import BufferaModels
import CryptoKit
import Foundation

if CommandLine.arguments.dropFirst().first == "--download-live" {
    do { exit(try runLiveDownload(arguments: CommandLine.arguments)) }
    catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}

func waitFor(_ manager: LocalModelManager, role: ModelRole = .embedding,
             timeout: TimeInterval = 12, _ predicate: (LocalModelSnapshot) -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let value = manager.snapshots.first(where: { $0.descriptor.role == role }), predicate(value) { return true }
        Thread.sleep(forTimeInterval: 0.015)
    } while Date() < deadline
    if let value = manager.snapshots.first(where: { $0.descriptor.role == role }) {
        print("TIMEOUT \(value.state): \(value.receivedBytes) bytes; \(value.errorMessage ?? "no error")")
    }
    return false
}

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-model-checks-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let requestLog = temporary.appendingPathComponent("requests.jsonl")
let server = Process()
let output = Pipe()
server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
server.arguments = ["-u", "-c", #"""
import http.server, json, sys, time
payload = bytes(range(256)) * 4096
attempts = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        requested = self.headers.get("Range")
        with open(sys.argv[1], "a") as f: f.write(json.dumps({"path":self.path,"range":requested})+"\n")
        attempts[self.path] = attempts.get(self.path, 0) + 1
        if self.path == "/error" or (self.path == "/retry" and attempts[self.path] == 1):
            self.send_error(503)
            return
        start = int(requested.split("=")[1].split("-")[0]) if requested else 0
        status = 206 if requested and self.path != "/ignore" else 200
        if status == 200: start = 0
        body = payload[start:]
        self.send_response(status)
        if status == 206:
            reported = start + 1 if self.path == "/bad-range" else start
            self.send_header("Content-Range",f"bytes {reported}-{len(payload)-1}/{len(payload)}")
        self.send_header("Content-Length",str(len(body)))
        self.send_header("ETag",'"fixture-v1"')
        self.end_headers()
        if self.path == "/truncated": body = body[:65536]
        try:
            for at in range(0,len(body),4096):
                self.wfile.write(body[at:at+4096]); self.wfile.flush()
                if self.path in ("/slow", "/truncated"): time.sleep(.004)
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = True
server = http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
print(server.server_address[1],flush=True)
server.serve_forever()
"""#, requestLog.path]
server.standardOutput = output
server.standardError = FileHandle.nullDevice
try server.run()
defer { server.terminate(); server.waitUntilExit() }
var portBytes = Data()
while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
    if byte[0] == 10 { break }
    portBytes.append(byte)
}
guard let port = String(data: portBytes, encoding: .utf8), Int(port) != nil else {
    fatalError("Local HTTP fixture did not start")
}
let payload = Data((0..<256).map(UInt8.init).flatMap { [$0] })
let fullPayload = (0..<4096).reduce(into: Data()) { data, _ in data.append(payload) }
let expectedHash = SHA256.hash(data: fullPayload).map { String(format: "%02x", $0) }.joined()
let revision = String(repeating: "a", count: 40)

func descriptor(_ route: String = "range", role: ModelRole = .embedding,
                hash: String = expectedHash) -> LocalModelDescriptor {
    LocalModelDescriptor(
        role: role, title: "Fixture", summary: "Local deterministic fixture", repository: "test/fixture",
        revision: revision, filename: "fixture.gguf", byteCount: Int64(fullPayload.count), sha256: hash,
        sourceURL: URL(string: "http://127.0.0.1:\(port)/\(route)")!,
        licenseURL: URL(string: "https://example.com/license")!
    )
}

func root(_ name: String) -> URL { temporary.appendingPathComponent(name) }
func partial(_ root: URL, role: ModelRole = .embedding) -> URL {
    root.appendingPathComponent(role.rawValue).appendingPathComponent(revision).appendingPathComponent("fixture.gguf.part")
}
func seedPartial(_ directory: URL, count: Int) throws {
    let path = partial(directory)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fullPayload.prefix(count).write(to: path)
}
func requests() -> [[String: Any]] {
    guard let data = try? Data(contentsOf: requestLog),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

do {
    let manager = try LocalModelManager(rootURL: root("complete"), descriptors: [descriptor()])
    check(manager.snapshots.first?.state == .notDownloaded, "initial state is not downloaded")
    check(manager.modelURL(for: .embedding) == nil, "incomplete models have no usable path")
    check(manager.snapshots.first?.isReadyForUse == false, "missing files are not ready for inference")
    manager.download(.embedding)
    check(waitFor(manager) { $0.state == .downloaded }, "real HTTP download completes and verifies")
    let file = manager.modelURL(for: .embedding)
    check(file.flatMap { try? Data(contentsOf: $0) } == fullPayload, "downloaded bytes match fixture")
    check(!FileManager.default.fileExists(atPath: partial(root("complete")).path), "verified file atomically leaves partial path")
    check(manager.snapshots.first?.isEnabled == false && manager.snapshots.first?.isReadyForUse == false,
          "downloading files alone does not turn on the feature")
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.isReadyForUse }, "verified model can be enabled")
    manager.setEnabled(false, for: .embedding)
    check(waitFor(manager) { !$0.isEnabled && $0.state == .downloaded }, "disable preserves downloaded file")
    manager.setEnabled(true, for: .embedding)
    _ = waitFor(manager) { $0.isEnabled }
    manager.shutdown()
    let restored = try LocalModelManager(rootURL: root("complete"), descriptors: [descriptor()])
    check(waitFor(restored) { $0.state == .downloaded && $0.isEnabled }, "restart verifies stored model and preserves enabled preference")
    restored.remove(.embedding)
    check(waitFor(restored) { $0.state == .notDownloaded && !$0.isEnabled }, "delete resets installed and enabled state")
    check(restored.modelURL(for: .embedding) == nil && !(FileManager.default.fileExists(atPath: file!.path)),
          "delete removes model bytes and usable path")
    restored.shutdown()
}

do {
    let directory = root("enable-feature")
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor("slow")])
    let access = LocalModelReadAccess(rootURL: directory, descriptor: descriptor("slow"))
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.state == .downloading && $0.receivedBytes > 32768 && $0.isEnabled },
          "enabling a missing feature starts the download and keeps its toggle on")
    check(manager.snapshots[0].isReadyForUse == false && (try? access.enabledEmbedding()) == nil,
          "requested feature is unavailable to runtimes until its files are verified")
    manager.setEnabled(false, for: .embedding)
    check(waitFor(manager) { $0.state == .paused && !$0.isEnabled },
          "disabling an in-flight feature pauses its download and clears preference")
    let pausedBytes = manager.snapshots[0].receivedBytes
    Thread.sleep(forTimeInterval: 0.08)
    check(manager.snapshots[0].receivedBytes == pausedBytes && !manager.snapshots[0].isReadyForUse,
          "late download callbacks cannot reactivate a disabled feature")
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.isReadyForUse }, "re-enabling resumes files and activates automatically after verification")
    check((try? access.enabledEmbedding())?.fileURL == manager.modelURL(for: .embedding),
          "read-only runtime access accepts only the completed enabled feature")
    check(requests().contains { ($0["path"] as? String) == "/slow" &&
        ($0["range"] as? String) == "bytes=\(pausedBytes)-" }, "feature resume reuses the saved file offset")
    manager.shutdown()
}

do {
    let directory = root("feature-paused-restart")
    let first = try LocalModelManager(rootURL: directory, descriptors: [descriptor("slow")])
    first.setEnabled(true, for: .embedding)
    _ = waitFor(first) { $0.state == .downloading && $0.receivedBytes > 32768 }
    first.pause(.embedding)
    check(waitFor(first) { $0.state == .paused && $0.isEnabled && !$0.isReadyForUse },
          "pausing a download retains the requested feature preference")
    first.shutdown()
    let second = try LocalModelManager(rootURL: directory, descriptors: [descriptor("slow")])
    check(second.snapshots[0].state == .paused && second.snapshots[0].isEnabled && !second.snapshots[0].isReadyForUse,
          "restart preserves a paused feature preference without claiming readiness")
    let requestCount = requests().count
    Thread.sleep(forTimeInterval: 0.08)
    check(requests().count == requestCount, "restart does not unexpectedly restart paused downloads")
    second.download(.embedding)
    check(waitFor(second) { $0.isReadyForUse }, "resuming a paused feature activates it automatically")
    second.shutdown()
}

do {
    let directory = root("feature-retry")
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor("retry")])
    let access = LocalModelReadAccess(rootURL: directory, descriptor: descriptor("retry"))
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.state == .failed && $0.isEnabled && !$0.isReadyForUse && $0.errorMessage != nil },
          "download failure stays visible without losing the requested feature preference")
    check((try? access.enabledEmbedding()) == nil, "failed downloads remain unavailable to runtime readers")
    manager.download(.embedding)
    check(waitFor(manager) { $0.isReadyForUse && $0.errorMessage == nil },
          "retry completes the same feature activation without another toggle")
    manager.shutdown()
}

do {
    let directory = root("legacy-enabled")
    let file = partial(directory).deletingPathExtension()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fullPayload.write(to: file)
    let legacyReceipt: [String: Any] = ["embedding": ["revision": revision, "sha256": expectedHash,
                                                   "state": "downloaded", "enabled": true]]
    try JSONSerialization.data(withJSONObject: legacyReceipt).write(to: directory.appendingPathComponent("state.json"))
    let before = requests().count
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    check(waitFor(manager) { $0.isReadyForUse }, "existing enabled receipts retain feature activation after verification")
    check(requests().count == before, "legacy enabled files are reused without downloading again")
    manager.shutdown()
}

do {
    let directory = root("disable-startup-verification")
    let file = partial(directory).deletingPathExtension()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fullPayload.write(to: file)
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    check(manager.snapshots[0].state == .downloaded && !manager.snapshots[0].isReadyForUse &&
          manager.modelURL(for: .embedding) == nil,
          "installed switched-off files are visible without exposing an unverified usable URL")
    manager.setEnabled(false, for: .embedding)
    check(waitFor(manager) { !$0.isEnabled && $0.state == .downloaded },
          "keeping a feature off leaves its verification deferred")
    let before = requests().count
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.isReadyForUse }, "enabling verifies retained final files after deferred startup")
    check(requests().count == before, "deferred verification runs locally without a second download")
    manager.shutdown()
}

do {
    let directory = root("pause")
    let first = try LocalModelManager(rootURL: directory, descriptors: [descriptor("slow")])
    first.download(.embedding)
    check(waitFor(first) { $0.state == .downloading && $0.receivedBytes > 32768 }, "slow fixture reports intermediate byte progress")
    first.pause(.embedding)
    check(waitFor(first) { $0.state == .paused && $0.receivedBytes > 0 }, "pause retains partial bytes")
    let pausedBytes = first.snapshots[0].receivedBytes
    Thread.sleep(forTimeInterval: 0.08)
    check(first.snapshots[0].receivedBytes == pausedBytes, "late data callbacks cannot alter paused progress")
    first.shutdown()
    let second = try LocalModelManager(rootURL: directory, descriptors: [descriptor("slow")])
    check(second.snapshots[0].state == .paused && second.snapshots[0].receivedBytes == pausedBytes,
          "process restart recovers actual partial size")
    second.download(.embedding)
    check(waitFor(second) { $0.state == .downloaded }, "resumed transfer completes")
    check(requests().contains { ($0["path"] as? String) == "/slow" &&
        ($0["range"] as? String) == "bytes=\(pausedBytes)-" }, "resume sends exact stored Range offset")
    second.shutdown()
}

do {
    let directory = root("ignore")
    try seedPartial(directory, count: 70000)
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor("ignore")])
    manager.download(.embedding)
    check(waitFor(manager) { $0.state == .downloaded }, "server ignoring Range restarts safely")
    check(manager.modelURL(for: .embedding).flatMap { try? Data(contentsOf: $0) } == fullPayload,
          "ignored Range does not duplicate partial bytes")
    manager.shutdown()
}

do {
    let directory = root("bad-range")
    try seedPartial(directory, count: 70000)
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor("bad-range")])
    manager.download(.embedding)
    check(waitFor(manager) { $0.state == .failed && $0.errorMessage != nil }, "malformed Content-Range fails visibly")
    check((try? Data(contentsOf: partial(directory)).count) == 70000, "invalid Range never appends response bytes")
    check(manager.modelURL(for: .embedding) == nil, "invalid transfer is never exposed as ready")
    manager.shutdown()
}

do {
    let directory = root("checksum")
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor(hash: String(repeating: "0", count: 64))])
    manager.download(.embedding)
    check(waitFor(manager) { $0.state == .failed && $0.receivedBytes == 0 }, "checksum mismatch rejects and clears corrupt partial")
    check(manager.modelURL(for: .embedding) == nil, "checksum failure never yields usable model")
    manager.shutdown()
}

do {
    let directory = root("full-partial")
    try seedPartial(directory, count: fullPayload.count)
    let before = requests().count
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    manager.download(.embedding)
    check(waitFor(manager) { $0.state == .downloaded }, "complete partial is verified and installed")
    check(requests().count == before, "complete partial requires no network request")
    manager.shutdown()
}

do {
    let manager = try LocalModelManager(rootURL: root("truncated"), descriptors: [descriptor("truncated")])
    manager.download(.embedding)
    check(waitFor(manager) { $0.state == .failed && $0.receivedBytes > 0 }, "connection truncation retains partial and visible failure")
    manager.shutdown()
}

do {
    let manager = try LocalModelManager(rootURL: root("parallel"), descriptors: [
        descriptor("slow"), descriptor("slow", role: .assistant)
    ])
    manager.setEnabled(true, for: .embedding)
    manager.setEnabled(true, for: .assistant)
    check(waitFor(manager) { $0.receivedBytes > 16000 && $0.state == .downloading } &&
          waitFor(manager, role: .assistant) { $0.receivedBytes > 16000 && $0.state == .downloading },
          "two model roles download independently")
    manager.remove(.embedding)
    check(waitFor(manager) { $0.state == .notDownloaded && !$0.isEnabled && !$0.isReadyForUse }, "remove cancels an active download and disables the feature")
    check(waitFor(manager, role: .assistant) { $0.isReadyForUse }, "removing one role does not cancel another feature activation")
    Thread.sleep(forTimeInterval: 0.1)
    check(manager.snapshots.first { $0.descriptor.role == .embedding }?.state == .notDownloaded &&
          !FileManager.default.fileExists(atPath: root("parallel").appendingPathComponent("embedding").path),
          "late cancellation callback cannot recreate deleted files or state")
    manager.shutdown()
}

do {
    let directory = root("disk-error")
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    try Data().write(to: directory.appendingPathComponent("embedding"))
    manager.download(.embedding)
    check(waitFor(manager) { $0.state == .failed && $0.errorMessage != nil }, "filesystem collision is visible without downloading")
    manager.shutdown()
}

do {
    let directory = root("state-error")
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("state.json"), withIntermediateDirectories: true)
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.state == .failed && $0.errorMessage != nil && !$0.isReadyForUse }, "state persistence failure prevents download readiness")
    check((try? LocalModelReadAccess(rootURL: directory, descriptor: descriptor()).enabledEmbedding()) == nil,
          "failed receipt writes never expose a ready feature to readers")
    manager.shutdown()
}

do {
    let directory = root("diagnostic-off")
    let file = partial(directory).deletingPathExtension()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fullPayload.write(to: file)
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    let before = requests().count
    var outcomes: [Result<URL, Error>] = []
    var callbacksOnMain = true
    for _ in 0..<2 {
        manager.verifyInstalledModel(for: .embedding) { result in
            callbacksOnMain = callbacksOnMain && Thread.isMainThread
            outcomes.append(result)
        }
    }
    let deadline = Date().addingTimeInterval(2)
    while outcomes.count < 2 && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(outcomes.count == 2 && outcomes.allSatisfy { (try? $0.get()) == file },
          "explicit diagnostics obtain verified installed files without enabling their feature")
    check(callbacksOnMain, "diagnostic verification results arrive on the main queue")
    check(!manager.snapshots[0].isEnabled && manager.modelURL(for: .embedding) == file,
          "diagnostic verification leaves the feature off and makes verified URL available")
    check(requests().count == before, "explicit diagnostics never download installed files again")
    var corrupted = fullPayload
    corrupted[corrupted.count / 2] ^= 0xff
    try corrupted.write(to: file)
    var changedFileResult: Result<URL, Error>?
    manager.verifyInstalledModel(for: .embedding) { changedFileResult = $0 }
    let changedFileDeadline = Date().addingTimeInterval(2)
    while changedFileResult == nil && Date() < changedFileDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let rejected: Bool
    if case .failure = changedFileResult { rejected = true }
    else { rejected = false }
    check(rejected && manager.snapshots[0].state == .failed && manager.modelURL(for: .embedding) == nil,
          "explicit diagnostics reject same-process mutations after an earlier successful verification")
    manager.shutdown()
}

do {
    let directory = root("modified-file")
    let manager = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    manager.download(.embedding)
    _ = waitFor(manager) { $0.state == .downloaded }
    let file = manager.modelURL(for: .embedding)!
    manager.shutdown()
    var corrupted = fullPayload
    corrupted[corrupted.count / 2] ^= 0xff
    try corrupted.write(to: file)
    let restored = try LocalModelManager(rootURL: directory, descriptors: [descriptor()])
    check(restored.snapshots[0].state == .downloaded && !restored.snapshots[0].isEnabled &&
          restored.modelURL(for: .embedding) == nil,
          "restart defers full verification of installed switched-off files")
    restored.setEnabled(true, for: .embedding)
    check(waitFor(restored) { $0.state == .failed }, "enabling rejects same-size file modified after download")
    check(restored.modelURL(for: .embedding) == nil, "deferred receipt cannot bypass integrity verification")
    restored.shutdown()
}

do {
    let manager = try LocalModelManager(rootURL: root("callback"), descriptors: [descriptor()])
    var deliveredOnMain = false
    manager.onChange = { snapshots in deliveredOnMain = Thread.isMainThread && snapshots.count == 1 }
    let deadline = Date().addingTimeInterval(2)
    while !deliveredOnMain && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(deliveredOnMain, "UI receives initial snapshot on main thread")
    manager.onChange = nil
    manager.shutdown()
}

print("Model checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
