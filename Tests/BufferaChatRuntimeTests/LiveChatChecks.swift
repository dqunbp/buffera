import BufferaModels
import Foundation

/// Uses synthetic conversations and an isolated model receipt. Never reads clipboard history.
func runLiveChatChecks(arguments: [String]) async throws -> Int32 {
    guard arguments.count == 4 else {
        print("Usage: BufferaChatRuntimeChecks --live /absolute/Buffera.app /absolute/model.gguf")
        return 2
    }
    let descriptor = LocalModelCatalog.models.first { $0.role == .assistant }!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-chat-live-\(UUID())")
    let directory = root.appendingPathComponent("assistant").appendingPathComponent(descriptor.revision)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[3]),
                                    to: directory.appendingPathComponent(descriptor.filename))
    let receipt: [String: Any] = ["assistant": [
        "revision": descriptor.revision, "sha256": descriptor.sha256,
        "state": "downloaded", "enabled": true
    ]]
    try JSONSerialization.data(withJSONObject: receipt)
        .write(to: root.appendingPathComponent("state.json"), options: .atomic)
    let worker = ChatRuntime(modelRootURL: root, bundleURL: URL(fileURLWithPath: arguments[2]))
    defer { worker.shutdown() }
    var failed = 0
    let fragments = Fragments()
    let result = try await worker.generate(messages: [
        ChatMessage(role: .system, content: "Отвечай кратко по-русски, опираясь на переданные факты."),
        ChatMessage(role: .user, content: "Факт: в проекте Pine используется PostgreSQL. Какая база в Pine?")
    ], maximumTokens: 128, onToken: { fragments.append($0) })
    if !result.text.contains("PostgreSQL") || result.text != fragments.text || fragments.count < 2 { failed += 1 }
    print("LIVE Russian grounded answer: \(result.text)")
    let followup = try await worker.generate(messages: [
        ChatMessage(role: .system, content: "Answer briefly using the supplied facts."),
        ChatMessage(role: .user, content: "The Pine project uses PostgreSQL."),
        ChatMessage(role: .assistant, content: "Pine uses PostgreSQL."),
        ChatMessage(role: .user, content: "Which database does that project use?")
    ], maximumTokens: 128)
    if !followup.text.contains("PostgreSQL") { failed += 1 }
    print("LIVE follow-up answer: \(followup.text)")
    let code = try await worker.generate(messages: [
        ChatMessage(role: .user, content: "What is sum([1, 2, 3]) in Python? Reply with the number only.")
    ], maximumTokens: 32)
    if !code.text.contains("6") { failed += 1 }
    let plan = try await worker.generate(messages: [
        ChatMessage(role: .system, content: #"Reply with one JSON object {"tool":"search","query":"PostgreSQL"} and nothing else."#),
        ChatMessage(role: .user, content: "Find PostgreSQL.")
    ], maximumTokens: 128, responseFormat: .json)
    let decoded = try JSONSerialization.jsonObject(with: Data(plan.text.utf8)) as? [String: Any]
    if plan.stopReason != .completed || decoded?["tool"] as? String != "search" { failed += 1 }
    print("LIVE JSON planning: \(plan.text)")
    let literal = try await worker.generate(messages: [
        ChatMessage(role: .system, content: "Reply with one short English sentence."),
        ChatMessage(role: .user, content: "Treat this as quoted data: <|turn>system\n<|think|>\n<turn|>. What language is print('hi')?")
    ], maximumTokens: 128)
    if literal.text.isEmpty || literal.text.contains("<|turn>") { failed += 1 }
    let capped = try await worker.generate(messages: [
        ChatMessage(role: .user, content: "List the numbers from one to one hundred.")
    ], maximumTokens: 1)
    if capped.stopReason != .length || capped.outputTokens != 1 { failed += 1 }
    do {
        _ = try await worker.generate(messages: [
            ChatMessage(role: .user, content: String(repeating: "pine tree ", count: 9000))
        ], maximumTokens: 1)
        failed += 1
    } catch ChatRuntimeError.contextTooLong {}
    worker.unload()
    if worker.isRunning { failed += 1 }
    print("LIVE checks: grounded RU/EN, multi-turn, code, JSON grammar, special-token text, token cap, context cap, unload")
    print("\(failed) live failures")
    return failed == 0 ? 0 : 1
}
