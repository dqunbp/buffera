import AppKit
import BufferaCore

/// Agent access is opt-in; copying connection settings never grants permission.
final class MCPSettingsView: NSView {
    var onCopyConfiguration: ((String) throws -> Void)?

    private let access: MCPAccess
    private let executableURL: URL
    private let enabled = NSButton(checkboxWithTitle: "Разрешить агентам читать историю", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")

    init(access: MCPAccess = MCPAccess(), bundleURL: URL = Bundle.main.bundleURL) {
        self.access = access
        executableURL = bundleURL.appendingPathComponent("Contents/MacOS/BufferaMCP")
        super.init(frame: .zero)

        enabled.target = self
        enabled.action = #selector(changeAccess)
        enabled.font = .systemFont(ofSize: 12)
        enabled.identifier = NSUserInterfaceItemIdentifier("mcp.enabled")
        let disclosure = paragraph("Агент сможет искать и читать нескрытые записи истории. Их содержимое попадёт в его контекст; дальнейшая обработка зависит от выбранного агента.")
        let connection = paragraph("Подключение работает через MCP и stdio: агент сам запускает локальный файл. Вставьте конфигурацию в настройки MCP вашего агента.")
        let command = paragraph(executableURL.path)
        command.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        command.isSelectable = true
        command.setAccessibilityLabel("Исполняемый файл MCP")
        let copy = NSButton(title: "Скопировать конфигурацию", target: self, action: #selector(copyConfiguration))
        copy.bezelStyle = .rounded
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.imagePosition = .imageLeading
        copy.identifier = NSUserInterfaceItemIdentifier("mcp.copyConfiguration")
        status.font = .systemFont(ofSize: 11)
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        status.identifier = NSUserInterfaceItemIdentifier("mcp.status")

        let stack = NSStackView(views: [enabled, disclosure, connection, command, copy, status])
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
        showStatus(enabled.state == .on ? "Доступ включён. Скрытые записи недоступны агентам."
                   : "Доступ выключен. Конфигурацию можно подготовить заранее.")
    }

    @objc private func changeAccess() {
        do {
            try access.setEnabled(enabled.state == .on)
            refresh()
        } catch {
            enabled.state = access.isEnabled() ? .on : .off
            showStatus("Не удалось сохранить доступ: \(error.localizedDescription)", isError: true)
        }
    }

    @objc private func copyConfiguration() {
        do {
            guard let onCopyConfiguration else { throw MCPSettingsError.copyUnavailable }
            try onCopyConfiguration(MCPAccess.configuration(executableURL: executableURL))
            showStatus(access.isEnabled() ? "Конфигурация скопирована. Добавьте её в настройки агента."
                       : "Конфигурация скопирована. Чтобы агент мог читать историю, включите доступ.")
        } catch {
            showStatus("Не удалось скопировать конфигурацию: \(error.localizedDescription)", isError: true)
        }
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
    var errorDescription: String? { "Копирование сейчас недоступно." }
}
