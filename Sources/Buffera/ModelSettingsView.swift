import AppKit
import BufferaModels

/// Rendering and user actions only; the application owns downloads and model processes.
final class ModelSettingsView: NSView {
    var onCheck: ((ModelRole) -> Void)?
    var onCancelCheck: ((ModelRole) -> Void)?
    var onWillDisableOrRemove: ((ModelRole) -> Void)?
    var onRetryEmbeddingIndex: (() -> Void)?
    var onOnlyPrepareOnExternalPowerChanged: ((Bool) -> Void)?
    var onContinueEmbeddingPreparation: (() -> Void)?

    private let manager: LocalModelManager?
    private var cards: [ModelRole: ModelCardView] = [:]

    init(manager: LocalModelManager?, unavailableMessage: String? = nil) {
        self.manager = manager
        super.init(frame: .zero)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        if manager == nil {
            let unavailable = modelParagraph(unavailableMessage ?? "Не удалось открыть скачанные файлы.")
            unavailable.textColor = .systemRed
            content.addArrangedSubview(unavailable)
            unavailable.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        #if !arch(arm64)
        let unsupported = modelParagraph("Эти функции пока доступны только на Mac с Apple Silicon.")
        unsupported.textColor = .systemOrange
        content.addArrangedSubview(unsupported)
        unsupported.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        #endif

        for snapshot in manager?.snapshots ?? [] {
            let card = ModelCardView(snapshot: snapshot)
            let role = snapshot.descriptor.role
            card.onDownload = { [weak manager] in manager?.setEnabled(true, for: role) }
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
            card.onOnlyPrepareOnExternalPowerChanged = { [weak self] in
                self?.onOnlyPrepareOnExternalPowerChanged?($0)
            }
            card.onContinuePreparation = { [weak self] in self?.onContinueEmbeddingPreparation?() }
            cards[role] = card
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let note = modelParagraph(
            "Обе функции работают на этом Mac. Интернет нужен только для скачивания. Скрытые записи не используются."
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

    func updateEmbeddingIndex(status: String, progress: Double?, canRetry: Bool, canContinueNow: Bool = false) {
        cards[.embedding]?.updateIndex(status: status, progress: progress, canRetry: canRetry,
                                      canContinueNow: canContinueNow)
    }

    func updateBackgroundPreparation(onlyOnExternalPower: Bool) {
        cards[.embedding]?.updateBackgroundPreparation(onlyOnExternalPower: onlyOnExternalPower)
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
    var onOnlyPrepareOnExternalPowerChanged: ((Bool) -> Void)?
    var onContinuePreparation: (() -> Void)?

    private var snapshot: LocalModelSnapshot
    private var isChecking = false
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let modelName = modelParagraph("")
    private let status = modelParagraph("")
    private let progress = NSProgressIndicator()
    private let primary = NSButton()
    private let remove = NSButton()
    private let check = NSButton()
    private let checkStatus = modelParagraph("")
    private let indexStatus = modelParagraph("")
    private let indexProgress = NSProgressIndicator()
    private let retryIndex = NSButton()
    private let continuePreparation = NSButton()
    private let onlyOnExternalPower = NSButton(
        checkboxWithTitle: "Готовить историю для поиска по смыслу только при питании от сети",
        target: nil, action: nil)
    private var indexHasProgress = false
    private var indexCanRetry = false
    private var indexCanContinueNow = false
    private let details = NSStackView()
    private let disclosure = NSButton(title: "Подробнее", target: nil, action: nil)

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
        let isSearch = snapshot.descriptor.role == .embedding
        enabled.title = isSearch ? "Поиск по смыслу" : "Спросить Buffera"
        enabled.font = .systemFont(ofSize: 13, weight: .semibold)
        enabled.target = self
        enabled.action = #selector(changeEnabled)
        enabled.identifier = NSUserInterfaceItemIdentifier("\(prefix).enabled")
        let description = modelParagraph(isSearch
            ? "Находите записи, даже если не помните точные слова. Для поиска по смыслу используется отдельная модель на вашем Mac."
            : "Локальная языковая модель (LLM) ищет в истории буфера обмена, читает найденные записи и отвечает на ваши вопросы.")
        let energyNote = modelParagraph(isSearch
            ? "Подготовка истории расходует заряд. Поиск по уже подготовленным записям доступен и от аккумулятора."
            : "Локальные ответы расходуют заряд и могут нагревать Mac. Обработка начинается после вашего вопроса.")
        energyNote.identifier = NSUserInterfaceItemIdentifier("\(prefix).energyNote")
        onlyOnExternalPower.font = .systemFont(ofSize: 11)
        onlyOnExternalPower.cell?.wraps = true
        onlyOnExternalPower.cell?.lineBreakMode = .byWordWrapping
        onlyOnExternalPower.state = .on
        onlyOnExternalPower.target = self
        onlyOnExternalPower.action = #selector(changeExternalPowerPreference)
        onlyOnExternalPower.identifier = NSUserInterfaceItemIdentifier("\(prefix).onlyOnExternalPower")
        onlyOnExternalPower.isHidden = !isSearch
        onlyOnExternalPower.toolTip = "Влияет на фоновую подготовку истории. Поиск и ответы по вашему запросу доступны при любом питании."

        modelName.font = .systemFont(ofSize: 11)
        modelName.identifier = NSUserInterfaceItemIdentifier("\(prefix).name")
        status.identifier = NSUserInterfaceItemIdentifier("\(prefix).status")
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.identifier = NSUserInterfaceItemIdentifier("\(prefix).progress")
        progress.setAccessibilityLabel("Скачивание модели \(snapshot.descriptor.title)")
        configure(primary, action: #selector(primaryAction), identifier: "\(prefix).download")
        configure(remove, action: #selector(removeModel), identifier: "\(prefix).remove")
        remove.title = "Удалить модель"
        remove.toolTip = "Выключить функцию и удалить скачанную модель с этого Mac"
        configure(check, action: #selector(checkModel), identifier: "\(prefix).check")
        check.toolTip = "Проверить русский и английский текст и код на встроенных примерах"
        let license = NSButton(title: "Лицензия", target: self, action: #selector(showLicense))
        license.bezelStyle = .inline
        license.font = .systemFont(ofSize: 11)
        license.identifier = NSUserInterfaceItemIdentifier("\(prefix).license")
        disclosure.bezelStyle = .inline
        disclosure.font = .systemFont(ofSize: 11)
        disclosure.target = self
        disclosure.action = #selector(toggleDetails)
        disclosure.identifier = NSUserInterfaceItemIdentifier("\(prefix).details")
        let actions = NSStackView(views: [primary, remove, disclosure])
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
        configure(continuePreparation, action: #selector(continueIndexPreparation),
                  identifier: "\(prefix).continuePreparation")
        continuePreparation.title = "Продолжить сейчас"
        continuePreparation.toolTip = "Продолжить на аккумуляторе до следующего подключения к сети или перезапуска Buffera"
        continuePreparation.isHidden = true

        let technicalActions = NSStackView(views: [check, license])
        technicalActions.orientation = .horizontal
        technicalActions.spacing = 8
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 8
        for view in [technicalActions, checkStatus] { details.addArrangedSubview(view) }
        details.isHidden = true
        let stack = NSStackView(views: [enabled, description, modelName, energyNote, status, progress,
                                      onlyOnExternalPower, indexStatus, indexProgress, continuePreparation,
                                      retryIndex, actions, details])
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
        for view in [description, modelName, energyNote, status, progress, onlyOnExternalPower,
                     indexStatus, indexProgress, details] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        checkStatus.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
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
        modelName.stringValue = "Модель: \(snapshot.descriptor.title) · \(total)"
        modelName.toolTip = snapshot.descriptor.summary
        enabled.state = snapshot.isEnabled ? .on : .off
        // A missing model requires an explicit download action with its size in view.
        // During preparation the requested-on switch remains available to stop it.
        enabled.isEnabled = platformSupported && (snapshot.state == .downloaded || snapshot.isEnabled)
        enabled.toolTip = snapshot.isEnabled
            ? "Выключение остановит обработку и сохранит скачанную модель"
            : snapshot.state == .downloaded
                ? "Включить функцию с уже скачанной моделью"
                : "Для включения сначала скачайте указанную модель"
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
            status.stringValue = "Модель ещё не скачана"
            primary.title = "Скачать модель и включить"
        case .downloading:
            status.stringValue = "Скачивание модели · \(received) из \(total). После проверки функция включится."
            primary.title = "Пауза"
        case .paused:
            status.stringValue = snapshot.isEnabled
                ? "Скачивание на паузе · \(received) из \(total)"
                : "Выключено · сохранено \(received) из \(total)"
            primary.title = snapshot.isEnabled ? "Продолжить" : "Включить и продолжить"
        case .verifying:
            status.stringValue = "Проверяем скачанную модель"
            primary.title = "Проверка файлов…"
            primary.isEnabled = false
        case .downloaded:
            status.stringValue = snapshot.isEnabled
                ? "Модель скачана · функция включена"
                : "Модель скачана · функция выключена"
        case .failed:
            status.stringValue = snapshot.errorMessage ?? "Не удалось подготовить функцию"
            status.textColor = .systemRed
            primary.title = snapshot.isEnabled ? "Повторить" : "Включить и повторить"
        }
        if let error = snapshot.errorMessage, snapshot.state != .failed {
            status.stringValue += "\n\(error)"
            status.textColor = .systemRed
        }
        updateIndexVisibility()
        onlyOnExternalPower.isEnabled = platformSupported
        updateCheckButton()
    }

    func updateCheck(status: String, running: Bool) {
        guard snapshot.state == .downloaded else { return }
        isChecking = running
        checkStatus.stringValue = status
        checkStatus.isHidden = status.isEmpty
        updateCheckButton()
    }

    func updateIndex(status: String, progress: Double?, canRetry: Bool, canContinueNow: Bool) {
        guard snapshot.descriptor.role == .embedding else { return }
        indexStatus.stringValue = status
        indexHasProgress = progress != nil
        indexCanRetry = canRetry
        indexCanContinueNow = canContinueNow
        if let progress { indexProgress.doubleValue = max(0, min(1, progress)) }
        updateIndexVisibility()
    }

    func updateBackgroundPreparation(onlyOnExternalPower value: Bool) {
        onlyOnExternalPower.state = value ? .on : .off
    }

    private func updateIndexVisibility() {
        indexStatus.isHidden = indexStatus.stringValue.isEmpty || !snapshot.isReadyForUse
        indexProgress.isHidden = !indexHasProgress || !snapshot.isReadyForUse
        retryIndex.isHidden = !indexCanRetry || !snapshot.isReadyForUse
        retryIndex.isEnabled = snapshot.isReadyForUse && platformSupported
        continuePreparation.isHidden = !indexCanContinueNow || !snapshot.isReadyForUse
        continuePreparation.isEnabled = snapshot.isReadyForUse && platformSupported
    }

    private func updateCheckButton() {
        check.isHidden = snapshot.state != .downloaded && !isChecking
        check.title = isChecking ? "Остановить проверку" : "Проверить работу"
        check.isEnabled = platformSupported && (isChecking || snapshot.state == .downloaded)
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
    @objc private func toggleDetails() {
        details.isHidden.toggle()
        disclosure.title = details.isHidden ? "Подробнее" : "Скрыть подробности"
    }
    @objc private func removeModel() { onRemove?() }
    @objc private func retryIndexing() { onRetryIndex?() }
    @objc private func continueIndexPreparation() { onContinuePreparation?() }
    @objc private func changeExternalPowerPreference() {
        onOnlyPrepareOnExternalPowerChanged?(onlyOnExternalPower.state == .on)
    }
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
