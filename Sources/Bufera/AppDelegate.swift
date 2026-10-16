import AppKit
import BuferaCore
import UniformTypeIdentifiers
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store: HistoryStore!
    private let work = DispatchQueue(label: "app.bufera.history", qos: .userInitiated)
    private let clipboard = ClipboardService()
    private let hotKeys = HotKeys()
    private var panel: HistoryPanel!
    private var generation = 0
    private var confirmationToken = 0
    private let logger = Logger(subsystem: "local.bufera.app", category: "confirmation")
    private let temporaryImageExports = TemporaryImageExports()
    private var exportCleanupTimer: Timer?
    private var lastError: Error?
    private var pauseItem: NSMenuItem!
    private var errorItem: NSMenuItem!
    private var shortcutItem: NSMenuItem!
    private var applicationExitObserver: NSObjectProtocol?
    private var countLimit: Int { UserDefaults.standard.object(forKey: "maxCount") as? Int ?? 50_000 }
    private var byteLimit: Int { UserDefaults.standard.object(forKey: "maxBytes") as? Int ?? 5_000_000_000 }
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bufera", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // One instance owns the hotkeys and the history observer.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.bufera.app")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        buildMenu()
        do { store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite")) }
        catch { showError(error, alert: true); return }
        panel = HistoryPanel()
        connectPanel()
        cleanupExports()
        exportCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.cleanupExports() }
        clipboard.onCapture = { [weak self] clip in
            guard let self else { return }
            let date = Date(); let count = self.countLimit; let bytes = self.byteLimit
            self.work.async {
                do {
                    try self.store.insert(payload: clip.payload, kind: clip.kind, title: clip.title, text: clip.text,
                                          source: clip.source, isConcealed: clip.isConcealed, date: date, maxCount: count, maxBytes: bytes)
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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open(); return true
    }

    private func connectPanel() {
        panel.request = { [weak self] filter, offset in
            guard let self else { return }
            if offset == 0 { self.generation += 1 }
            let generation = self.generation
            self.work.async {
                let result = Result { (try self.store.search(filter, offset: offset), try self.store.count(filter),
                                       offset == 0 ? try self.store.sources() : nil) }
                DispatchQueue.main.async {
                    guard generation == self.generation, self.panel.window.isVisible else { return }
                    switch result {
                    case .success(let (rows, count, sources)):
                        if let sources { self.panel.setSources(sources) }
                        self.panel.receive(rows, total: count, offset: offset)
                    case .failure(let error): self.panel.failed(error); self.showError(error)
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
                do { try self.store.conceal(id: id); DispatchQueue.main.async { self.panel.refresh() } }
                catch { DispatchQueue.main.async { self.panel.failed(error); self.showError(error) } }
            }
        }
        panel.onExport = { [weak self] id, chooseDestination in
            self?.loadPayload(id) { [weak self] payload in self?.exportImage(payload, id: id, chooseDestination: chooseDestination) }
        }
        panel.onDelete = { [weak self] id in
            guard let self else { return }
            self.work.async {
                do { try self.store.delete(id: id); DispatchQueue.main.async { self.panel.refresh() } }
                catch { DispatchQueue.main.async { self.panel.failed(error) } }
            }
        }
        panel.onClose = { [weak self] in
            self?.generation += 1
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
        let name = "Bufera-\(id).\(ext)"
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
    @objc private func showLastError() { if let lastError { showError(lastError, alert: true) } }
    @objc private func setLimit(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: sender.representedObject as! String)
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
    }
    @objc private func help() {
        let alert = NSAlert(); alert.messageText = "Bufera — клавиши и история"
        alert.informativeText = "⌘⌥V — открыть / следующий элемент\n⌘⌥C — предыдущий в открытом окне\n↑ ↓ — выбрать, Enter — в буфер и закрыть\n⌘F — перейти к поиску\nEscape — отменить\n⌘⌫ — удалить запись из истории\n\nПосле отпускания клавиш окно остаётся открытым. Вставку выполняете сами (на Mac обычно ⌘V).\n\nФильтры: тип, дата и приложение. Даты можно выбрать в календаре.\n\n«Показать в Finder» создаёт временную PNG-копию: очистка через 24 часа после последнего открытия, лимит 256 МиБ. «Сохранить как…» сохраняет файл постоянно.\n\nПомеченные пароли скрыты точками и не участвуют в текстовом поиске. «Показать» раскрывает выбранную запись до смены выбора или закрытия окна. Маскировка не шифрует локальную базу. Непомеченный пароль может выглядеть как обычный текст."
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
        statusItem.autosaveName = "BuferaClipboard"
        statusItem.isVisible = true
        let icon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Bufera — буфер обмена")
        icon?.size = NSSize(width: 17, height: 17)
        icon?.isTemplate = true
        statusItem.button?.image = icon
        if icon == nil { statusItem.button?.title = "B" }
        statusItem.button?.setAccessibilityLabel("Bufera — буфер обмена")
        statusItem.button?.toolTip = "Bufera — история буфера обмена"
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
        }
        _ = add("Открыть историю    ⌘⌥V", #selector(showHistory))
        shortcutItem = add("Подключить ⌘⌥V…", #selector(registerShortcuts))
        pauseItem = add("Приостановить запись", #selector(togglePause))
        menu.addItem(.separator())
        for (title, key, values, labels) in [
            ("Количество записей", "maxCount", [10_000, 50_000, 100_000], ["10 000", "50 000", "100 000"]),
            ("Объём истории", "maxBytes", [1_000_000_000, 5_000_000_000, 20_000_000_000], ["1 ГБ", "5 ГБ", "20 ГБ"])
        ] {
            let submenu = NSMenu(); let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = submenu; menu.addItem(parent)
            for (value, label) in zip(values, labels) {
                let item = NSMenuItem(title: label, action: #selector(setLimit), keyEquivalent: "")
                item.target = self; item.tag = value; item.representedObject = key
                item.state = value == (key == "maxCount" ? countLimit : byteLimit) ? .on : .off
                submenu.addItem(item)
            }
        }
        _ = add("Папка данных…", #selector(revealData))
        _ = add("Клавиши и справка…", #selector(help))
        errorItem = add("Последняя ошибка…", #selector(showLastError)); errorItem.isHidden = true
        menu.addItem(.separator()); _ = add("Завершить Bufera", #selector(quit))
        statusItem.menu = menu
        // Standard editing commands are needed for the search field in an accessory app.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "Bufera")
        let helpItem = NSMenuItem(title: "Клавиши и справка…", action: #selector(help), keyEquivalent: "")
        helpItem.target = self; appMenu.addItem(helpItem); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Завершить Bufera", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "Правка")
        for (title, selector, key) in [("Вырезать", #selector(NSText.cut(_:)), "x"), ("Копировать", #selector(NSText.copy(_:)), "c"), ("Вставить", #selector(NSText.paste(_:)), "v"), ("Выделить всё", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        edit.submenu = editMenu; mainMenu.addItem(edit); NSApp.mainMenu = mainMenu
    }
}
