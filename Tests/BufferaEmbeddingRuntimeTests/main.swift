import BufferaModels
import CryptoKit
import Darwin
import Foundation

if CommandLine.arguments.dropFirst().first == "--live" {
    do { exit(try await runLiveEmbeddingChecks(arguments: CommandLine.arguments)) }
    catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    if condition() { passed += 1; print("PASS \(description)") }
    else { failed += 1; print("FAIL \(description)") }
}

func eventually(_ condition: () -> Bool, timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    } while Date() < deadline
    return condition()
}

func expectError(_ name: String, operation: () async throws -> Void) async {
    do { try await operation(); check(false, name) }
    catch { check(true, name) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-embedding-checks-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let bytes = Data("synthetic fixture model".utf8)
let descriptor = LocalModelDescriptor(
    role: .embedding, title: "Fixture", summary: "", repository: "fixture/embedding",
    revision: String(repeating: "a", count: 40), filename: "fixture.gguf", byteCount: Int64(bytes.count),
    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    sourceURL: URL(string: "http://127.0.0.1/fixture")!,
    licenseURL: URL(string: "https://example.com/license")!
)
let modelDirectory = root.appendingPathComponent("embedding").appendingPathComponent(descriptor.revision)
try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
try bytes.write(to: modelDirectory.appendingPathComponent(descriptor.filename))
let receiptURL = root.appendingPathComponent("state.json")

func receipt(_ enabled: Bool, state: String = "downloaded") throws {
    let value: [String: Any] = ["embedding": ["revision": descriptor.revision, "sha256": descriptor.sha256,
                                             "state": state, "enabled": enabled]]
    try JSONSerialization.data(withJSONObject: value).write(to: receiptURL, options: .atomic)
}
try receipt(true)
let access = LocalModelReadAccess(rootURL: root, descriptor: descriptor)
let originalReceipt = try Data(contentsOf: receiptURL)
let installed = try access.enabledEmbedding()
check(installed.modelKey == EmbeddingConfiguration.modelKey(descriptor: descriptor),
      "read-only access and index use the same model identity")
let readReceipt = try Data(contentsOf: receiptURL)
check(readReceipt == originalReceipt, "availability reads never rewrite model receipts")
try receipt(false)
do { _ = try access.enabledEmbedding(); check(false, "disabled model is unavailable") }
catch EmbeddingRuntimeError.disabled { check(true, "disabled model is unavailable") }
try receipt(true, state: "verifying")
do { _ = try access.enabledEmbedding(); check(false, "unverified model is unavailable") }
catch { check(true, "unverified model is unavailable") }
try receipt(true)

let executable = root.appendingPathComponent("fixture-worker.py")
let launches = root.appendingPathComponent("launches")
let source = #"""
#!/usr/bin/python3
import json, os, struct, sys, time
with open(os.path.join(os.path.dirname(__file__), 'launches'), 'a') as output:
    output.write(str(os.getpid()) + '\n')
while True:
    header = sys.stdin.buffer.read(4)
    if not header: break
    length = struct.unpack('>I', header)[0]
    request = json.loads(sys.stdin.buffer.read(length))
    text = request['texts'][0]
    with open(os.path.join(os.path.dirname(__file__), 'requests'), 'a') as output:
        output.write(text + '\n')
    if text.startswith('slow-'): time.sleep(0.4)
    if text == 'hang': time.sleep(30)
    if text == 'crash': os._exit(7)
    if text == 'frame':
        sys.stdout.buffer.write(struct.pack('>I', 5 * 1024 * 1024)); sys.stdout.buffer.flush()
        continue
    vector = [1.0] + [0.0] * (1 if text == 'invalid' else 767)
    if text == 'slow-obsolete-query': vector = [0.0, 1.0] + [0.0] * 766
    response = {'id': request['id'], 'outputs': [
        {'vectors': [vector], 'truncated': False} for _ in request['texts']
    ]}
    if text == 'worker-error': response = {'id': request['id'], 'error': 'Synthetic failure'}
    body = json.dumps(response).encode()
    sys.stdout.buffer.write(struct.pack('>I', len(body)) + body); sys.stdout.buffer.flush()
"""#
try source.write(to: executable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
func launchCount() -> Int {
    ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").count
}
func requestOrder() -> [String] {
    ((try? String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
}
func runtime(idle: TimeInterval = 30, timeout: TimeInterval = 5) -> EmbeddingRuntime {
    EmbeddingRuntime(modelRootURL: root, executableURL: executable, idleTimeout: idle,
                     requestTimeout: timeout, descriptor: descriptor)
}

let worker = runtime()
let first = try await worker.embed(["English", "Русский 🧪 <|turn>"], kind: .document)
check(first.count == 2 && first.allSatisfy { $0.vectors.count == 1 && $0.vectors[0].count == 768 },
      "Unicode batches return one bounded result per input")
let count = launchCount()
_ = try await worker.embed(["query"], kind: .query)
check(launchCount() == count, "consecutive requests reuse one loaded process")
for _ in 0..<20 {
    let completed = Task { try await worker.embed(["completed"], kind: .query) }
    _ = try await completed.value
    completed.cancel()
}
check(launchCount() == count, "cancelling completed tasks does not affect future requests")
let beforeEnqueue = Task { try await worker.embed(["cancel before enqueue"], kind: .query) }
beforeEnqueue.cancel()
await expectError("cancellation before enqueue is observed") { _ = try await beforeEnqueue.value }
await expectError("empty input is rejected before sending") { _ = try await worker.embed(["  "], kind: .query) }
await expectError("oversized UTF-8 input is rejected") {
    _ = try await worker.embed([String(repeating: "🧪", count: 33_000)], kind: .document)
}
await expectError("worker errors are returned without corrupting the connection") {
    _ = try await worker.embed(["worker-error"], kind: .query)
}
_ = try await worker.embed(["after error"], kind: .query)
check(launchCount() == count, "valid worker error preserves reusable process")
await expectError("invalid vector dimensions are rejected") {
    _ = try await worker.embed(["invalid"], kind: .query)
}
_ = try await worker.embed(["after invalid"], kind: .query)
check(launchCount() == count + 1, "protocol failure restarts worker for next request")
await expectError("oversized response frame is rejected before allocation") {
    _ = try await worker.embed(["frame"], kind: .query)
}
await expectError("worker crash fails the active request") {
    _ = try await worker.embed(["crash"], kind: .query)
}

let active = Task { try await worker.embed(["hang"], kind: .document) }
_ = await eventually { worker.isRunning }
try await Task.sleep(nanoseconds: 50_000_000)
let queued = Task { try await worker.embed(["after cancel"], kind: .query) }
try await Task.sleep(nanoseconds: 20_000_000)
let cancelledAt = Date()
active.cancel()
await expectError("active task cancellation completes without waiting for inference") { _ = try await active.value }
let afterCancel = try await queued.value
check(afterCancel.count == 1 && Date().timeIntervalSince(cancelledAt) < 2,
      "queued request survives active cancellation and gets a new worker")

let beforeSoftCancel = launchCount()
let obsoleteQuery = Task { try await worker.embed(["slow-obsolete-query"], kind: .query) }
_ = await eventually { requestOrder().contains("slow-obsolete-query") }
let queryCancelledAt = Date()
obsoleteQuery.cancel()
await expectError("obsolete active query cancellation returns promptly") { _ = try await obsoleteQuery.value }
check(Date().timeIntervalSince(queryCancelledAt) < 0.2 && worker.isRunning,
      "obsolete queries release callers without killing the loaded worker")
var staleQueries: [Task<[EmbeddingOutput], Error>] = []
for index in 0..<40 {
    let stale = Task { try await worker.embed(["cancelled-pending-\(index)"], kind: .query) }
    stale.cancel()
    staleQueries.append(stale)
}
let latest = try await worker.embed(["latest-query"], kind: .query)
for stale in staleQueries { _ = try? await stale.value }
check(latest.first?.vectors.first?.first == 1 && launchCount() == beforeSoftCancel,
      "latest pending query reuses weights after an abandoned result is drained")
check(!requestOrder().contains { $0.hasPrefix("cancelled-pending-") },
      "cancelled pending queries never accumulate as inference work")

let background = Task { try await worker.embed(["slow-background"], kind: .document) }
_ = await eventually { requestOrder().contains("slow-background") }
let pendingDocument = Task { try await worker.embed(["queued-background"], kind: .document) }
try await Task.sleep(nanoseconds: 20_000_000)
let foreground = Task { try await worker.embed(["priority-query"], kind: .query) }
_ = try await background.value
_ = try await foreground.value
_ = try await pendingDocument.value
let order = requestOrder()
check(order.firstIndex(of: "priority-query")! < order.firstIndex(of: "queued-background")!,
      "foreground queries run before queued background documents")
check(launchCount() == beforeSoftCancel, "query priority does not reload the shared worker")

let abandoned = Task { try await worker.embed(["slow-unload-query"], kind: .query) }
_ = await eventually { requestOrder().contains("slow-unload-query") }
abandoned.cancel()
_ = try? await abandoned.value
worker.unload()
check(!worker.isRunning, "explicit unload still kills an abandoned active query")

let permissionRequest = Task { try await worker.embed(["hang"], kind: .document) }
try await Task.sleep(nanoseconds: 100_000_000)
try receipt(false)
await expectError("external disable interrupts an active worker within polling interval") {
    _ = try await permissionRequest.value
}
check(!worker.isRunning, "disabled model releases the worker process")
await expectError("disabled model cannot start another request") {
    _ = try await worker.embed(["denied"], kind: .query)
}
try receipt(true)
_ = try await worker.embed(["enabled again"], kind: .query)
worker.unload()
check(!worker.isRunning, "synchronous unload releases the worker")
_ = try await worker.embed(["after unload"], kind: .query)
worker.shutdown()
check(!worker.isRunning, "synchronous shutdown releases the worker")
await expectError("shutdown permanently rejects later requests") {
    _ = try await worker.embed(["after shutdown"], kind: .query)
}

let idleWorker = runtime(idle: 0.1)
_ = try await idleWorker.embed(["idle"], kind: .query)
let idleReleased = await eventually { !idleWorker.isRunning }
check(idleReleased, "idle timeout unloads model memory")
idleWorker.shutdown()

let timedWorker = runtime(timeout: 0.2)
await expectError("request deadline interrupts a stuck worker") {
    _ = try await timedWorker.embed(["hang"], kind: .query)
}
check(!timedWorker.isRunning, "timed-out process is released")
timedWorker.shutdown()

let abandonedTimedWorker = runtime(timeout: 0.2)
let stuckQuery = Task { try await abandonedTimedWorker.embed(["hang"], kind: .query) }
_ = await eventually { abandonedTimedWorker.isRunning }
stuckQuery.cancel()
_ = try? await stuckQuery.value
let timedOutAbandoned = await eventually { !abandonedTimedWorker.isRunning }
check(timedOutAbandoned, "abandoned query keeps a bounded deadline and cannot retain a stuck worker")
abandonedTimedWorker.shutdown()

let pids = ((try? String(contentsOf: launches, encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { Int32($0) }
let allExited = await eventually { pids.allSatisfy { kill($0, 0) != 0 } }
check(allExited, "all fixture worker processes exited")
let unchangedModel = try Data(contentsOf: modelDirectory.appendingPathComponent(descriptor.filename))
check(unchangedModel == bytes, "inference never mutates model weights")
print("\(passed) passed; \(failed) failed")
exit(failed == 0 ? 0 : 1)
