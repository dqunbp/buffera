import BufferaLocalization
import AppKit

/// Both the card submenu and its shortcut popup use this list and dispatch path.
/// Results can arrive while AppKit is tracking the menu, so callers replace its
/// items in place rather than presenting another menu or a second window.
final class CopyTransformMenu: NSMenu {
    private var operations: [CopyTransformOperation]?
    private let onChoose: (CopyTransformOperation) -> Void
    private let defaults: UserDefaults
    private var namingMenu: NSMenu?
    private var actionsEnabled = true

    init(operations: [CopyTransformOperation]?, defaults: UserDefaults = .standard,
         onChoose: @escaping (CopyTransformOperation) -> Void) {
        self.operations = operations
        self.defaults = defaults
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
        if let namingMenu {
            items.first { $0.submenu === namingMenu }?.isEnabled = enabled
            for item in namingMenu.items { item.isEnabled = enabled }
        }
    }

    private func rebuild() {
        namingMenu = nil
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
        let supportsTextFiles = operations.contains { operation in
            if case .textFile = operation { return true }
            return false
        }
        guard supportsTextFiles else { return }
        let title = L10n.text("Имя текстового файла")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        let selected = TextFileNaming.load(from: defaults)
        for mode in TextFileNaming.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changeNaming(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = mode == selected ? .on : .off
            item.isEnabled = actionsEnabled
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = actionsEnabled
        namingMenu = submenu
        addItem(.separator())
        addItem(item)
    }

    @objc private func changeNaming(_ sender: NSMenuItem) {
        guard actionsEnabled, sender.isEnabled, let namingMenu,
              namingMenu.supermenu === self, sender.menu === namingMenu,
              let mode = sender.representedObject as? TextFileNaming else { return }
        defaults.set(mode.rawValue, forKey: TextFileNaming.preferenceKey)
        for item in namingMenu.items {
            item.state = (item.representedObject as? TextFileNaming) == mode ? .on : .off
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard actionsEnabled, sender.menu === self,
              let operation = sender.representedObject as? CopyTransformOperation,
              operations?.contains(operation) == true else { return }
        onChoose(operation)
    }
}
