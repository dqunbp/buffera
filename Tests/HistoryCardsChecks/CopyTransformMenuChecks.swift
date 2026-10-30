import AppKit
import BufferaLocalization

func copyTransformNamingMenuChecks() {
    let suite = "Buffera.CopyTransformNamingMenuChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var chosen: [CopyTransformOperation] = []

    func makeMenu(_ operations: [CopyTransformOperation]?) -> CopyTransformMenu {
        CopyTransformMenu(operations: operations, defaults: defaults) { chosen.append($0) }
    }
    func namingItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { item in
            item.submenu?.items.contains { $0.representedObject is TextFileNaming } == true
        }
    }
    func choices(in menu: NSMenu) -> NSMenu {
        guard let submenu = namingItem(in: menu)?.submenu else { fatalError("Missing file naming submenu") }
        return submenu
    }
    func item(_ mode: TextFileNaming, in submenu: NSMenu) -> NSMenuItem {
        guard let item = submenu.items.first(where: { ($0.representedObject as? TextFileNaming) == mode }) else {
            fatalError("Missing file naming choice: \(mode)")
        }
        return item
    }
    func send(_ item: NSMenuItem) {
        guard let action = item.action else { fatalError("Missing native menu action") }
        check(NSApp.sendAction(action, to: item.target, from: item), "file naming native action remains connected")
    }
    func checkSelection(_ submenu: NSMenu, _ selected: TextFileNaming) {
        check(submenu.items.compactMap { $0.representedObject as? TextFileNaming } == TextFileNaming.allCases,
              "file naming menu offers both stable preference values")
        check(submenu.items.map(\.title) == TextFileNaming.allCases.map(\.title),
              "file naming menu uses the translated names shared with export preferences")
        for mode in TextFileNaming.allCases {
            check(item(mode, in: submenu).state == (mode == selected ? .on : .off),
                  "file naming menu marks only the saved preference")
        }
    }

    let menu = makeMenu([.text(.plainText), .textFile(.txt), .textFile(.md)])
    check(namingItem(in: menu)?.title == L10n.text("Имя текстового файла"),
          "file naming is described beside the text export commands")
    checkSelection(choices(in: menu), .firstLine)
    check(defaults.object(forKey: "textFileNaming") == nil,
          "opening the file naming menu does not write a default preference")

    // A preference written by the former settings control must be preserved.
    defaults.set("dateTime", forKey: "textFileNaming")
    let existing = makeMenu([.textFile(.txt)])
    checkSelection(choices(in: existing), .dateTime)
    check(defaults.string(forKey: "textFileNaming") == "dateTime",
          "opening the moved setting preserves the previous key and value")
    send(item(.firstLine, in: choices(in: existing)))
    check(TextFileNaming.load(from: defaults) == .firstLine && chosen.isEmpty,
          "changing the filename preference saves immediately without copying")
    checkSelection(choices(in: existing), .firstLine)
    checkSelection(choices(in: makeMenu([.textFile(.md)])), .firstLine)

    for operations: [CopyTransformOperation]? in [nil, [], [.imageText], [.text(.plainText)]] {
        existing.setOperations(operations)
        check(namingItem(in: existing) == nil,
              "pending, empty, image and inline-text operations do not offer file naming")
    }
    for format in CopyTransformOperation.TextFileFormat.allCases {
        existing.setOperations([.textFile(format)])
        checkSelection(choices(in: existing), .firstLine)
        check(existing.items.compactMap { $0.representedObject as? CopyTransformOperation } == [.textFile(format)],
              "filename choices do not alter either available export format")
    }

    let staleSubmenu = choices(in: existing)
    let staleDate = item(.dateTime, in: staleSubmenu)
    existing.setOperations([.textFile(.txt), .textFile(.md)])
    withExtendedLifetime(staleSubmenu) { send(staleDate) }
    check(TextFileNaming.load(from: defaults) == .firstLine && chosen.isEmpty,
          "a retained choice in a replaced submenu cannot change the filename preference")

    existing.setActionsEnabled(false)
    check(namingItem(in: existing)?.isEnabled == false && choices(in: existing).items.allSatisfy { !$0.isEnabled },
          "disabling card actions also disables the filename submenu and its choices")
    send(item(.dateTime, in: choices(in: existing)))
    check(TextFileNaming.load(from: defaults) == .firstLine && chosen.isEmpty,
          "direct dispatch of a disabled filename choice cannot save or copy")
    existing.setOperations([.textFile(.md)])
    check(namingItem(in: existing)?.isEnabled == false && choices(in: existing).items.allSatisfy { !$0.isEnabled },
          "late availability keeps the rebuilt filename submenu disabled")
    send(item(.dateTime, in: choices(in: existing)))
    check(TextFileNaming.load(from: defaults) == .firstLine && chosen.isEmpty,
          "a rebuilt disabled filename choice still rejects direct dispatch")
    existing.setActionsEnabled(true)
    check(namingItem(in: existing)?.isEnabled == true && choices(in: existing).items.allSatisfy(\.isEnabled),
          "reenabling card actions restores filename choices")
    send(item(.dateTime, in: choices(in: existing)))
    check(TextFileNaming.load(from: defaults) == .dateTime && chosen.isEmpty,
          "reenabled filename choices persist without dispatching an export")
    checkSelection(choices(in: existing), .dateTime)
    checkSelection(choices(in: makeMenu([.textFile(.txt), .textFile(.md)])), .dateTime)

    let removedSubmenu = choices(in: existing)
    let removedFirstLine = item(.firstLine, in: removedSubmenu)
    existing.setOperations([.imageText])
    withExtendedLifetime(removedSubmenu) { send(removedFirstLine) }
    check(TextFileNaming.load(from: defaults) == .dateTime && chosen.isEmpty,
          "removing file exports invalidates choices retained from their submenu")

    existing.setOperations([.textFile(.txt), .textFile(.md)])
    for format in CopyTransformOperation.TextFileFormat.allCases {
        let operation = CopyTransformOperation.textFile(format)
        let export = existing.items.first { ($0.representedObject as? CopyTransformOperation) == operation }!
        send(export)
    }
    check(chosen == [.textFile(.txt), .textFile(.md)] && TextFileNaming.load(from: defaults) == .dateTime,
          "both text export commands retain direct dispatch and the saved naming preference")
}
