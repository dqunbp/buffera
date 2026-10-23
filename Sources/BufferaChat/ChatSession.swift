import BufferaLocalization
import Foundation
import BufferaCore
import BufferaModels
import BufferaSearch

/// A bounded conversation lives only in memory. Every new turn reads its sources again.
public actor ChatSession {
    private struct Turn {
        let question: String
        let answer: String
        let sources: [ChatSource]
    }
    private struct Observation: Encodable {
        let tool: String
        let items: [ChatHistoryItem]?
        let document: ChatEvidence?
        let error: String?
        let searchQuery: String?

        init(tool: String, items: [ChatHistoryItem]?, document: ChatEvidence?, error: String?,
             searchQuery: String? = nil) {
            self.tool = tool; self.items = items; self.document = document
            self.error = error; self.searchQuery = searchQuery
        }
    }
    private struct PreviousSource: Encodable {
        let id: String
        let title: String
    }
    private struct PreviousTurn: Encodable {
        let question: String
        let answer: String
    }
    private struct PlannerInput: Encodable {
        let question: String
        let conversation: [PreviousTurn]
        let previousSources: [PreviousSource]
        let observations: [Observation]
        let decisionsRemaining: Int
    }
    private struct AnswerInput: Encodable {
        let question: String
        let conversation: [PreviousTurn]
        let neighborAnchors: [String]
        let evidence: [ChatEvidence]
    }

    private let runtime: ChatRuntime?
    private let provider: ChatGenerationProvider
    private let reader: ChatHistoryReader
    private var turns: [Turn] = []
    private var activeID: UUID?

    public init(databaseURL: URL, modelRootURL: URL, bundleURL: URL = Bundle.main.bundleURL,
                embeddingRuntime: EmbeddingRuntime? = nil) {
        let runtime = ChatRuntime(modelRootURL: modelRootURL, bundleURL: bundleURL)
        self.runtime = runtime
        provider = { messages, maximum, format, onToken in
            try await runtime.generate(messages: messages, maximumTokens: maximum,
                                       responseFormat: format, onToken: onToken)
        }
        reader = ChatHistoryReader(databaseURL: databaseURL,
            searchService: HybridSearchService(modelRootURL: modelRootURL, bundleURL: bundleURL,
                                               embeddingRuntime: embeddingRuntime))
    }

    public init(databaseURL: URL, searchService: HybridSearchService,
                generationProvider: @escaping ChatGenerationProvider) {
        runtime = nil; provider = generationProvider
        reader = ChatHistoryReader(databaseURL: databaseURL, searchService: searchService)
    }

    public func reset() {
        activeID = nil
        turns = []
        runtime?.unload()
    }

    /// Closing the window releases the worker without losing completed conversation turns.
    @discardableResult public nonisolated func unload() -> Task<Void, Never> {
        runtime?.unload()
        return Task { await reader.searchService.unload() }
    }

    public nonisolated func shutdown() {
        runtime?.shutdown()
        reader.searchService.shutdown()
    }

    public func respond(to rawQuestion: String,
                        onEvent: @escaping @Sendable (ChatEvent) -> Void) async throws -> ChatTurnResult {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw ChatSessionError.emptyQuestion }
        guard question.count <= 2000, question.utf8.count <= 8000 else { throw ChatSessionError.questionTooLong }
        guard activeID == nil else { throw ChatSessionError.busy }
        let id = UUID()
        activeID = id
        defer { if activeID == id { activeID = nil } }
        do {
            return try await run(question: question, id: id, onEvent: onEvent)
        } catch ChatSessionError.historyChanged {
            turns = []
            throw ChatSessionError.historyChanged
        } catch HistoryError.missing {
            turns = []
            throw ChatSessionError.historyChanged
        } catch let error as HistoryError {
            if case .database = error { throw ChatSessionError.unavailable }
            throw ChatSessionError.unavailable
        }
    }

    private func run(question: String, id: UUID,
                     onEvent: @escaping @Sendable (ChatEvent) -> Void) async throws -> ChatTurnResult {
        let previousSources = turns.flatMap(\.sources)
        let previousIDs = Set(previousSources.map(\.id))
        try reader.validate(ids: previousIDs)
        try check(id)
        let planner = try ChatPrompts.planner(now: Date(), sources: reader.sourceNames())
        var knownIDs = previousIDs
        var observedIDs = previousIDs
        var candidates: [Int64] = []
        var neighborIDs: [Int64] = []
        var neighborAnchors: Set<Int64> = []
        var observations: [Observation] = []
        var evidence: [ChatEvidence] = []
        var numbers: [Int64: Int] = [:]
        var executedPlans: Set<String> = []
        var fallback = false

        onEvent(.status(L10n.text("Ищу подходящие записи…")))
        planning: for decision in 0..<4 {
            try check(id)
            try reader.validate(ids: observedIDs)
            let input = PlannerInput(question: question,
                conversation: turns.map { PreviousTurn(question: $0.question, answer: $0.answer) },
                previousSources: previousSources.map { PreviousSource(id: String($0.id), title: $0.title) },
                observations: observations, decisionsRemaining: 4 - decision)
            let response: ChatGeneration
            do {
                response = try await provider(messages(system: planner, user: try chatJSON(input),
                                                       includePrevious: false),
                                              384, .json, { _ in })
                try check(id)
            } catch ChatRuntimeError.contextTooLong {
                fallback = true
                break
            }
            // A length-limited JSON response is never treated as an executable plan.
            guard response.stopReason == .completed, let plan = try? ChatPlan.parse(response.text) else {
                fallback = true
                break
            }
            let canonical = try JSONSerialization.data(
                withJSONObject: JSONSerialization.jsonObject(with: Data(response.text.utf8)), options: [.sortedKeys])
            let signature = String(decoding: canonical, as: UTF8.self)
            if !executedPlans.insert(signature).inserted {
                observations.append(Observation(tool: "repeated_call", items: nil, document: nil,
                    error: "This exact call already succeeded. Do not repeat it. Choose read_clip for a different known ID, get_neighbors for surrounding captures, or finish."))
                continue
            }
            do {
                switch plan {
                case .finish: break planning
                case .search(let filter, let limit, let offset):
                    onEvent(.status(L10n.text("Ищу подходящие записи…")))
                    let page = try await reader.search(filter, limit: limit, offset: offset)
                    let rows = page.rows
                    try check(id)
                    candidates = rows.map(\.id)
                    for row in rows {
                        knownIDs.insert(row.id); observedIDs.insert(row.id)
                    }
                    observations.append(Observation(tool: "search_history", items: rows.map(ChatHistoryItem.init),
                                                    document: nil, error: nil, searchQuery: page.query))
                case .read(let clipID, let offset, let limit):
                    guard knownIDs.contains(clipID) else { throw ChatPlanError.invalid }
                    onEvent(.status(L10n.text("Читаю найденное…")))
                    let remaining = 24_000 - evidence.reduce(0) { $0 + $1.text.utf8.count }
                    guard remaining > 0 else { break planning }
                    let number = numbers[clipID] ?? numbers.count + 1
                    let document = try reader.read(id: clipID, number: number, offset: offset, limit: limit,
                                                   bytes: min(16_000, remaining))
                    numbers[clipID] = number
                    evidence.append(document)
                    observedIDs.insert(clipID)
                    observations.append(Observation(tool: "read_clip", items: nil, document: document, error: nil))
                case .neighbors(let anchor, let before, let after):
                    guard knownIDs.contains(anchor) else { throw ChatPlanError.invalid }
                    onEvent(.status(L10n.text("Смотрю соседние копирования…")))
                    let rows = try reader.neighbors(id: anchor, before: before, after: after)
                    neighborAnchors.insert(anchor)
                    candidates = rows.map(\.id)
                    let anchorDate = rows.first { $0.id == anchor }?.date ?? .distantPast
                    neighborIDs = rows.filter { $0.id != anchor }.sorted {
                        let left = abs($0.date.timeIntervalSince(anchorDate))
                        let right = abs($1.date.timeIntervalSince(anchorDate))
                        return left == right ? $0.id < $1.id : left < right
                    }.prefix(3).map(\.id)
                    for row in rows {
                        knownIDs.insert(row.id); observedIDs.insert(row.id)
                    }
                    observations.append(Observation(tool: "get_neighbors", items: rows.map(ChatHistoryItem.init),
                                                    document: nil, error: nil))
                }
            } catch ChatPlanError.invalid {
                observations.append(Observation(tool: "invalid", items: nil, document: nil,
                    error: "Invalid arguments or unknown ID. Use only IDs and limits returned by the tools."))
            }
        }
        try check(id)
        if observations.isEmpty, previousSources.isEmpty { fallback = true }
        if candidates.isEmpty, observations.isEmpty, !fallback {
            candidates = previousSources.map(\.id)
        }
        if fallback && candidates.isEmpty {
            onEvent(.status(L10n.text("Ищу по вашему вопросу…")))
            var filter = SearchFilter()
            filter.query = chatPrefix(question, characters: 1000, bytes: 4000)
            let page = try await reader.search(filter, limit: 6)
            try check(id)
            candidates = page.rows.map(\.id)
        }
        // Small models sometimes finish after snippets. Read a bounded set before synthesis,
        // so every answer source refers to actual original text/OCR rather than an invented ID.
        if evidence.isEmpty {
            for clipID in candidates.prefix(3) {
                try check(id)
                let number = numbers[clipID] ?? numbers.count + 1
                let document = try reader.read(id: clipID, number: number, limit: 3000, bytes: 8000)
                numbers[clipID] = number
                evidence.append(document)
            }
        }
        // The neighbor tool deliberately returns bounded metadata. Hydrate its nearest results
        // even if a small model used its remaining decision to reread only the anchor.
        for clipID in neighborIDs where !evidence.contains(where: { $0.source.id == clipID }) {
            try check(id)
            let remaining = 24_000 - evidence.reduce(0) { $0 + $1.text.utf8.count }
            guard remaining > 0 else { break }
            let number = numbers[clipID] ?? numbers.count + 1
            let document = try reader.read(id: clipID, number: number, limit: 3000,
                                           bytes: min(8000, remaining))
            numbers[clipID] = number
            evidence.append(document)
        }
        try check(id)
        let usedIDs = Set(evidence.map { $0.source.id }).union(previousIDs)
        try reader.validate(ids: usedIDs)
        var sourceIDs: Set<Int64> = []
        let sources = evidence.compactMap { document -> ChatSource? in
            sourceIDs.insert(document.source.id).inserted ? document.source : nil
        }
        onEvent(.sources(sources))
        let gate = ChatStreamGuard(reader: reader, ids: usedIDs)
        let runtime = runtime
        onEvent(.status(evidence.isEmpty ? L10n.text("Подходящих записей не найдено…") : L10n.text("Готовлю ответ…")))
        var answer: ChatGeneration?
        var budget = 24_000
        var bounded = evidence
        for attempt in 0..<5 {
            try check(id)
            do {
                let input = AnswerInput(question: question,
                    conversation: attempt == 0 ? turns.map { PreviousTurn(question: $0.question, answer: $0.answer) } : [],
                    neighborAnchors: neighborAnchors.sorted().map(String.init), evidence: bounded)
                let context = messages(system: ChatPrompts.answer, user: try chatJSON(input),
                                       includePrevious: false)
                answer = try await provider(context, 1024, .text, { token in
                    guard gate.permits() else { runtime?.unload(); return }
                    onEvent(.token(token))
                })
                break
            } catch {
                if let failure = gate.failure { throw failure }
                if case ChatRuntimeError.contextTooLong = error, attempt < 4 {
                    budget /= 2
                    let perDocument = max(128, budget / max(1, evidence.count))
                    bounded = evidence.map { $0.bounded(bytes: perDocument) }
                    continue
                }
                throw error
            }
        }
        try check(id)
        guard gate.permits() else { throw gate.failure ?? ChatSessionError.unavailable }
        guard let answer, !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatSessionError.emptyAnswer
        }
        turns.append(Turn(question: question,
                          answer: chatPrefix(answer.text, characters: 2000, bytes: 8000), sources: sources))
        turns = Array(turns.suffix(2))
        return ChatTurnResult(answer: answer.text, sources: sources,
                              truncated: answer.stopReason == .length || bounded.contains(where: \.truncated))
    }

    private func messages(system: String, user: String, includePrevious: Bool = true) -> [ChatMessage] {
        var messages = [ChatMessage(role: .system, content: system)]
        if includePrevious {
            for turn in turns {
                messages.append(ChatMessage(role: .user, content: turn.question))
                messages.append(ChatMessage(role: .assistant, content: turn.answer))
            }
        }
        messages.append(ChatMessage(role: .user, content: user))
        return messages
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
    }
}
