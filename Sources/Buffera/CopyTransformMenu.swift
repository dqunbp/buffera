import BufferaLocalization
import AppKit

/// Both the card submenu and its shortcut popup use this list and dispatch path.
/// Results can arrive while AppKit is tracking the menu, so callers replace its
/// items in place rather than presenting another menu or a second window.
final class CopyTransformMenu: NSMenu {
    private var operations: [CopyTransformOperation]?
    private let onChoose: (CopyTransformOperation) -> Void
    private var actionsEnabled = true

    init(operations: [CopyTransformOperation]?, onChoose: @escaping (CopyTransformOperation) -> Void) {
        self.operations = operations
        self.onChoose = onChoose
        super.init(title: L10n.text("Скопировать иначе"))
        autoenablesItems = false
        rebuild()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setOperations(_ operations: [CopyTransformOperation]?) {
        self.operations = operations
        rebuild()
    }

    func setActionsEnabled(_ enabled: Bool) {
        actionsEnabled = enabled
        for item in items where item.representedObject is CopyTransformOperation {
            item.isEnabled = enabled
        }
    }

    private func rebuild() {
        guard let operations, !operations.isEmpty else {
            let item = NSMenuItem(title: operations == nil ? L10n.text("Проверяем варианты…") : L10n.text("Нет подходящих вариантов"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            items = [item]
            return
        }
        items = operations.map { operation in
            let item = NSMenuItem(title: operation.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = operation
            item.isEnabled = actionsEnabled
            return item
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard actionsEnabled, sender.menu === self,
              let operation = sender.representedObject as? CopyTransformOperation,
              operations?.contains(operation) == true else { return }
        onChoose(operation)
    }
}
