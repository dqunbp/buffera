import AppKit
import BufferaModels

/// Rendering and user actions only; the application owns downloads and model processes.
final class ModelSettingsView: NSView {
    var onCheck: ((ModelRole) -> Void)?
    var onCancelCheck: ((ModelRole) -> Void)?
    var onWillDisableOrRemove: ((ModelRole) -> Void)?
    var onRetryEmbeddingIndex: (() -> Void)?

    private let manager: LocalModelManager?
    private var cards: [ModelRole: ModelCardView] = [:]

    init(manager: LocalModelManager?, unavailableMessage: String? = nil) {
        self.manager = manager
        super.init(frame: .zero)

        let introduction = modelParagraph(
            "Включите модель поиска, чтобы находить записи по смыслу. История обрабатывается постепенно на этом Mac. Локальный чат появится на следующем этапе."
        )
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.addArrangedSubview(introduction)
        if manager == nil {
            let unavailable = modelParagraph(unavailableMessage ?? "Не удалось открыть хранилище моделей.")
            unavailable.textColor = .systemRed
            content.addArrangedSubview(unavailable)
            unavailable.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        #if !arch(arm64)
        let unsupported = modelParagraph("Локальные модели пока доступны только на Mac с Apple Silicon.")
        unsupported.textColor = .systemOrange
        content.addArrangedSubview(unsupported)
        unsupported.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        #endif

        for snapshot in manager?.snapshots ?? [] {
            let card = ModelCardView(snapshot: snapshot)
            let role = snapshot.descriptor.role
            card.onDownload = { [weak manager] in manager?.download(role) }
            card.onPause = { [weak manager] in manager?.pause(role) }
            card.onRemove = { [weak self] in
                self?.onWillDisableOrRemove?(role)
                self?.manager?.remove(role)
            }
            card.onSetEnabled = { [weak self] enabled in
                if !enabled { self?.onWillDisableOrRemove?(role) }
                self?.manager?.setEnabled(enabled, for: role)
            }
            card.onCheck = { [weak self] in self?.onCheck?(role) }
            card.onCancelCheck = { [weak self] in self?.onCancelCheck?(role) }
            card.onRetryIndex = { [weak self] in self?.onRetryEmbeddingIndex?() }
            cards[role] = card
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        introduction.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let note = modelParagraph(
            "Выключение останавливает обработку и освобождает память. Скачанные файлы остаются на диске; «Удалить» убирает их отдельно. Скрытые записи не индексируются."
        )
        content.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.identifier = NSUserInterfaceItemIdentifier("models.scroll")
        let document = ModelSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        if let manager { update(manager.snapshots) }
    }

    func update(_ snapshots: [LocalModelSnapshot]) {
        for snapshot in snapshots { cards[snapshot.descriptor.role]?.update(snapshot) }
    }

    func updateCheck(role: ModelRole, status: String, running: Bool) {
        cards[role]?.updateCheck(status: status, running: running)
    }

    func updateEmbeddingIndex(status: String, progress: Double?, canRetry: Bool) {
        cards[.embedding]?.updateIndex(status: status, progress: progress, canRetry: canRetry)
    }
}

private final class ModelSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ModelCardView: NSBox {
    var onDownload: (() -> Void)?
    var onPause: (() -> Void)?
    var onRemove: (() -> Void)?
    var onSetEnabled: ((Bool) -> Void)?
    var onCheck: (() -> Void)?
    var onCancelCheck: (() -> Void)?
    var onRetryIndex: (() -> Void)?

    private var snapshot: LocalModelSnapshot
    private var isChecking = false
    private let enabled = NSButton(checkboxWithTitle: "Использовать модель", target: nil, action: nil)
    private let modelName = NSTextField(labelWithString: "")
    private let status = modelParagraph("")
    private let progress = NSProgressIndicator()
    private let primary = NSButton()
    private let remove = NSButton()
    private let check = NSButton()
    private let checkStatus = modelParagraph("")
    private let indexStatus = modelParagraph("")
    private let indexProgress = NSProgressIndicator()
    private let retryIndex = NSButton()

    init(snapshot: LocalModelSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        boxType = .custom
        borderWidth = 0
        cornerRadius = 12
        fillColor = .controlBackgroundColor
        contentViewMargins = .zero

        let prefix = "models.\(snapshot.descriptor.role.rawValue)"
        identifier = NSUserInterfaceItemIdentifier(prefix)
        let title = NSTextField(labelWithString: snapshot.descriptor.role == .embedding
                                ? "Поиск по смыслу" : "Локальный помощник")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        enabled.font = .systemFont(ofSize: 11)
        enabled.target = self
        enabled.action = #selector(changeEnabled)
        enabled.identifier = NSUserInterfaceItemIdentifier("\(prefix).enabled")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [title, spacer, enabled])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8

        modelName.font = .systemFont(ofSize: 11)
        modelName.lineBreakMode = .byTruncatingTail
        modelName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelName.identifier = NSUserInterfaceItemIdentifier("\(prefix).name")
        status.identifier = NSUserInterfaceItemIdentifier("\(prefix).status")
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.identifier = NSUserInterfaceItemIdentifier("\(prefix).progress")
        progress.setAccessibilityLabel("Загрузка \(snapshot.descriptor.title)")
        configure(primary, action: #selector(primaryAction), identifier: "\(prefix).download")
        configure(remove, action: #selector(removeModel), identifier: "\(prefix).remove")
        remove.title = "Удалить"
        configure(check, action: #selector(checkModel), identifier: "\(prefix).check")
        check.toolTip = "Проверить русский и английский текст и код на встроенных примерах"
        let license = NSButton(title: "Лицензия", target: self, action: #selector(showLicense))
        license.bezelStyle = .inline
        license.font = .systemFont(ofSize: 11)
        license.identifier = NSUserInterfaceItemIdentifier("\(prefix).license")
        let actions = NSStackView(views: [primary, check, remove, license])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        checkStatus.identifier = NSUserInterfaceItemIdentifier("\(prefix).checkStatus")
        checkStatus.isSelectable = true
        checkStatus.isHidden = true
        indexStatus.identifier = NSUserInterfaceItemIdentifier("\(prefix).indexStatus")
        indexStatus.isHidden = true
        indexProgress.style = .bar
        indexProgress.controlSize = .small
        indexProgress.minValue = 0
        indexProgress.maxValue = 1
        indexProgress.isIndeterminate = false
        indexProgress.isHidden = true
        indexProgress.identifier = NSUserInterfaceItemIdentifier("\(prefix).indexProgress")
        indexProgress.setAccessibilityLabel("Подготовка истории для поиска по смыслу")
        configure(retryIndex, action: #selector(retryIndexing), identifier: "\(prefix).retryIndex")
        retryIndex.title = "Повторить обработку"
        retryIndex.isHidden = true

        let stack = NSStackView(views: [heading, modelName, status, progress, actions, checkStatus,
                                      indexStatus, indexProgress, retryIndex])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView else { return }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        for view in [heading, modelName, status, progress, checkStatus, indexStatus, indexProgress] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        update(snapshot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: LocalModelSnapshot) {
        self.snapshot = snapshot
        if snapshot.state != .downloaded {
            isChecking = false
            checkStatus.stringValue = ""
            checkStatus.isHidden = true
        }
        let total = modelByteCount(snapshot.totalBytes)
        let received = modelByteCount(snapshot.receivedBytes)
        modelName.stringValue = "\(snapshot.descriptor.title) · \(total)"
        modelName.toolTip = snapshot.descriptor.summary
        enabled.state = snapshot.isEnabled ? .on : .off
        enabled.isEnabled = snapshot.state == .downloaded && platformSupported
        primary.isHidden = snapshot.state == .downloaded
        primary.isEnabled = snapshot.totalBytes > 0 && platformSupported
        remove.isHidden = snapshot.state == .notDownloaded
        remove.isEnabled = platformSupported
        progress.isHidden = ![.downloading, .paused, .verifying].contains(snapshot.state)
        progress.isIndeterminate = snapshot.state == .verifying
        if progress.isIndeterminate { progress.startAnimation(nil) }
        else {
            progress.stopAnimation(nil)
            progress.doubleValue = min(1, max(0, snapshot.progress))
        }
        status.textColor = .secondaryLabelColor
        switch snapshot.state {
        case .notDownloaded:
            status.stringValue = "Не скачана"
            primary.title = "Скачать · \(total)"
        case .downloading:
            status.stringValue = "Загружено \(received) из \(total)"
            primary.title = "Пауза"
        case .paused:
            status.stringValue = "На паузе · \(received) из \(total)"
            primary.title = "Продолжить"
        case .verifying:
            status.stringValue = "Проверяем скачанные файлы"
            primary.title = "Проверка файлов…"
            primary.isEnabled = false
        case .downloaded:
            status.stringValue = snapshot.isEnabled ? "Готова к работе" : "Скачана · выключена"
        case .failed:
            status.stringValue = snapshot.errorMessage ?? "Не удалось загрузить модель"
            status.textColor = .systemRed
            primary.title = snapshot.receivedBytes > 0 ? "Продолжить" : "Повторить загрузку"
        }
        if let error = snapshot.errorMessage, snapshot.state != .failed {
            status.stringValue += "\n\(error)"
            status.textColor = .systemRed
        }
        updateCheckButton()
    }

    func updateCheck(status: String, running: Bool) {
        guard snapshot.state == .downloaded else { return }
        isChecking = running
        checkStatus.stringValue = status
        checkStatus.isHidden = status.isEmpty
        updateCheckButton()
    }

    func updateIndex(status: String, progress: Double?, canRetry: Bool) {
        guard snapshot.descriptor.role == .embedding else { return }
        indexStatus.stringValue = status
        indexStatus.isHidden = status.isEmpty
        indexProgress.isHidden = progress == nil
        if let progress { indexProgress.doubleValue = max(0, min(1, progress)) }
        retryIndex.isHidden = !canRetry
        retryIndex.isEnabled = snapshot.state == .downloaded && snapshot.isEnabled && platformSupported
    }

    private func updateCheckButton() {
        check.isHidden = snapshot.state != .downloaded && !isChecking
        check.title = isChecking ? "Остановить проверку" : "Проверить модель"
        check.isEnabled = platformSupported && (isChecking || (snapshot.state == .downloaded && snapshot.isEnabled))
    }

    private var platformSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private func configure(_ button: NSButton, action: Selector, identifier: String) {
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
    }

    @objc private func primaryAction() {
        if snapshot.state == .downloading { onPause?() }
        else { onDownload?() }
    }

    @objc private func changeEnabled() { onSetEnabled?(enabled.state == .on) }
    @objc private func removeModel() { onRemove?() }
    @objc private func retryIndexing() { onRetryIndex?() }
    @objc private func checkModel() {
        if isChecking { onCancelCheck?() }
        else { onCheck?() }
    }
    @objc private func showLicense() { NSWorkspace.shared.open(snapshot.descriptor.licenseURL) }
}

private func modelParagraph(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 11)
    field.textColor = .secondaryLabelColor
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    return field
}

private func modelByteCount(_ count: Int64) -> String {
    let units: [(Int64, String)] = [(1_000_000_000, "ГБ"), (1_000_000, "МБ"), (1_000, "КБ")]
    for (divisor, suffix) in units where count >= divisor {
        let value = (Double(count) / Double(divisor)).formatted(
            .number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(0...2))
        )
        return "\(value) \(suffix)"
    }
    return "\(count) Б"
}
