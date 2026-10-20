import AppKit
import BufferaChat
import BufferaModels

/// AppKit owns presentation; the session owns retrieval and local inference.
/// A generation number prevents cancelled turns from updating a newer window.
final class HistoryChatCoordinator {
    var onOpenSource: ((Int64) -> Void)?
    var onShowModels: (() -> Void)?
    private let session: ChatSession
    private var controller: HistoryChatWindow?
    private var responseTask: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var unloadingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var generation = 0
    private var answer = ""
    private var sourceIDs = Set<Int64>()
    private var enabled = false
    private var availabilityMessage = "Скачайте и включите модель чата в настройках."

    init(databaseURL: URL, modelRootURL: URL) {
        session = ChatSession(databaseURL: databaseURL, modelRootURL: modelRootURL)
    }

    func show() {
        if controller == nil {
            let window = HistoryChatWindow()
            window.onSend = { [weak self] in self?.send($0) }
            window.onStop = { [weak self] in self?.stop() }
            window.onNewConversation = { [weak self] in self?.reset() }
            window.onOpenSource = { [weak self] in self?.onOpenSource?($0) }
            window.onShowModels = { [weak self] in self?.onShowModels?() }
            controller = window
        }
        controller?.setAvailability(enabled: enabled, message: enabled ? nil : availabilityMessage)
        controller?.show()
    }

    func modelsChanged(_ snapshots: [LocalModelSnapshot]) {
        enabled = snapshots.contains {
            $0.descriptor.role == .assistant && $0.state == .downloaded && $0.isEnabled
        }
        if snapshots.contains(where: { $0.descriptor.role == .assistant && $0.state == .downloaded }) {
            availabilityMessage = "Включите модель чата в настройках, чтобы задать вопрос."
        } else {
            availabilityMessage = "Скачайте и включите модель чата в настройках."
        }
        if !enabled { stop() }
        controller?.setAvailability(enabled: enabled, message: enabled ? nil : availabilityMessage)
    }

    func willDisableModel(_ role: ModelRole) {
        if role == .assistant { stop() }
    }

    func historyChanged(id: Int64) {
        guard responseTask != nil || sourceIDs.contains(id) else { return }
        reset()
        controller?.setStatus("Источник скрыт или удалён. Начат новый разговор.")
    }

    func shutdown() {
        generation += 1
        responseTask?.cancel(); resetTask?.cancel()
        session.shutdown()
    }

    private func send(_ question: String) {
        guard enabled, responseTask == nil else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard question.utf8.count <= 8000, question.count <= 2000 else {
            controller?.setStatus(ChatSessionError.questionTooLong.localizedDescription)
            return
        }
        generation += 1
        let current = generation
        answer = ""
        controller?.beginResponse(question: question)
        let pendingReset = resetTask
        let pendingCancellation = drainingTask
        let pendingUnload = unloadingTask
        responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await pendingCancellation?.value
            await pendingUnload?.value
            await pendingReset?.value
            do {
                try Task.checkCancellation()
                let result = try await self.session.respond(to: question) { [weak self] event in
                    DispatchQueue.main.async {
                        guard let self, self.generation == current, self.responseTask != nil else { return }
                        switch event {
                        case .status(let status): self.controller?.setStatus(status)
                        case .sources(let sources): self.sourceIDs.formUnion(sources.map(\.id))
                        case .token(let text):
                            self.answer += text
                            self.controller?.updateResponse(text: self.answer)
                        }
                    }
                }
                try Task.checkCancellation()
                guard current == self.generation else { return }
                self.responseTask = nil
                self.answer = result.answer
                self.sourceIDs.formUnion(result.sources.map(\.id))
                self.controller?.updateResponse(text: result.answer)
                self.controller?.finishResponse(sources: result.sources,
                    status: result.truncated ? "Ответ или найденные записи сокращены по объёму." : nil)
            } catch is CancellationError {
                guard current == self.generation else { return }
                self.responseTask = nil
                self.controller?.finishResponse(sources: [], status: "Ответ остановлен.")
            } catch ChatSessionError.historyChanged {
                guard current == self.generation else { return }
                self.reset()
                self.controller?.setStatus(ChatSessionError.historyChanged.localizedDescription)
            } catch {
                guard current == self.generation else { return }
                self.responseTask = nil
                self.controller?.failResponse(error.localizedDescription)
            }
        }
    }

    private func stop() {
        generation += 1
        let wasRunning = responseTask != nil
        if let responseTask {
            responseTask.cancel()
            drainingTask = responseTask
        }
        responseTask = nil
        let previousUnload = unloadingTask
        let currentUnload = session.unload()
        unloadingTask = Task {
            await previousUnload?.value
            await currentUnload.value
        }
        if wasRunning { controller?.finishResponse(sources: [], status: "Ответ остановлен.") }
    }

    private func reset() {
        stop()
        answer = ""; sourceIDs.removeAll()
        controller?.resetConversation()
        let previous = resetTask
        let pendingCancellation = drainingTask
        let pendingUnload = unloadingTask
        resetTask = Task { [session] in
            await pendingCancellation?.value
            await pendingUnload?.value
            await previous?.value
            await session.reset()
        }
    }
}
