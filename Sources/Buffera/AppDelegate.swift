import AppKit
import BufferaCore
import BufferaModels
import BufferaSearch
import UniformTypeIdentifiers
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store: HistoryStore!
    private let work = DispatchQueue(label: "app.buffera.history", qos: .userInitiated)
    private let clipboard = ClipboardService()
    private let clipboardSession = ClipboardSessionMonitor()
    private let hotKeys = HotKeys()
    private var panel: HistoryPanel!
    private var settings: SettingsWindow?
    private var modelManager: LocalModelManager?
    private var modelStorageError: String?
    private let modelProbe = ModelProbeController()
    private var embeddingIndexer: EmbeddingIndexer?
    private var searchService: HybridSearchService!
    private var searchTask: Task<Void, Never>?
    private var historyChat: HistoryChatCoordinator?
    private var embeddingStatus = EmbeddingIndexStatus.disabled
    private var embeddingEnabled: Bool?
    private var imageTextIndexer: ImageTextIndexer?
    private var copyTransformService: CopyTransformService?
    private var generation = 0
    private var searchGeneration = 0
    private var confirmationToken = 0
    private var captureSelectionToken = 0
    private let logger = Logger(subsystem: "local.buffera.app", category: "confirmation")
    private let temporaryImageExports = TemporaryImageExports()
    private var exportCleanupTimer: Timer?
    private var lastError: Error?
    private var pauseItem: NSMenuItem!
    private var errorItem: NSMenuItem!
    private var shortcutItem: NSMenuItem!
    private var imageTextItem: NSMenuItem!
    private var retryImageTextItem: NSMenuItem!
    private var applicationExitObserver: NSObjectProtocol?
    private var countLimit: Int { HistoryLimits.load().maxCount }
    private var byteLimit: Int { HistoryLimits.load().maxBytes }
    private var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Buffera", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Both identities must be stopped before the legacy SQLite directory moves.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: LegacyMigration.previousBundleIdentifier).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Сначала завершите предыдущую версию"
            alert.informativeText = "Предыдущая версия ещё использует историю. Закройте её через значок в строке меню и откройте Buffera снова — история и настройки перенесутся автоматически."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // One instance owns the hotkeys and the history observer.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.buffera.app")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        do {
            folder = try LegacyMigration.prepareHistory(in: folder.deletingLastPathComponent())
            try LegacyMigration.migratePreferences()
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        do { store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite")) }
        catch { showError(error, alert: true); return }
        let modelRoot = folder.appendingPathComponent("Models", isDirectory: true)
        searchService = HybridSearchService(modelRootURL: modelRoot)
        historyChat = HistoryChatCoordinator(databaseURL: folder.appendingPathComponent("history.sqlite"),
            modelRootURL: modelRoot)
        historyChat?.onOpenSource = { [weak self] in self?.openChatSource($0) }
        historyChat?.onShowFeatures = { [weak self] in
            self?.showSettings()
            self?.settings?.showFeatures()
        }
        embeddingIndexer = EmbeddingIndexer(databaseURL: folder.appendingPathComponent("history.sqlite"),
            modelRootURL: modelRoot,
            onProgress: { [weak self] status in
                DispatchQueue.main.async { self?.showEmbeddingProgress(status) }
            },
            onIndexed: { [weak self] in
                DispatchQueue.main.async { self?.panel?.searchIndexDidChange() }
            })
        do {
            let manager = try LocalModelManager(rootURL: modelRoot)
            manager.onChange = { [weak self] snapshots in self?.modelsChanged(snapshots) }
            modelManager = manager
        } catch { modelStorageError = error.localizedDescription; showError(error) }
        modelProbe.onChange = { [weak self] role, status, running in
            self?.settings?.updateModelCheck(role: role, status: status, running: running)
        }
        copyTransformService = CopyTransformService(store: store, storageQueue: work)
        panel = HistoryPanel()
        connectPanel()
        imageTextIndexer = ImageTextIndexer(store: store, storageQueue: work,
            onProgress: { [weak self] in self?.showImageTextProgress($0) },
            onIndexed: { [weak self] in
                self?.panel.searchIndexDidChange()
                self?.scheduleEmbeddings()
            },
            onError: { [weak self] in self?.showError($0) })
        cleanupExports()
        exportCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.cleanupExports() }
        clipboard.onCapture = { [weak self] clip in
            guard let self else { return }
            self.captureSelectionToken += 1
            let selectionToken = self.captureSelectionToken
            let date = Date(); let count = self.countLimit; let bytes = self.byteLimit
            self.work.async {
                do {
                    let id = try self.store.insert(payload: clip.payload, kind: clip.kind, title: clip.title, text: clip.text,
                                          source: clip.source, isConcealed: clip.isConcealed, isRemote: clip.isRemote,
                                          date: date, maxCount: count, maxBytes: bytes)
                    DispatchQueue.main.async {
                        guard selectionToken == self.captureSelectionToken else { return }
                        self.panel.clipboardDidCapture(id: id)
                    }
                    self.imageTextIndexer?.schedule()
                    self.scheduleEmbeddings()
                } catch { DispatchQueue.main.async { self.showError(error) } }
            }
        }
        clipboard.onError = { [weak self] error in self?.showError(error) }
        clipboard.captureIsAllowed = { [weak self] in self?.clipboardSession.allowsCapture ?? false }
        clipboardSession.onTransition = { [weak self] in self?.clipboard.discardPendingChanges() }
        clipboardSession.start()
        clipboard.discardPendingChanges()
        clipboard.start()
        hotKeys.onPress = { [weak self] delta, isRepeat in
            guard let self else { return }
            if self.panel.isAvailableForShortcut { self.panel.shortcutPressed(delta, isRepeat: isRepeat) }
            else if delta > 0, !isRepeat { self.open(fromShortcut: true) }
        }
        registerShortcuts()
        applicationExitObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                                     object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.hotKeys.isRegistered else { return }
            self.registerShortcuts()
        }
        open()
        imageTextIndexer?.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open(); return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard.paused = true
        clipboardSession.stop()
        imageTextIndexer?.stop()
        modelManager?.shutdown()
        modelProbe.shutdown()
        searchTask?.cancel()
        embeddingIndexer?.shutdown()
        searchService?.shutdown()
        historyChat?.shutdown()
    }

    private func connectPanel() {
        panel.onNavigate = { [weak self] in
            self?.searchGeneration += 1
            self?.searchTask?.cancel()
            self?.generation += 1
            self?.confirmationToken += 1
        }
        panel.requestNearby = { [weak self] anchorID, token in
            guard let self else { return }
            self.work.async {
                let result = Result { try self.store.nearby(anchorID: anchorID) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let rows): self.panel.receiveNearby(rows, anchorID: anchorID, token: token)
                    case .failure(let error): self.panel.nearbyFailed(error, token: token)
                    }
                }
            }
        }
        panel.onShowSettings = { [weak self] in self?.showSettings() }
        panel.onShowChat = { [weak self] in self?.showChat() }
        panel.onAppearanceChange = { [weak self] value in self?.settings?.updateAppearance(value) }
        panel.request = { [weak self] filter, offset, limit in
            guard let self else { return }
            let refreshSources = offset == 0 && !self.panel.isRefreshingSearchIndex
            if offset == 0 {
                self.searchGeneration += 1
                // OCR refreshes the same view: its existing thumbnail/action requests remain valid.
                if !self.panel.isRefreshingSearchIndex { self.generation += 1 }
            }
            let searchGeneration = self.searchGeneration
            self.searchTask?.cancel()
            let mode = self.panel.searchMode
            let databaseURL = self.folder.appendingPathComponent("history.sqlite")
            self.searchTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if offset == 0, !filter.query.isEmpty {
                        try await Task.sleep(nanoseconds: 180_000_000)
                    }
                    let response = try await self.searchService.search(databaseURL: databaseURL,
                        filter: filter, mode: mode, limit: limit, offset: offset)
                    let sources: [String]? = refreshSources
                        ? try await self.historySources() : nil
                    try Task.checkCancellation()
                    guard searchGeneration == self.searchGeneration, self.panel.window.isVisible else { return }
                    if let sources { self.panel.setSources(sources) }
                    self.panel.updateSearchMode(response.mode, reason: response.fallbackReason)
                    self.panel.receive(response.rows, total: response.total, offset: offset)
                } catch is CancellationError {
                    return
                } catch {
                    guard searchGeneration == self.searchGeneration, self.panel.window.isVisible else { return }
                    self.panel.searchFailed(error); self.showError(error)
                }
            }
        }
        panel.onConfirm = { [weak self] id in
            guard let self else { return }
            self.confirmationToken += 1
            let token = self.confirmationToken
            // Confirmation owns a snapshot of the choice. Search refreshes must
            // not silently drop it; only closing/reopening the panel cancels it.
            self.work.async {
                let result = Result { try self.store.payload(id: id) }
                DispatchQueue.main.async {
                    guard token == self.confirmationToken, self.panel.window.isVisible else {
                        self.logger.notice("Confirm cancelled"); return
                    }
                    do {
                        try self.restoreClipboard(result.get(), id: id)
                        self.logger.notice("Confirm completed")
                        self.panel.closeAfterConfirmation()
                    } catch {
                        self.logger.error("Confirm failed")
                        self.panel.failed(error); self.showError(error)
                    }
                }
            }
        }
        panel.requestCopyTransformOperations = { [weak self] id, completion in
            guard let service = self?.copyTransformService else {
                completion(.failure(CopyTransformError.unavailable)); return
            }
            service.operations(id: id, completion: completion)
        }
        panel.requestCopyTransform = { [weak self] id, operation, completion in
            guard let service = self?.copyTransformService else {
                completion(.failure(CopyTransformError.unavailable)); return
            }
            service.transform(id: id, operation: operation, completion: completion)
        }
        panel.onCancelCopyTransformed = { [weak self] in self?.confirmationToken += 1 }
        panel.onCopyTransformed = { [weak self] id, text, completion in
            guard let self else { completion(CopyTransformError.cancelled); return }
            self.confirmationToken += 1
            let token = self.confirmationToken
            self.work.async {
                let validation = Result {
                    let clip = try self.store.summary(id: id)
                    guard !CopyTransformOperation.available(for: clip).isEmpty else { throw CopyTransformError.unavailable }
                    guard !text.isEmpty else { throw CopyTransformError.noText }
                }
                DispatchQueue.main.async {
                    guard token == self.confirmationToken, self.panel.isAvailableForShortcut,
                          self.panel.isConfirmingCopyTransform else {
                        completion(CopyTransformError.cancelled); return
                    }
                    do {
                        try validation.get()
                        let payload = ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.string.rawValue,
                                                                          data: Data(text.utf8))]])
                        try self.restoreClipboard(payload, id: id)
                        completion(nil)
                    } catch { completion(error) }
                }
            }
        }
        panel.requestThumbnail = { [weak self] id, completion in
            guard let self else { return }
            let current = self.generation
            self.work.async {
                let result = Result { ClipboardService.thumbnail(try self.store.payload(id: id)) }
                DispatchQueue.main.async {
                    guard current == self.generation else { return }
                    switch result {
                    case .success(let image): completion(image)
                    case .failure(let error): self.showError(error); completion(nil)
                    }
                }
            }
        }
        panel.onReveal = { [weak self] id, token in
            self?.loadPayload(id) { [weak self] payload in self?.panel.showConcealedText(ClipboardService.revealedText(payload), id: id, token: token) }
        }
        panel.onConceal = { [weak self] id in
            guard let self else { return }
            self.work.async {
                do {
                    try self.store.conceal(id: id)
                    self.imageTextIndexer?.schedule(); self.scheduleEmbeddings()
                    DispatchQueue.main.async {
                        self.historyChat?.historyChanged(id: id)
                        if self.panel.window.isVisible { self.panel.refresh(preservingSelection: true) }
                    }
                }
                catch { DispatchQueue.main.async { self.panel.failed(error); self.showError(error) } }
            }
        }
        panel.onFavorite = { [weak self] id, isFavorite in
            guard let self else { return }
            self.work.async {
                do {
                    try self.store.setFavorite(id: id, isFavorite: isFavorite)
                    DispatchQueue.main.async { self.panel.favoriteFinished(id: id, isFavorite: isFavorite, error: nil) }
                } catch {
                    DispatchQueue.main.async { self.panel.favoriteFinished(id: id, isFavorite: isFavorite, error: error); self.showError(error) }
                }
            }
        }
        panel.onPreview = { [weak self] clip, token in
            guard let self, !clip.isConcealed else { return }
            let current = self.generation
            self.work.async {
                let content: ClipPreviewContent
                do { content = ClipPreviewContent.decode(try self.store.payload(id: clip.id), kind: clip.kind) }
                catch { content = .unavailable(error.localizedDescription) }
                DispatchQueue.main.async {
                    guard current == self.generation else { return }
                    self.panel.showPreview(content, id: clip.id, token: token)
                }
            }
        }
        panel.onExport = { [weak self] id, chooseDestination in
            self?.loadPayload(id) { [weak self] payload in self?.exportImage(payload, id: id, chooseDestination: chooseDestination) }
        }
        panel.onDelete = { [weak self] id in
            guard let self else { return }
            self.work.async {
                do {
                    try self.store.delete(id: id)
                    self.imageTextIndexer?.schedule(); self.scheduleEmbeddings()
                    DispatchQueue.main.async {
                        self.historyChat?.historyChanged(id: id)
                        if self.panel.window.isVisible { self.panel.refresh(preservingSelection: true) }
                    }
                }
                catch { DispatchQueue.main.async { self.panel.failed(error) } }
            }
        }
        panel.onShortcutGestureEnd = { [weak self] in self?.hotKeys.resetPressedKeys() }
        panel.onClose = { [weak self] in
            self?.generation += 1
            self?.searchGeneration += 1
            self?.searchTask?.cancel()
            self?.confirmationToken += 1
            self?.hotKeys.resetPressedKeys()
            try? self?.hotKeys.setPreviousEnabled(false)
        }
    }

    private func historySources() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            work.async { continuation.resume(with: Result { try self.store.sources() }) }
        }
    }

    private func scheduleEmbeddings() {
        guard let embeddingIndexer else { return }
        Task { await embeddingIndexer.schedule() }
    }

    private func modelsChanged(_ snapshots: [LocalModelSnapshot]) {
        settings?.updateModels(snapshots)
        historyChat?.modelsChanged(snapshots)
        let enabled = snapshots.contains {
            $0.descriptor.role == .embedding && $0.isReadyForUse
        }
        guard enabled != embeddingEnabled else { return }
        embeddingEnabled = enabled
        // Let an active query finish (or fall back after runtime unload). Cancelling here leaves
        // the panel in its loading state, which also prevents the deferred index refresh.
        Task { @MainActor [weak self] in
            guard let self, enabled == self.embeddingEnabled else { return }
            await self.embeddingIndexer?.setEnabled(enabled)
            guard enabled == self.embeddingEnabled else { return }
            if !enabled { await self.searchService.unload() }
            self.panel?.searchIndexDidChange()
        }
    }

    private func showEmbeddingProgress(_ status: EmbeddingIndexStatus) {
        embeddingStatus = status
        settings?.updateEmbeddingIndex(status: status.message, progress: status.fraction, canRetry: status.canRetry)
    }

    /// Normal and transformed copies share suppression and usage ordering.
    private func restoreClipboard(_ payload: ClipPayload, id: Int64) throws {
        try clipboard.restore(payload)
        // A capture queued before this restore remains in history, but cannot reclaim selection.
        captureSelectionToken += 1
        // Queue usage before closing so an immediate reopen observes the successful copy.
        work.async {
            do { try self.store.markUsed(id: id) }
            catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    private func loadPayload(_ id: Int64, completion: @escaping (ClipPayload) -> Void) {
        let current = generation
        work.async {
            let result = Result { try self.store.payload(id: id) }
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                switch result {
                case .success(let payload): completion(payload)
                case .failure(let error): self.panel.failed(error); self.showError(error)
                }
            }
        }
    }

    private func exportImage(_ payload: ClipPayload, id: Int64, chooseDestination: Bool) {
        guard let (data, ext) = ClipboardService.imageData(payload) else { panel.failed(ClipboardFailure.noImage); return }
        let name = "\(BrandIdentity.name)-\(id).\(ext)"
        if chooseDestination {
            let dialog = NSSavePanel(); dialog.nameFieldStringValue = name; dialog.allowedContentTypes = [.png]
            dialog.beginSheetModal(for: panel.window) { [weak self] response in
                if response == .OK, let url = dialog.url { self?.writeImage(data, to: url, reveal: false) }
            }
        } else {
            do {
                let url = try temporaryImageExports.file(data: data, id: id, fileExtension: ext)
                panel.close(restoreFocus: false)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { panel.failed(error); showError(error) }
        }
    }

    private func writeImage(_ data: Data, to url: URL, reveal: Bool) {
        do {
            try data.write(to: url, options: .atomic)
            if reveal { panel.close(restoreFocus: false); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch { panel.failed(error); showError(error) }
    }

    private func open(fromShortcut: Bool = false) {
        guard panel != nil else { if let lastError { showError(lastError, alert: true) }; return }
        confirmationToken += 1
        panel.open(fromShortcut: fromShortcut)
        do { try hotKeys.setPreviousEnabled(true) } catch { panel.failed(error); showError(error) }
    }
    @objc private func showHistory() { open() }
    @objc private func showChat() {
        guard let historyChat else { return }
        if panel?.window.attachedSheet != nil { return }
        if panel?.window.isVisible == true { panel.close(restoreFocus: false) }
        historyChat.show()
    }

    private func openChatSource(_ id: Int64) {
        guard panel.window.attachedSheet == nil else { return }
        work.async { [weak self] in
            guard let self else { return }
            let result = Result {
                let summary = try self.store.summary(id: id)
                guard !summary.isConcealed else { throw HistoryError.missing }
                return summary
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let clip):
                    self.confirmationToken += 1
                    self.panel.openSource(clip)
                    do { try self.hotKeys.setPreviousEnabled(true) } catch { self.showError(error) }
                case .failure:
                    self.historyChat?.historyChanged(id: id)
                }
            }
        }
    }

    @objc private func showSettings() {
        // A save sheet must finish before its parent can be hidden.
        if let window = panel?.window, window.attachedSheet != nil {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if settings == nil {
            let controller = SettingsWindow(modelManager: modelManager, modelError: modelStorageError,
                                            mcpAccess: MCPAccess(directory: folder))
            controller.onCheckModel = { [weak self] role in
                guard let self, let url = self.modelManager?.modelURL(for: role) else { return }
                self.modelProbe.check(role, modelURL: url)
            }
            controller.onCancelModelCheck = { [weak self] role in self?.modelProbe.cancel(role) }
            controller.onWillDisableOrRemoveModel = { [weak self] role in
                self?.modelProbe.cancel(role)
                self?.historyChat?.willDisableModel(role)
            }
            controller.onRetryEmbeddingIndex = { [weak self] in
                guard let indexer = self?.embeddingIndexer else { return }
                Task { await indexer.retry() }
            }
            controller.onAppearanceChange = { [weak self] value in self?.panel?.applyAppearance(value) }
            controller.onRevealData = { [weak self] in self?.revealData() }
            controller.onCopyMCPConfiguration = { [weak self] configuration in
                guard let self else { throw MCPSettingsError.copyUnavailable }
                try self.clipboard.restore(ClipPayload(items: [[Representation(
                    type: NSPasteboard.PasteboardType.string.rawValue, data: Data(configuration.utf8))]]))
            }
            settings = controller
            showEmbeddingProgress(embeddingStatus)
        }
        if panel?.window.isVisible == true { panel.close(restoreFocus: false) }
        settings?.show()
    }
    private func cleanupExports() {
        do { try temporaryImageExports.cleanup() } catch { showError(error) }
    }
    @objc private func registerShortcuts() {
        do {
            try hotKeys.register()
            shortcutItem.title = "⌘⌥V подключено"
        } catch {
            shortcutItem.title = "Подключить ⌘⌥V снова…"
            showError(error)
        }
    }
    @objc private func togglePause() {
        clipboard.paused.toggle(); pauseItem.state = clipboard.paused ? .on : .off
        statusItem.button?.appearsDisabled = clipboard.paused
    }
    @objc private func revealData() { NSWorkspace.shared.open(folder) }
    @objc private func quit() { work.sync {}; NSApp.terminate(nil) }
    @objc private func retryImageText() { imageTextIndexer?.retryFailed() }
    private func showImageTextProgress(_ progress: ImageTextProgress) {
        if progress.pending > 0 {
            imageTextItem.title = "Распознавание картинок: осталось \(progress.pending)"
        } else if progress.failed > 0 {
            imageTextItem.title = "Не удалось распознать: \(progress.failed)"
        } else {
            imageTextItem.title = "Поиск по картинкам: готово"
        }
        retryImageTextItem.isHidden = progress.failed == 0
    }
    @objc private func showLastError() { if let lastError { showError(lastError, alert: true) } }
    @objc private func help() {
        let alert = NSAlert(); alert.messageText = "\(BrandIdentity.name) — клавиши и история"
        let actions = ClipCardAction.allCases.map { "\($0.shortcut) — \($0.title)" }.joined(separator: "\n")
        alert.informativeText = """
        ⌘⌥V — открыть / следующий элемент
        ⌘⌥C — предыдущий в открытом окне
        Стрелки — выбрать запись
        ⌘⌥S — скрыть или показать боковое меню
        ⌘, — настройки
        ⌘1–9 — выбрать одну из первых девяти записей
        ⌘F — перейти к поиску, ⌘0 — вся история
        Escape — закрыть просмотр или окно

        \(actions)

        Действия находятся внутри карточек и в их контекстном меню. Подсказки кнопок показывают сочетания. Пробел открывает просмотр при выборе записи; в поле поиска он вводит пробел. ⌘Y открывает просмотр и из поиска.

        Запрос, фильтры и раздел сохраняются между открытиями окна до перезапуска \(BrandIdentity.name). Избранное хранится постоянно и не удаляется автоматически при достижении лимитов обычной истории.

        Текст на новых и ранее сохранённых картинках распознаётся на Mac в фоне и участвует в обычном поиске. Поддерживаются русский и английский. Прогресс и повтор неудачных попыток доступны через значок \(BrandIdentity.name) в строке меню. Скрытые записи не распознаются.

        Enter копирует запись, поднимает её наверх и закрывает окно. Дата копирования сохраняется. Escape и переход в другое приложение закрывают без выбора. Вставку выполняете сами (на Mac обычно ⌘V).

        «Показать в Finder» создаёт временную PNG-копию: очистка через 24 часа, лимит 256 МиБ. «Сохранить как…» сохраняет файл постоянно.

        Помеченные пароли скрыты точками. Кнопка глаза раскрывает скрытую запись или скрывает обычный текст. Маскировка не шифрует локальную базу.
        """
        alert.runModal()
    }

    private func showError(_ error: Error, alert: Bool = false) {
        lastError = error; errorItem.isHidden = false
        errorItem.title = "Последняя ошибка…"
        statusItem.button?.toolTip = error.localizedDescription
        if alert { let dialog = NSAlert(error: error); NSApp.activate(ignoringOtherApps: true); dialog.runModal() }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "BufferaClipboard"
        statusItem.isVisible = true
        statusItem.button?.image = BrandIdentity.menuBarIcon()
        statusItem.button?.setAccessibilityLabel("\(BrandIdentity.name) — буфер обмена")
        statusItem.button?.toolTip = "\(BrandIdentity.name) — история буфера обмена"
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
        }
        _ = add("Открыть историю    ⌘⌥V", #selector(showHistory))
        _ = add("Спросить Buffera…", #selector(showChat))
        let settingsItem = add("Настройки…", #selector(showSettings))
        settingsItem.keyEquivalent = ","
        shortcutItem = add("Подключить ⌘⌥V…", #selector(registerShortcuts))
        pauseItem = add("Приостановить запись", #selector(togglePause))
        menu.addItem(.separator())
        imageTextItem = NSMenuItem(title: "Подготовка поиска по картинкам…", action: nil, keyEquivalent: "")
        menu.addItem(imageTextItem)
        retryImageTextItem = add("Повторить распознавание", #selector(retryImageText))
        retryImageTextItem.isHidden = true
        menu.addItem(.separator())
        _ = add("Папка данных…", #selector(revealData))
        _ = add("Клавиши и справка…", #selector(help))
        errorItem = add("Последняя ошибка…", #selector(showLastError)); errorItem.isHidden = true
        menu.addItem(.separator()); _ = add("Завершить \(BrandIdentity.name)", #selector(quit))
        statusItem.menu = menu
        // Standard editing commands are needed for the search field in an accessory app.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: BrandIdentity.name)
        let chatItem = NSMenuItem(title: "Спросить Buffera…", action: #selector(showChat), keyEquivalent: "")
        chatItem.target = self; appMenu.addItem(chatItem)
        let appearanceItem = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        appearanceItem.target = self; appMenu.addItem(appearanceItem); appMenu.addItem(.separator())
        let helpItem = NSMenuItem(title: "Клавиши и справка…", action: #selector(help), keyEquivalent: "")
        helpItem.target = self; appMenu.addItem(helpItem); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Завершить \(BrandIdentity.name)", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "Правка")
        for (title, selector, key) in [("Вырезать", #selector(NSText.cut(_:)), "x"), ("Копировать", #selector(NSText.copy(_:)), "c"), ("Вставить", #selector(NSText.paste(_:)), "v"), ("Выделить всё", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        edit.submenu = editMenu; mainMenu.addItem(edit); NSApp.mainMenu = mainMenu
    }
}
