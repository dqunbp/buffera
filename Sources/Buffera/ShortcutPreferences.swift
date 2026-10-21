import AppKit
import Carbon
import BufferaLocalization

/// The same physical letters are used in every keyboard layout.
struct ShortcutPreferences: Equatable, Codable {
    enum Base: String, CaseIterable, Codable {
        case commandOption, controlOption, controlShift, commandShift, controlCommandOption

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .commandOption: return [.command, .option]
            case .controlOption: return [.control, .option]
            case .controlShift: return [.control, .shift]
            case .commandShift: return [.command, .shift]
            case .controlCommandOption: return [.control, .command, .option]
            }
        }
        var carbonModifiers: UInt32 {
            var result = 0
            for (flag, value): (NSEvent.ModifierFlags, Int) in [(.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)] {
                if modifiers.contains(flag) { result |= value }
            }
            return UInt32(result)
        }
        var title: String {
            switch self {
            case .commandOption: return "⌘⌥"
            case .controlOption: return "⌃⌥"
            case .controlShift: return "⌃⇧"
            case .commandShift: return "⌘⇧"
            case .controlCommandOption: return "⌃⌘⌥"
            }
        }
    }

    static let preferenceKey = "keyboard.shortcuts"
    static let defaults = ShortcutPreferences(base: .commandOption, next: "V", previous: "C")
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    private static let keyCodes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    let base: Base
    let next: String
    let previous: String
    var nextTitle: String { base.title + next }
    var previousTitle: String { base.title + previous }
    var nextKeyCode: UInt16 { Self.keyCodes[Self.letters.firstIndex(of: next)!] }
    var previousKeyCode: UInt16 { Self.keyCodes[Self.letters.firstIndex(of: previous)!] }

    func validate() throws {
        guard Self.letters.contains(next), Self.letters.contains(previous) else { throw ShortcutPreferenceError.invalidLetter }
        guard next != previous else { throw ShortcutPreferenceError.sameLetter }
        // These exact combinations belong to existing Buffera/menu commands.
        let reserved: Set<String> = base == .commandOption ? ["S"] : base == .commandShift ? ["C", "H", "R", "S", "N", "Z"] : []
        if let letter = [next, previous].first(where: { reserved.contains($0) }) {
            throw ShortcutPreferenceError.reserved(base.title + letter)
        }
    }

    func direction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.intersection([.command, .option, .control, .shift]) == base.modifiers else { return nil }
        if keyCode == nextKeyCode { return 1 }
        if keyCode == previousKeyCode { return -1 }
        return nil
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preferenceKey), let value = try? JSONDecoder().decode(Self.self, from: data),
              (try? value.validate()) != nil else { return .defaults }
        return value
    }

    func save(to defaults: UserDefaults = .standard) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
    }

    var usageHint: String {
        L10n.text("Одно \(nextTitle) с отпусканием оставляет окно открытым. Для быстрого выбора удерживайте \(base.title) с самого открытия, нажмите \(next) или \(previous) ещё раз и отпустите. Enter — выбрать, пробел — просмотр (из поиска — ⌘Y). Вставка — ⌘V в нужном приложении.")
    }
}

enum ShortcutPreferenceError: LocalizedError {
    case invalidLetter, sameLetter, reserved(String), unavailable
    var errorDescription: String? {
        switch self {
        case .invalidLetter: return L10n.text("Выберите буквы от A до Z.")
        case .sameLetter: return L10n.text("Для следующей и предыдущей записи нужны разные буквы.")
        case .reserved(let shortcut): return L10n.text("\(shortcut) уже используется другой командой Buffera. Выберите другую букву или базу.")
        case .unavailable: return L10n.text("Не удалось применить сочетания. Попробуйте открыть настройки снова.")
        }
    }
}
