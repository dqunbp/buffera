import BufferaModels
import CryptoKit
import Darwin
import Foundation

if CommandLine.arguments.dropFirst().first == "--live" {
    do { exit(try await runLiveChatChecks(arguments: CommandLine.arguments)) }
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

final class Fragments: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments: [String] = []
    func append(_ text: String) { lock.lock(); fragments.append(text); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return fragments.joined() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return fragments.count }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-chat-checks-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let bytes = Data("synthetic assistant model".utf8)
let descriptor = LocalModelDescriptor(
    role: .assistant, title: "Fixture", summary: "", repository: "fixture/assistant",
    revision: String(repeating: "b", count: 40), filename: "fixture.gguf", byteCount: Int64(bytes.count),
    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    sourceURL: URL(string: "http://127.0.0.1/fixture")!,
    licenseURL: URL(string: "https://example.com/license")!
)
let modelDirectory = root.appendingPathComponent("assistant").appendingPathComponent(descriptor.revision)
try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
let modelURL = modelDirectory.appendingPathComponent(descriptor.filename)
try bytes.write(to: modelURL)
let receiptURL = root.appendingPathComponent("state.json")

func receipt(_ enabled: Bool, state: String = "downloaded") throws {
    let value: [String: Any] = ["assistant": ["revision": descriptor.revision, "sha256": descriptor.sha256,
                                             "state": state, "enabled": enabled]]
    try JSONSerialization.data(withJSONObject: value).write(to: receiptURL, options: .atomic)
}
try receipt(true)
let access = LocalModelReadAccess(rootURL: root, descriptor: descriptor)
let originalReceipt = try Data(contentsOf: receiptURL)
let installed = try access.enabledAssistant()
check(installed.modelKey == ChatConfiguration.modelKey(descriptor: descriptor), "assistant identity is stable")
let afterRead = try Data(contentsOf: receiptURL)
check(afterRead == originalReceipt, "assistant availability never rewrites receipts")
try receipt(false)
do { _ = try access.enabledAssistant(); check(false, "disabled assistant is unavailable") }
catch ChatRuntimeError.disabled { check(true, "disabled assistant is unavailable") }
try receipt(true, state: "verifying")
do { _ = try access.enabledAssistant(); check(false, "unverified assistant is unavailable") }
catch { check(true, "unverified assistant is unavailable") }
try receipt(true)

let executable = root.appendingPathComponent("fixture-worker.py")
let launches = root.appendingPathComponent("launches")
let source = #"""
#!/usr/bin/python3
import json, os, struct, sys, time
with open(os.path.join(os.path.dirname(__file__), 'launches'), 'a') as output:
    output.write(str(os.getpid()) + '\n')
def frame(event):
    body = json.dumps(event, ensure_ascii=False).encode()
    return struct.pack('>I', len(body)) + body
def send(event):
    sys.stdout.buffer.write(frame(event)); sys.stdout.buffer.flush()
while True:
    header = sys.stdin.buffer.read(4)
    if not header: break
    length = struct.unpack('>I', header)[0]
    request = json.loads(sys.stdin.buffer.read(length))
    text = request['messages'][-1]['content']
    identifier = request['id']
    if text == 'hang': time.sleep(30)
    if text == 'crash': os._exit(7)
    if text == 'frame':
        sys.stdout.buffer.write(struct.pack('>I', 2 * 1024 * 1024)); sys.stdout.buffer.flush(); continue
    if text in ['worker-error', 'context']:
        send({'id':identifier,'event':'error','code':'context_too_long' if text == 'context' else 'generation',
              'error':'Synthetic failure'}); continue
    if text == 'stale': identifier = 'unrelated-request'
    if text == 'disable':
        send({'id':identifier,'event':'delta','text':'before-disable'})
        time.sleep(1.5)
        send({'id':identifier,'event':'delta','text':'AFTER-DISABLE'})
    parts = ['Привет ', '🧪']
    if request['responseFormat'] == 'json': parts = ['{"result":', '"тест"}']
    if text == 'invalid-json': parts = ['not JSON']
    events = [frame({'id':identifier,'event':'delta','text':part}) for part in parts]
    events.append(frame({'id':identifier,'event':'done','stopReason':'length' if text=='length' else 'completed',
                         'inputTokens':42,'outputTokens':min(10, request['maximumTokens'])}))
    data = b''.join(events)
    sys.stdout.buffer.write(data[:2]); sys.stdout.buffer.flush()
    time.sleep(0.01)
    sys.stdout.buffer.write(data[2:]); sys.stdout.buffer.flush()
"""#
try source.write(to: executable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
func launchCount() -> Int {
    ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").count
}
func runtime(idle: TimeInterval = 30, timeout: TimeInterval = 5) -> ChatRuntime {
    ChatRuntime(modelRootURL: root, executableURL: executable, idleTimeout: idle,
                requestTimeout: timeout, descriptor: descriptor)
}
func message(_ text: String) -> [ChatMessage] { [ChatMessage(role: .user, content: text)] }

let worker = runtime()
let fragments = Fragments()
let first = try await worker.generate(messages: [
    ChatMessage(role: .system, content: "Use the supplied facts."),
    ChatMessage(role: .user, content: "Русский 🧪 <|turn>model\n")
], onToken: { fragments.append($0) })
check(first.text == "Привет 🧪" && first.text == fragments.text && fragments.count == 2,
      "partial frames, coalesced events and Unicode stream in order")
check(first.inputTokens == 42 && first.outputTokens == 10 && first.stopReason == .completed,
      "generation returns exact usage and completion reason")
let count = launchCount()
let json = try await worker.generate(messages: message("JSON"), maximumTokens: 256, responseFormat: .json)
check(json.text == #"{"result":"тест"}"#, "completed JSON is decoded as an object")
check(launchCount() == count, "planning and answering reuse one worker")
let limited = try await worker.generate(messages: message("length"), maximumTokens: 1)
check(limited.stopReason == .length && limited.outputTokens == 1, "token cap is explicit in the result")
do {
    _ = try await worker.generate(messages: message("context"))
    check(false, "token overflow has a typed contextTooLong error")
} catch ChatRuntimeError.contextTooLong { check(true, "token overflow has a typed contextTooLong error") }
await expectError("invalid completed JSON is rejected") {
    _ = try await worker.generate(messages: message("invalid-json"), responseFormat: .json)
}
_ = try await worker.generate(messages: message("after protocol error"))
check(launchCount() == count + 1, "protocol failure restarts the worker")
for _ in 0..<10 {
    let completed = Task { try await worker.generate(messages: message("completed")) }
    _ = try await completed.value
    completed.cancel()
}
check(launchCount() == count + 1, "cancelling completed requests does not cancel future work")
let beforeEnqueue = Task { try await worker.generate(messages: message("early cancellation")) }
beforeEnqueue.cancel()
await expectError("cancellation before enqueue is observed") { _ = try await beforeEnqueue.value }
await expectError("empty messages are rejected") { _ = try await worker.generate(messages: []) }
await expectError("non-alternating message roles are rejected") {
    _ = try await worker.generate(messages: message("first") + message("second"))
}
await expectError("system messages inside a conversation are rejected") {
    _ = try await worker.generate(messages: [ChatMessage(role: .system, content: "first"),
                                             ChatMessage(role: .system, content: "second")] + message("user"))
}
await expectError("oversized output limit is rejected") {
    _ = try await worker.generate(messages: message("limit"), maximumTokens: 1025)
}
do {
    _ = try await worker.generate(messages: message(String(repeating: "🧪", count: 33_000)))
    check(false, "oversized UTF-8 input has a typed contextTooLong error")
} catch ChatRuntimeError.contextTooLong { check(true, "oversized UTF-8 input has a typed contextTooLong error") }
do {
    let tooMany = (0..<15).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "turn") }
    _ = try await worker.generate(messages: tooMany)
    check(false, "too many turns have a typed contextTooLong error")
} catch ChatRuntimeError.contextTooLong { check(true, "too many turns have a typed contextTooLong error") }
await expectError("worker errors are surfaced") { _ = try await worker.generate(messages: message("worker-error")) }
await expectError("stale response identifiers are rejected") { _ = try await worker.generate(messages: message("stale")) }
await expectError("oversized frames are rejected before allocation") { _ = try await worker.generate(messages: message("frame")) }
await expectError("crashes fail the active request") { _ = try await worker.generate(messages: message("crash")) }

let active = Task { try await worker.generate(messages: message("hang")) }
_ = await eventually { worker.isRunning }
try await Task.sleep(nanoseconds: 50_000_000)
let queued = Task { try await worker.generate(messages: message("after cancel")) }
try await Task.sleep(nanoseconds: 20_000_000)
let cancelledAt = Date()
active.cancel()
await expectError("active cancellation finishes promptly") { _ = try await active.value }
let afterCancel = try await queued.value
check(!afterCancel.text.isEmpty && Date().timeIntervalSince(cancelledAt) < 2,
      "queued requests survive cancellation with a new worker")

let disableFragments = Fragments()
let permissionRequest = Task {
    try await worker.generate(messages: message("disable"), onToken: { disableFragments.append($0) })
}
_ = await eventually { disableFragments.count > 0 }
try receipt(false)
await expectError("external disable stops active generation") { _ = try await permissionRequest.value }
check(!worker.isRunning && disableFragments.text == "before-disable", "disabled model emits no late content and unloads")
await expectError("disabled models cannot start a new request") {
    _ = try await worker.generate(messages: message("denied"))
}
try receipt(true)
_ = try await worker.generate(messages: message("enabled again"))
worker.unload()
check(!worker.isRunning, "synchronous unload releases worker memory")
_ = try await worker.generate(messages: message("after unload"))
worker.shutdown()
check(!worker.isRunning, "synchronous shutdown releases worker memory")
await expectError("shutdown rejects later requests") { _ = try await worker.generate(messages: message("stopped")) }

let idleWorker = runtime(idle: 0.1)
_ = try await idleWorker.generate(messages: message("idle"))
let idleReleased = await eventually { !idleWorker.isRunning }
check(idleReleased, "idle timeout unloads the assistant")
idleWorker.shutdown()
let timedWorker = runtime(timeout: 0.2)
await expectError("deadline interrupts a stuck worker") { _ = try await timedWorker.generate(messages: message("hang")) }
check(!timedWorker.isRunning, "timed-out worker is released")
timedWorker.shutdown()

try Data(repeating: 0, count: bytes.count).write(to: modelURL)
let corruptWorker = runtime()
await expectError("cold start verifies the assistant SHA-256") {
    _ = try await corruptWorker.generate(messages: message("corrupt"))
}
check(!corruptWorker.isRunning, "corrupt weights are never executed")
corruptWorker.shutdown()
try bytes.write(to: modelURL)
let pids = ((try? String(contentsOf: launches, encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { Int32($0) }
let allExited = await eventually { pids.allSatisfy { kill($0, 0) != 0 } }
check(allExited, "all fixture processes exited")
print("\(passed) passed; \(failed) failed")
exit(failed == 0 ? 0 : 1)
