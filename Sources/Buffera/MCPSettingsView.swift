import BufferaLocalization
import AppKit
import BufferaCore

/// Agent access is opt-in; copying connection settings never grants permission.
final class MCPSettingsView: NSView {
    var onCopyConfiguration: ((String) throws -> Void)?

    // The wizard stages permission in its draft; settings keep immediate persistence.
    var readEnabled: (() -> Bool)?
    var writeEnabled: ((Bool) throws -> Void)?
    private var isEnabled: Bool { readEnabled?() ?? access.isEnabled() }

    private let access: MCPAccess
    private let executableURL: URL
    private let enabled = NSButton(checkboxWithTitle: L10n.text("Разрешить агентам читать историю"), target: nil, action: nil)
    private var confirmations: [String: NSTextField] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")

    init(access: MCPAccess = MCPAccess(), bundleURL: URL = Bundle.main.bundleURL) {
        self.access = access
        executableURL = bundleURL.appendingPathComponent("Contents/MacOS/BufferaMCP")
        super.init(frame: .zero)

        enabled.target = self
        enabled.action = #selector(changeAccess)
        enabled.font = .systemFont(ofSize: 12)
        enabled.identifier = NSUserInterfaceItemIdentifier("mcp.enabled")
        let disclosure = paragraph(L10n.text("Агент сможет читать историю и отдельно раскрывать скрытые записи. Инструкция просит его получить ваше согласие, если оно ещё не дано. Прочитанное попадёт в контекст агента."))
        let connection = paragraph(L10n.text("Скопируйте команду для своего агента и выполните её в Терминале. Агент сам запускает локальный файл через stdio. Для ручного подключения доступна конфигурация JSON."))
        let claude = connectionBlock("Claude Code", value: MCPAccess.addCommand(for: .claudeCode, executableURL: executableURL),
                                     action: #selector(copyClaudeCommand), identifier: "mcp.copyClaudeCommand")
        let codex = connectionBlock("Codex", value: MCPAccess.addCommand(for: .codex, executableURL: executableURL),
                                    action: #selector(copyCodexCommand), identifier: "mcp.copyCodexCommand")
        let json = connectionBlock("JSON", value: (try? MCPAccess.configuration(executableURL: executableURL)) ?? "",
                                   action: #selector(copyConfiguration), identifier: "mcp.copyConfiguration")
        status.font = .systemFont(ofSize: 11)
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        status.identifier = NSUserInterfaceItemIdentifier("mcp.status")

        let stack = NSStackView(views: [enabled, disclosure, connection, claude, codex, json, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for field in [disclosure, connection, claude, codex, json, status] {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        enabled.state = isEnabled ? .on : .off
        if writeEnabled != nil {
            showStatus(enabled.state == .on ? L10n.text("Доступ будет включён после завершения настройки.")
                       : L10n.text("Доступ будет выключен после завершения настройки."))
            return
        }
        showStatus(enabled.state == .on ? L10n.text("Доступ включён. Скрытые записи показаны масками; раскрытие — через reveal_clip.")
                   : L10n.text("Доступ выключен. Конфигурацию можно подготовить заранее."))
    }

    @objc private func changeAccess() {
        do {
            if let writeEnabled { try writeEnabled(enabled.state == .on) }
            else { try access.setEnabled(enabled.state == .on) }
            refresh()
        } catch {
            enabled.state = isEnabled ? .on : .off
            showStatus(L10n.text("Не удалось сохранить доступ: \(error.localizedDescription)"), isError: true)
        }
    }

    @objc private func copyConfiguration() {
        copyConnection({ try MCPAccess.configuration(executableURL: executableURL) },
                       identifier: "mcp.copyConfiguration", confirmation: L10n.text("JSON-конфигурация скопирована. Добавьте её в настройки агента."))
    }

    @objc private func copyClaudeCommand() { copyCommand(for: .claudeCode) }
    @objc private func copyCodexCommand() { copyCommand(for: .codex) }

    private func copyCommand(for client: MCPClient) {
        copyConnection({ MCPAccess.addCommand(for: client, executableURL: executableURL) },
                       identifier: client == .claudeCode ? "mcp.copyClaudeCommand" : "mcp.copyCodexCommand",
                       confirmation: client == .claudeCode
                        ? L10n.text("Команда для Claude Code скопирована. Выполните её в Терминале.")
                        : L10n.text("Команда для Codex скопирована. Выполните её в Терминале."))
    }

    private func copyConnection(_ value: () throws -> String, identifier: String, confirmation: String) {
        confirmations.values.forEach { $0.isHidden = true }
        do {
            guard let onCopyConfiguration else { throw MCPSettingsError.copyUnavailable }
            try onCopyConfiguration(value())
            confirmations[identifier]?.stringValue = confirmation
            confirmations[identifier]?.textColor = .secondaryLabelColor
            confirmations[identifier]?.isHidden = false
            showStatus(confirmation + (isEnabled ? ""
                       : L10n.text(" Чтобы агент мог читать историю, включите доступ.")))
        } catch {
            let message = L10n.text("Не удалось скопировать: \(error.localizedDescription)")
            confirmations[identifier]?.stringValue = message
            confirmations[identifier]?.textColor = .systemRed
            confirmations[identifier]?.isHidden = false
            showStatus(message, isError: true)
        }
    }

    private func connectionBlock(_ title: String, value: String, action: Selector, identifier: String) -> NSView {
        let code = paragraph(value)
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.isSelectable = true
        code.lineBreakMode = .byCharWrapping
        code.identifier = NSUserInterfaceItemIdentifier(identifier + ".value")
        let button = copyButton(L10n.text("Скопировать"), action: action, identifier: identifier)
        button.setAccessibilityLabel(L10n.text("Скопировать: \(title)"))
        let header = NSStackView(views: [SetupUI.text(title, bold: true), NSView(), button])
        let confirmation = paragraph("")
        confirmation.isHidden = true
        confirmations[identifier] = confirmation
        return SetupUI.card([header, confirmation, code])
    }

    private func copyButton(_ title: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }

    private func showStatus(_ message: String, isError: Bool = false) {
        status.stringValue = message
        status.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }
}

enum MCPSettingsError: LocalizedError {
    case copyUnavailable
    var errorDescription: String? { L10n.text("Копирование сейчас недоступно.") }
}
