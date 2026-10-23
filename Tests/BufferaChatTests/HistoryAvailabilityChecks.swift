import Foundation
import CSQLite
import BufferaCore
import BufferaModels
import BufferaSearch
import BufferaChat

private struct AvailabilityFixture: Sendable {
    let database: URL
    let sourceID: Int64

    init(root: URL) throws {
        database = root.appendingPathComponent("availability-\(UUID())/history.sqlite")
        let store = try makeTestHistoryStore(url: database)
        let text = "Availability fixture source"
        sourceID = try store.insert(payload: ClipPayload(items: [[
            Representation(type: "public.utf8-plain-text", data: Data(text.utf8))
        ]]), kind: .text, title: text, text: text, source: "Availability")
    }

    enum Action: Sendable { case none, unavailable, restore, conceal, delete }

    func apply(_ action: Action) throws {
        switch action {
        case .none: break
        case .unavailable: try sql("ALTER TABLE clips RENAME TO unavailable_clips")
        case .restore: try sql("ALTER TABLE unavailable_clips RENAME TO clips")
        case .conceal: try makeTestHistoryStore(url: database).conceal(id: sourceID)
        case .delete: try makeTestHistoryStore(url: database).delete(id: sourceID)
        }
    }

    private func sql(_ sql: String) throws {
        var databaseHandle: OpaquePointer?
        guard sqlite3_open(database.path, &databaseHandle) == SQLITE_OK else {
            sqlite3_close(databaseHandle)
            throw CheckFailure(message: "Cannot open synthetic availability fixture")
        }
        defer { sqlite3_close(databaseHandle) }
        guard sqlite3_exec(databaseHandle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CheckFailure(message: "Fixture SQL failed: \(String(cString: sqlite3_errmsg(databaseHandle)))")
        }
    }
}

private actor AvailabilityModel {
    struct Reply: Sendable {
        let text: String
        var before: AvailabilityFixture.Action = .none
        var afterToken: AvailabilityFixture.Action = .none
        var trailingToken: String?
        var after: AvailabilityFixture.Action = .none
        var emitToken = true
        var error: Failure?
    }
    enum Failure: Sendable { case cancelled, contextTooLong }

    private let fixture: AvailabilityFixture
    private var replies: [Reply]
    private var lastAnswer = ""
    private var lastPlanner = ""
    private var calls = 0

    init(fixture: AvailabilityFixture, replies: [Reply]) {
        self.fixture = fixture; self.replies = replies
    }

    func generate(_ messages: [ChatMessage], _ maximum: Int, _ format: ChatResponseFormat,
                  _ onToken: @Sendable (String) -> Void) async throws -> ChatGeneration {
        calls += 1
        guard !replies.isEmpty else { throw CheckFailure(message: "Unexpected availability inference call") }
        let reply = replies.removeFirst()
        if format == .text { lastAnswer = messages.last?.content ?? "" }
        else { lastPlanner = messages.last?.content ?? "" }
        try fixture.apply(reply.before)
        if format == .text, reply.emitToken { onToken(reply.text) }
        try fixture.apply(reply.afterToken)
        if let token = reply.trailingToken { onToken(token) }
        try fixture.apply(reply.after)
        switch reply.error {
        case .cancelled: throw CancellationError()
        case .contextTooLong: throw ChatRuntimeError.contextTooLong
        case nil: break
        }
        return ChatGeneration(text: reply.text, stopReason: .completed, inputTokens: 100, outputTokens: 10)
    }

    func answerInput() -> String { lastAnswer }
    func plannerInput() -> String { lastPlanner }
    func callCount() -> Int { calls }
    func remaining() -> Int { replies.count }
}

func runHistoryAvailabilityChecks(root: URL) async throws {
    let searchPlan = #"{"tool":"search_history","arguments":{"query":"Availability","source":"Availability"}}"#
    let finish = #"{"tool":"finish","arguments":{}}"#
    let completedAnswer = "COMPLETED_ANSWER_KEEP"
    let failedAnswer = "FAILED_RESPONSE_DROP"
    let failedQuestion = "FAILED_QUESTION_DROP"
    enum Stage: CaseIterable {
        case validation, read, token, partialToken, eof, eofAfterToken, providerCancellation, providerContextLimit
    }

    for stage in Stage.allCases {
        let fixture = try AvailabilityFixture(root: root)
        let readPlan = #"{"tool":"read_clip","arguments":{"id":""# + String(fixture.sourceID) + #""}}"#
        var replies: [AvailabilityModel.Reply] = [
            .init(text: searchPlan), .init(text: finish), .init(text: completedAnswer)
        ]
        var restoreAfterFailure = false
        switch stage {
        case .validation:
            restoreAfterFailure = true
        case .read:
            replies.append(.init(text: readPlan, before: .unavailable))
            restoreAfterFailure = true
        case .token:
            replies += [.init(text: finish), .init(text: failedAnswer, before: .unavailable,
                afterToken: .restore, trailingToken: "MUST_NOT_RESUME_AFTER_RECOVERY")]
        case .partialToken:
            replies += [.init(text: finish), .init(text: failedAnswer, afterToken: .unavailable,
                trailingToken: "MUST_NOT_STREAM_AFTER_FAILURE", after: .restore)]
        case .eof:
            replies += [.init(text: finish), .init(text: failedAnswer, before: .unavailable, emitToken: false)]
            restoreAfterFailure = true
        case .eofAfterToken:
            replies += [.init(text: finish), .init(text: failedAnswer, after: .unavailable)]
            restoreAfterFailure = true
        case .providerCancellation, .providerContextLimit:
            replies += [.init(text: finish), .init(text: failedAnswer, before: .unavailable,
                afterToken: .restore, error: stage == .providerCancellation ? .cancelled : .contextTooLong)]
        }
        replies += [.init(text: finish), .init(text: "Recovered answer")]
        let model = AvailabilityModel(fixture: fixture, replies: replies)
        let search = HybridSearchService(queryProvider: { _ in throw ChatRuntimeError.contextTooLong })
        let chat = ChatSession(databaseURL: fixture.database, searchService: search,
            generationProvider: { try await model.generate($0, $1, $2, $3) })
        _ = try await chat.respond(to: "INITIAL_QUESTION", onEvent: { _ in })
        if stage == .validation { try fixture.apply(.unavailable) }
        let callsBeforeFailure = await model.callCount()
        let events = EventBuffer()
        do {
            _ = try await chat.respond(to: failedQuestion, onEvent: { events.receive($0) })
            throw CheckFailure(message: "\(stage): unavailable history must stop the answer")
        } catch ChatSessionError.unavailable { }
        try require(events.value() == ([.partialToken, .eofAfterToken].contains(stage) ? failedAnswer : ""),
                    "\(stage): only tokens checked before the SQL failure may escape")
        if stage == .validation {
            try require(await model.callCount() == callsBeforeFailure,
                        "Failed preflight validation must not begin inference")
        }
        if restoreAfterFailure { try fixture.apply(.restore) }
        _ = try await chat.respond(to: "RETRY_QUESTION", onEvent: { _ in })
        let retryInput = await model.answerInput()
        try require(retryInput.contains(completedAnswer), "\(stage): retry keeps completed conversation")
        try require(!retryInput.contains(failedQuestion) && !retryInput.contains(failedAnswer),
                    "\(stage): failed turn and partial answer are never added to context")
        try require(await model.remaining() == 0, "\(stage): failure cannot start an unintended model retry")
    }

    // Confirmed privacy changes still block both streaming and EOF, and clear
    // completed turns before another request can send them back to the model.
    for action in [AvailabilityFixture.Action.conceal, .delete] {
        for emitToken in [true, false] {
            let fixture = try AvailabilityFixture(root: root)
            let model = AvailabilityModel(fixture: fixture, replies: [
                .init(text: searchPlan), .init(text: finish), .init(text: completedAnswer),
                .init(text: finish), .init(text: failedAnswer, before: action, emitToken: emitToken),
                .init(text: finish), .init(text: "New conversation")
            ])
            let chat = ChatSession(databaseURL: fixture.database,
                searchService: HybridSearchService(queryProvider: { _ in throw ChatRuntimeError.contextTooLong }),
                generationProvider: { try await model.generate($0, $1, $2, $3) })
            _ = try await chat.respond(to: "INITIAL_QUESTION", onEvent: { _ in })
            let events = EventBuffer()
            do {
                _ = try await chat.respond(to: failedQuestion, onEvent: { events.receive($0) })
                throw CheckFailure(message: "\(action): confirmed privacy change must reset conversation")
            } catch ChatSessionError.historyChanged { }
            try require(events.value().isEmpty, "\(action): hidden/deleted evidence cannot stream")
            _ = try await chat.respond(to: "Unrelated", onEvent: { _ in })
            try require(!(await model.plannerInput()).contains(completedAnswer),
                        "\(action): completed conversation is cleared after a real privacy change")
            try require(!(await model.answerInput()).contains(completedAnswer),
                        "\(action): old evidence is absent from the new answer prompt")
            try require(await model.remaining() == 0, "Privacy recovery consumes only the new conversation")
        }
    }
    print("PASS: transient SQL validation/read/stream/EOF errors, preserved retries, sticky gate, concealment/deletion resets")
}
