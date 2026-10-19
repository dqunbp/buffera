import AppKit
import BufferaCore
import UniformTypeIdentifiers
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store: HistoryStore!
    private let work = DispatchQueue(label: "app.buffera.history", qos: .userInitiated)
    private let clipboard = ClipboardService()
    private let hotKeys = HotKeys()
    private var panel: HistoryPanel!
    private var settings: SettingsWindow?
    private var imageTextIndexer: ImageTextIndexer?
    private var generation = 0
    private var searchGeneration = 0
    private var confirmationToken = 0
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
        panel = HistoryPanel()
        connectPanel()
        imageTextIndexer = ImageTextIndexer(store: store, storageQueue: work,
            onProgress: { [weak self] in self?.showImageTextProgress($0) },
            onIndexed: { [weak self] in self?.panel.searchIndexDidChange() },
            onError: { [weak self] in self?.showError($0) })
        cleanupExports()
        exportCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.cleanupExports() }
        clipboard.onCapture = { [weak self] clip in
            guard let self else { return }
            let date = Date(); let count = self.countLimit; let bytes = self.byteLimit
            self.work.async {
                do {
                    try self.store.insert(payload: clip.payload, kind: clip.kind, title: clip.title, text: clip.text,
                                          source: clip.source, isConcealed: clip.isConcealed, date: date, maxCount: count, maxBytes: bytes)
                    self.imageTextIndexer?.schedule()
                } catch { DispatchQueue.main.async { self.showError(error) } }
            }
        }
        clipboard.onError = { [weak self] error in self?.showError(error) }
        clipboard.start()
        hotKeys.onPress = { [weak self] delta in
            guard let self else { return }
            if self.panel.isInteracting { self.panel.move(delta) }
            else if delta > 0 { self.open() }
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
        imageTextIndexer?.stop()
    }

    private func connectPanel() {
        panel.onShowSettings = { [weak self] in self?.showSettings() }
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
            self.work.async {
                let result = Result { (try self.store.search(filter, limit: limit, offset: offset), try self.store.count(filter),
                                       refreshSources ? try self.store.sources() : nil) }
                DispatchQueue.main.async {
                    guard searchGeneration == self.searchGeneration, self.panel.window.isVisible else { return }
                    switch result {
                    case .success(let (rows, count, sources)):
                        if let sources { self.panel.setSources(sources) }
                        self.panel.receive(rows, total: count, offset: offset)
                    case .failure(let error): self.panel.searchFailed(error); self.showError(error)
                    }
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
                        try self.clipboard.restore(result.get())
                        self.logger.notice("Confirm completed")
                        self.panel.close()
                    } catch {
                        self.logger.error("Confirm failed")
                        self.panel.failed(error); self.showError(error)
                    }
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
                do { try self.store.conceal(id: id); self.imageTextIndexer?.schedule(); DispatchQueue.main.async { if self.panel.window.isVisible { self.panel.refresh(preservingSelection: true) } } }
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
                do { try self.store.delete(id: id); self.imageTextIndexer?.schedule(); DispatchQueue.main.async { if self.panel.window.isVisible { self.panel.refresh(preservingSelection: true) } } }
                catch { DispatchQueue.main.async { self.panel.failed(error) } }
            }
        }
        panel.onClose = { [weak self] in
            self?.generation += 1
            self?.searchGeneration += 1
            self?.confirmationToken += 1
            try? self?.hotKeys.setPreviousEnabled(false)
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

    private func open() {
        guard panel != nil else { if let lastError { showError(lastError, alert: true) }; return }
        confirmationToken += 1
        panel.open()
        do { try hotKeys.setPreviousEnabled(true) } catch { panel.failed(error); showError(error) }
    }
    @objc private func showHistory() { open() }
    @objc private func showSettings() {
        // A save sheet must finish before its parent can be hidden.
        if let window = panel?.window, window.attachedSheet != nil {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if settings == nil {
            let controller = SettingsWindow()
            controller.onAppearanceChange = { [weak self] value in self?.panel?.applyAppearance(value) }
            controller.onRevealData = { [weak self] in self?.revealData() }
            settings = controller
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

        Enter копирует запись и закрывает окно. Вставку выполняете сами (на Mac обычно ⌘V).

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
