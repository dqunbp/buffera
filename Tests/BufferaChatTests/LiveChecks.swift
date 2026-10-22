import Foundation
import BufferaCore
import BufferaChat
import BufferaModels
import BufferaSearch

/// Opt-in, real model check using a fresh history database. Models must be provided in an
/// explicitly chosen fixture directory; this command never enables the user's model receipts.
func runLiveChatCheck(arguments: [String]) async throws {
    func value(_ flag: String) throws -> URL {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            throw CheckFailure(message: "Live check requires --model-root PATH --bundle PATH")
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }
    let models = try value("--model-root")
    let bundle = try value("--bundle")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BufferaChatLive-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("history.sqlite")
    let store = try makeTestHistoryStore(url: database)
    func insert(_ text: String, seconds: TimeInterval, hidden: Bool = false) throws -> Int64 {
        try store.insert(payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text",
            data: Data(text.utf8))]]), kind: .text, title: text, text: text, source: "Safari",
            isConcealed: hidden, date: Date(timeIntervalSince1970: seconds),
            maxCount: 100, maxBytes: 1_000_000)
    }
    let release = try insert("Проект Borealis: релиз назначен на 18 ноября 2026 года. Ответственная — Ирина.",
                             seconds: 100)
    let review = try insert("Проект Borealis: проверка сборки 17 ноября 2026 года.", seconds: 110)
    _ = try insert("Список продуктов: молоко, хлеб, яблоки.", seconds: 120)
    let secret = "BUFFERA_HIDDEN_LIVE_SENTINEL_893"
    _ = try insert("Проект Borealis: \(secret)", seconds: 105, hidden: true)
    let trace = arguments.contains("--trace")
    let runtime = ChatRuntime(modelRootURL: models, bundleURL: bundle)
    let search = HybridSearchService(modelRootURL: models, bundleURL: bundle)
    let chat = ChatSession(databaseURL: database, searchService: search,
        generationProvider: { messages, maximum, format, onToken in
            let response = try await runtime.generate(messages: messages, maximumTokens: maximum,
                                                       responseFormat: format, onToken: onToken)
            if trace {
                let line = "SYNTHETIC \(format.rawValue) [\(response.stopReason.rawValue)]: \(response.text)\n"
                try FileHandle.standardError.write(contentsOf: Data(line.utf8))
            }
            return response
        })
    defer { runtime.shutdown() }
    defer { chat.shutdown() }
    let first = try await chat.respond(to: "Когда назначен релиз проекта Borealis?", onEvent: { event in
        if case .status(let status) = event {
            try? FileHandle.standardError.write(contentsOf: Data("STATE: \(status)\n".utf8))
        }
    })
    try require(first.sources.contains { $0.id == release }, "Live model must retrieve the matching release source")
    try require(first.answer.contains("18"), "Live answer must contain the date from evidence")
    try require(!first.answer.contains(secret), "Concealed fixture must remain unavailable")
    let followup = try await chat.respond(to: "Что копировал рядом с найденной записью про релиз?", onEvent: { _ in })
    try require(followup.sources.contains { $0.id == review }, "Live follow-up must read neighboring capture")
    try require(followup.answer.contains("17") || followup.answer.lowercased().contains("проверк"),
                "Live follow-up answer must actually describe the neighboring review, not repeat the anchor")
    try require(!followup.answer.contains(secret), "Follow-up must exclude concealed neighbor")
    print("PASS: real local model, isolated history retrieval, citations, neighbor follow-up, concealed exclusion")
}
