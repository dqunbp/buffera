import AppKit
import Carbon
import BufferaLocalization

struct ShortcutKey: Hashable, Codable {
    // Virtual key codes are independent of the current input language.
    private static let titles: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ISO_Section: "§",
        kVK_JIS_Yen: "¥", kVK_JIS_Underscore: "_"
    ]

    let code: UInt16
    var title: String { Self.titles[Int(code)]! }

    init?(code: UInt16) {
        guard Self.titles[Int(code)] != nil else { return nil }
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let code = try? container.decode(UInt16.self), let key = Self(code: code) {
            self = key
        } else if let letter = try? container.decode(String.self),
                  let code = Self.titles.first(where: { $0.value == letter })?.key {
            // Buffera previously stored the names of physical A–Z keys.
            self.code = UInt16(code)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported shortcut key")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

struct ShortcutPreferences: Equatable, Codable {
    enum Base: String, CaseIterable, Codable {
        case commandOption, controlOption, controlShift, commandShift, controlCommandOption, control

        init?(modifiers: NSEvent.ModifierFlags) {
            let flags = modifiers.intersection([.command, .option, .control, .shift])
            guard let value = Self.allCases.first(where: { $0.modifiers == flags }) else { return nil }
            self = value
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .commandOption: return [.command, .option]
            case .controlOption: return [.control, .option]
            case .controlShift: return [.control, .shift]
            case .commandShift: return [.command, .shift]
            case .controlCommandOption: return [.control, .command, .option]
            case .control: return .control
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
            case .control: return "⌃"
            }
        }
    }

    static let preferenceKey = "keyboard.shortcuts"
    static let defaults = ShortcutPreferences(base: .commandOption,
        next: ShortcutKey(code: UInt16(kVK_ANSI_V))!, previous: ShortcutKey(code: UInt16(kVK_ANSI_C))!)
    var base: Base
    var next: ShortcutKey
    var previous: ShortcutKey
    var pause: ShortcutKey? = nil
    var skipNext: ShortcutKey? = nil

    func title(for key: ShortcutKey) -> String { base.title + key.title }
    var nextTitle: String { title(for: next) }
    var previousTitle: String { title(for: previous) }

    func validate() throws {
        let assigned = [next, previous] + [pause, skipNext].compactMap { $0 }
        guard Set(assigned).count == assigned.count else { throw ShortcutPreferenceError.duplicate }
        // These exact combinations belong to existing Buffera/menu commands.
        let reserved: Set<Int>
        switch base {
        case .commandOption: reserved = [kVK_ANSI_S, kVK_ANSI_Comma]
        case .commandShift:
            reserved = [kVK_ANSI_C, kVK_ANSI_H, kVK_ANSI_N, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_Z, kVK_ANSI_Comma]
        case .controlCommandOption: reserved = [kVK_ANSI_Comma]
        default: reserved = []
        }
        if let key = assigned.first(where: { reserved.contains(Int($0.code)) }) {
            throw ShortcutPreferenceError.reserved(title(for: key))
        }
    }

    func direction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.intersection([.command, .option, .control, .shift]) == base.modifiers else { return nil }
        if keyCode == next.code { return 1 }
        if keyCode == previous.code { return -1 }
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
        L10n.text("Одно \(nextTitle) с отпусканием оставляет окно открытым. Для быстрого выбора удерживайте \(base.title) с самого открытия, нажмите \(next.title) или \(previous.title) ещё раз и отпустите. Enter — выбрать, пробел — просмотр (из поиска — ⌘Y). Вставка — ⌘V в нужном приложении.")
    }
}

enum ShortcutPreferenceError: LocalizedError {
    case duplicate, reserved(String), unavailable
    var errorDescription: String? {
        switch self {
        case .duplicate: return L10n.text("Для разных действий нужны разные сочетания.")
        case .reserved(let shortcut): return L10n.text("\(shortcut) уже используется другой командой Buffera. Выберите другое сочетание.")
        case .unavailable: return L10n.text("Не удалось применить сочетания. Попробуйте открыть настройки снова.")
        }
    }
}
