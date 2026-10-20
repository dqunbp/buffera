import BufferaLocalization
import AppKit
import BufferaCore

/// Agent access is opt-in; copying connection settings never grants permission.
final class MCPSettingsView: NSView {
    var onCopyConfiguration: ((String) throws -> Void)?

    private let access: MCPAccess
    private let executableURL: URL
    private let enabled = NSButton(checkboxWithTitle: L10n.text("Разрешить агентам читать историю"), target: nil, action: nil)
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
        let command = paragraph(executableURL.path)
        command.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        command.isSelectable = true
        command.setAccessibilityLabel(L10n.text("Исполняемый файл MCP"))
        let claude = copyButton(L10n.text("Команда для Claude Code"), action: #selector(copyClaudeCommand),
                                identifier: "mcp.copyClaudeCommand")
        claude.toolTip = L10n.text("Скопировать команду подключения Claude Code для всех проектов этого пользователя")
        let codex = copyButton(L10n.text("Команда для Codex"), action: #selector(copyCodexCommand),
                               identifier: "mcp.copyCodexCommand")
        codex.toolTip = L10n.text("Скопировать команду подключения Codex")
        let commands = NSStackView(views: [claude, codex])
        commands.orientation = .horizontal
        commands.alignment = .centerY
        commands.spacing = 10
        let copy = copyButton(L10n.text("Скопировать конфигурацию"), action: #selector(copyConfiguration),
                              identifier: "mcp.copyConfiguration")
        status.font = .systemFont(ofSize: 11)
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        status.identifier = NSUserInterfaceItemIdentifier("mcp.status")

        let stack = NSStackView(views: [enabled, disclosure, connection, command, commands, copy, status])
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
        for field in [disclosure, connection, command, status] {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        enabled.state = access.isEnabled() ? .on : .off
        showStatus(enabled.state == .on ? L10n.text("Доступ включён. Скрытые записи показаны масками; раскрытие — через reveal_clip.")
                   : L10n.text("Доступ выключен. Конфигурацию можно подготовить заранее."))
    }

    @objc private func changeAccess() {
        do {
            try access.setEnabled(enabled.state == .on)
            refresh()
        } catch {
            enabled.state = access.isEnabled() ? .on : .off
            showStatus(L10n.text("Не удалось сохранить доступ: \(error.localizedDescription)"), isError: true)
        }
    }

    @objc private func copyConfiguration() {
        copyConnection({ try MCPAccess.configuration(executableURL: executableURL) },
                       confirmation: L10n.text("Конфигурация скопирована. Добавьте её в настройки агента."))
    }

    @objc private func copyClaudeCommand() { copyCommand(for: .claudeCode) }
    @objc private func copyCodexCommand() { copyCommand(for: .codex) }

    private func copyCommand(for client: MCPClient) {
        copyConnection({ MCPAccess.addCommand(for: client, executableURL: executableURL) },
                       confirmation: L10n.text("Команда скопирована. Выполните её в Терминале."))
    }

    private func copyConnection(_ value: () throws -> String, confirmation: String) {
        do {
            guard let onCopyConfiguration else { throw MCPSettingsError.copyUnavailable }
            try onCopyConfiguration(value())
            showStatus(confirmation + (access.isEnabled() ? ""
                       : L10n.text(" Чтобы агент мог читать историю, включите доступ.")))
        } catch {
            showStatus(L10n.text("Не удалось скопировать: \(error.localizedDescription)"), isError: true)
        }
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
