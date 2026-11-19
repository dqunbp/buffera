import AppKit
import BufferaModels
import BufferaLocalization
import UniformTypeIdentifiers

/// Selection is staged until the user explicitly connects the file.
final class ModelSourceView: NSStackView {
    private let manager: LocalModelManager
    private let role: ModelRole
    private let discovery: () -> [ExternalModels.Candidate]
    private let found = NSTextField(wrappingLabelWithString: "")
    private let choices = NSPopUpButton()
    private let rescan = NSButton()
    private let origin = NSTextField(wrappingLabelWithString: "")
    private var scanning = false
    private var manualSelection = false
    var connectButton: NSButton { connect }
    private let choose = NSButton()
    private let selected = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let connect = NSButton()
    private var candidates: [ExternalModels.Candidate] = []
    private var selectedURL: URL?
    private var busy = false
    private var activating = false
    var onWillChange: (() -> Void)?
    var onConnected: (() -> Void)?
    var onNeedsResize: (() -> Void)?
    var onBusyChanged: ((Bool) -> Void)?

    init(manager: LocalModelManager, role: ModelRole,
         discovery: @escaping () -> [ExternalModels.Candidate] = { ExternalModels.discover() }) {
        self.manager = manager
        self.role = role
        self.discovery = discovery
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        let prefix = "models.\(role.rawValue)"
        let title = NSTextField(labelWithString: role == .embedding ? L10n.text("Поиск по смыслу") : L10n.text("Спросить Buffera"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        found.stringValue = L10n.text("Ищем модели в Foresight и кеше Hugging Face…")
        origin.identifier = .init("\(prefix).sourceOrigin")
        found.identifier = .init("\(prefix).discoveryStatus")
        configure(rescan, title: L10n.text("Обновить список"), action: #selector(rescanModels), id: "\(prefix).rescan")
        choices.identifier = .init("\(prefix).source")
        choices.target = self
        choices.action = #selector(selectCandidate)
        choices.setAccessibilityLabel(L10n.text("Выберите модель…"))
        configure(choose, title: L10n.text("Выбрать файл…"), action: #selector(chooseFile), id: "\(prefix).chooseFile")
        configure(connect, title: L10n.text("Подключить"), action: #selector(connectFile), id: "\(prefix).connectSource")
        connect.keyEquivalent = "\r"
        selected.isSelectable = true
        selected.identifier = .init("\(prefix).sourcePath")
        status.identifier = .init("\(prefix).sourceStatus")
        status.isHidden = true
        let supportedTitle = NSTextField(labelWithString: L10n.text("Поддерживаемые модели"))
        supportedTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let supported = NSTextField(wrappingLabelWithString: ExternalModels.supported.filter { $0.role == role }.map {
            let variant = $0.engine == .llama ? $0.filename : "\($0.title) · LiteRT-LM (Foresight)"
            return "\(variant) · \(modelByteCount($0.byteCount))"
        }.joined(separator: "\n"))
        supported.identifier = .init("\(prefix).supportedSources")
        let compatibility = NSTextField(wrappingLabelWithString: L10n.text("Поддерживаются только перечисленные версии моделей. Другие версии и квантования не подходят. Совместимость файла проверяется перед подключением."))
        let manual = NSTextField(wrappingLabelWithString: L10n.text("Если модель хранится в другой папке, выберите файл вручную."))
        for field in [selected, origin, status, supported, compatibility, manual, found] {
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        let modelLabel = NSTextField(labelWithString: L10n.text("Модель"))
        let selectionRow = NSStackView(views: [choices, rescan])
        selectionRow.orientation = .horizontal
        selectionRow.spacing = 8
        choices.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [title, supportedTitle, supported, compatibility, modelLabel, selectionRow, origin, selected, found, manual, choose, status] {
            addArrangedSubview(view)
        }
        for view in [found, selectionRow, origin, selected, supported, compatibility, manual, status] {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { discover() }
    }

    @objc private func rescanModels() { discover() }

    func discover() {
        guard !scanning, !busy else { return }
        scanning = true
        found.stringValue = L10n.text("Ищем модели в Foresight и кеше Hugging Face…")
        found.isHidden = false
        updateSelection()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = discovery()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scanning = false
                candidates = result.filter { $0.descriptor.role == self.role }
                if !manualSelection && !candidates.contains(where: { $0.url == self.selectedURL }) {
                    selectedURL = candidates.first?.url
                }
                found.stringValue = L10n.text("В Foresight и кеше Hugging Face подходящих файлов не найдено.")
                found.isHidden = !candidates.isEmpty
                updateSelection()
            }
        }
    }

    func refresh() {
        guard activating, let snapshot = manager.snapshots.first(where: { $0.descriptor.role == role }) else { return }
        if snapshot.isReadyForUse && snapshot.externalURL?.standardizedFileURL == selectedURL?.standardizedFileURL {
            activating = false
            setBusy(false)
            onConnected?()
        } else if let error = snapshot.errorMessage {
            activating = false
            setBusy(false)
            showError(error)
        }
    }

    private func configure(_ button: NSButton, title: String, action: Selector, id: String) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.identifier = .init(id)
    }

    @objc private func selectCandidate() {
        let index = choices.indexOfSelectedItem
        guard candidates.indices.contains(index) else { return }
        manualSelection = false
        selectedURL = candidates[index].url
        updateSelection()
    }

    private func updateSelection() {
        choices.removeAllItems()
        for candidate in candidates {
            choices.addItem(withTitle: "\(candidate.descriptor.title) · \(modelByteCount(candidate.descriptor.byteCount))")
            choices.lastItem?.toolTip = candidate.url.path
        }
        if let selectedURL {
            if let index = candidates.firstIndex(where: { $0.url == selectedURL }) {
                choices.selectItem(at: index)
            } else {
                // Preserve a manually chosen file when discovery finishes or refreshes.
                choices.addItem(withTitle: selectedURL.lastPathComponent)
                choices.selectItem(at: choices.numberOfItems - 1)
            }
        } else {
            choices.addItem(withTitle: L10n.text("Выберите модель…"))
        }
        choices.isEnabled = !busy && !scanning && (!candidates.isEmpty || selectedURL != nil)
        rescan.isEnabled = !busy && !scanning
        if manualSelection {
            origin.stringValue = L10n.text("Выбрана вручную")
        } else if let candidate = candidates.first(where: { $0.url == selectedURL }) {
            origin.stringValue = candidate.source == .foresight
                ? L10n.text("Найдена в Foresight") : L10n.text("Найдена в кеше Hugging Face")
        }
        origin.isHidden = selectedURL == nil
        selected.stringValue = selectedURL?.path ?? ""
        selected.isHidden = selectedURL == nil
        connect.isEnabled = selectedURL != nil && !busy && !scanning
        status.isHidden = true
        onNeedsResize?()
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf"), UTType(filenameExtension: "litertlm")].compactMap { $0 }
        panel.message = L10n.text("Выберите проверенную модель Buffera или Foresight. Файл останется на прежнем месте.")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            selectFile(url)
        }
    }

    func selectFile(_ url: URL) {
        guard !busy else { return }
        manualSelection = true
        selectedURL = url
        updateSelection()
    }

    private func setBusy(_ value: Bool) {
        busy = value
        rescan.isEnabled = !value && !scanning
        choices.isEnabled = !value && !scanning && (!candidates.isEmpty || selectedURL != nil)
        choose.isEnabled = !value
        connect.isEnabled = !value && !scanning && selectedURL != nil
        onBusyChanged?(value)
    }

    private func showError(_ message: String) {
        status.stringValue = message
        status.textColor = .systemRed
        status.isHidden = false
        onNeedsResize?()
    }

    @objc private func connectFile() {
        guard let selectedURL, !busy, !scanning else { return }
        setBusy(true)
        status.textColor = .secondaryLabelColor
        status.isHidden = false
        status.stringValue = L10n.text("Проверяем выбранный файл…")
        onNeedsResize?()
        manager.selectExternal(selectedURL, for: role) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                onWillChange?()
                activating = true
                manager.setEnabled(true, for: role)
            case .failure(let error):
                setBusy(false)
                showError(error.localizedDescription)
            }
        }
    }
}
