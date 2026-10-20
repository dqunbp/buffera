import BufferaLocalization
import AppKit
import BufferaChat
import BufferaModels

/// AppKit owns presentation; the session owns retrieval and local inference.
/// A generation number prevents cancelled turns from updating a newer window.
final class HistoryChatCoordinator {
    var onOpenSource: ((Int64) -> Void)?
    var onShowFeatures: (() -> Void)?
    var onActivityChange: ((Bool) -> Void)?
    private let session: ChatSession
    private var controller: HistoryChatWindow?
    private var responseTask: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var unloadingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var isActive = false
    private var generation = 0
    private var answer = ""
    private var sourceIDs = Set<Int64>()
    private var enabled = false
    private var availabilityMessage = L10n.text("Для работы помощника скачайте модель в настройках «Поиск и ответы».")

    init(databaseURL: URL, modelRootURL: URL, embeddingRuntime: EmbeddingRuntime? = nil) {
        session = ChatSession(databaseURL: databaseURL, modelRootURL: modelRootURL,
                              embeddingRuntime: embeddingRuntime)
    }

    func show() {
        if controller == nil {
            let window = HistoryChatWindow()
            window.onSend = { [weak self] in self?.send($0) }
            window.onStop = { [weak self] in self?.stop() }
            window.onNewConversation = { [weak self] in self?.reset() }
            window.onOpenSource = { [weak self] in self?.onOpenSource?($0) }
            window.onShowFeatures = { [weak self] in self?.onShowFeatures?() }
            controller = window
        }
        controller?.setAvailability(enabled: enabled, message: enabled ? nil : availabilityMessage)
        controller?.show()
    }

    func modelsChanged(_ snapshots: [LocalModelSnapshot]) {
        let assistant = snapshots.first { $0.descriptor.role == .assistant }
        let wasEnabled = enabled
        enabled = assistant?.isReadyForUse == true
        availabilityMessage = L10n.text("Для работы помощника скачайте модель в настройках «Поиск и ответы».")
        if let assistant {
            switch assistant.state {
            case .downloading:
                availabilityMessage = L10n.text("Скачивается модель \(assistant.descriptor.title) · \(Int(assistant.progress * 100))%. После проверки можно будет задать вопрос.")
            case .verifying:
                availabilityMessage = L10n.text("Проверяем скачанную модель.")
            case .paused:
                availabilityMessage = L10n.text("Подготовка модели на паузе. Продолжите её в настройках.")
            case .failed:
                availabilityMessage = L10n.text("Не удалось подготовить модель. Повторите попытку в настройках.")
            case .notDownloaded:
                break
            case .downloaded:
                availabilityMessage = L10n.text("Включите «Спросить Buffera» в настройках, чтобы задать вопрос.")
            }
        }
        if wasEnabled && !enabled { stop() }
        controller?.setAvailability(enabled: enabled, message: enabled ? nil : availabilityMessage)
    }

    func willDisableModel(_ role: ModelRole) {
        if role == .assistant { stop() }
    }

    func historyChanged(id: Int64) {
        guard responseTask != nil || sourceIDs.contains(id) else { return }
        reset()
        controller?.setStatus(L10n.text("Источник скрыт или удалён. Начат новый разговор."))
    }

    func shutdown() {
        generation += 1
        responseTask?.cancel(); resetTask?.cancel(); activityTask?.cancel()
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
        setActive(true)
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
                    status: result.truncated ? L10n.text("Ответ или найденные записи сокращены по объёму.") : nil)
                self.setActive(false)
            } catch is CancellationError {
                guard current == self.generation else { return }
                self.responseTask = nil
                self.controller?.finishResponse(sources: [], status: L10n.text("Ответ остановлен."))
                self.setActive(false)
            } catch ChatSessionError.historyChanged {
                guard current == self.generation else { return }
                self.reset()
                self.controller?.setStatus(ChatSessionError.historyChanged.localizedDescription)
            } catch {
                guard current == self.generation else { return }
                self.responseTask = nil
                self.controller?.failResponse(error.localizedDescription)
                self.setActive(false)
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
        let current = generation
        let pendingCancellation = drainingTask
        let pendingUnload = unloadingTask
        activityTask?.cancel()
        activityTask = Task { @MainActor [weak self] in
            await pendingCancellation?.value
            await pendingUnload?.value
            guard !Task.isCancelled, let self, self.generation == current,
                  self.responseTask == nil else { return }
            self.setActive(false)
        }
        if wasRunning { controller?.finishResponse(sources: [], status: L10n.text("Ответ остановлен.")) }
    }

    private func setActive(_ value: Bool) {
        guard value != isActive else { return }
        isActive = value
        onActivityChange?(value)
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
