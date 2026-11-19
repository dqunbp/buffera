import BufferaLocalization
import AppKit
import Carbon
import os

/// Register replacements before releasing old keys, including when letters swap.
final class HotKeys {
    struct Binding: Hashable {
        let key: UInt16
        let modifiers: UInt32
    }
    struct Registration {
        let id: UInt32
        let release: () -> Void
    }
    typealias Register = (Binding, UInt32) throws -> (() -> Void)
    private var registrations: [Binding: Registration] = [:]
    private var handler: EventHandlerRef?
    private var pressedIDs: Set<UInt32> = []
    private var nextID: UInt32 = 0
    private var previousEnabled = false
    private let customRegister: Register?
    private static let signature: OSType = 0x42554652
    private let logger = Logger(subsystem: "local.buffera.app", category: "hotkeys")
    private(set) var preferences: ShortcutPreferences
    var isRegistered: Bool { registrations[binding(preferences, previous: false)] != nil }
    var onPause: (() -> Void)?
    var onSkipNext: (() -> Void)?
    var onPress: ((Int, Bool) -> Void)?

    init(preferences: ShortcutPreferences = .load(), register: Register? = nil) {
        self.preferences = (try? preferences.validate()) != nil ? preferences : .defaults
        customRegister = register
    }

    private func binding(_ value: ShortcutPreferences, previous: Bool) -> Binding {
        Binding(key: previous ? value.previousKeyCode : value.nextKeyCode, modifiers: value.base.carbonModifiers)
    }

    private func captureBindings(_ value: ShortcutPreferences) -> [Binding] {
        [value.pause, value.skipNext].compactMap { $0 }.map {
            Binding(key: ShortcutPreferences.keyCode($0), modifiers: value.base.carbonModifiers)
        }
    }

    func register() throws {
        try ensure([binding(preferences, previous: false)] + captureBindings(preferences))
    }

    func apply(_ value: ShortcutPreferences) throws {
        try value.validate()
        // Validate both directions even when history is closed. On failure ensure
        // releases only newly acquired keys and leaves the active pair untouched.
        try ensure([binding(value, previous: false), binding(value, previous: true)] + captureBindings(value))
        preferences = value
        resetNavigationPressedKeys()
        releaseUnused()
    }

    func setPreviousEnabled(_ enabled: Bool) throws {
        if enabled { try ensure([binding(preferences, previous: true)]) }
        previousEnabled = enabled
        releaseUnused()
    }

    private func ensure(_ bindings: [Binding]) throws {
        if handler == nil && customRegister == nil { try installHandler() }
        var acquired: [Binding] = []
        do {
            for binding in bindings where registrations[binding] == nil {
                nextID += 1
                let release: () -> Void
                if let customRegister { release = try customRegister(binding, nextID) }
                else {
                    var ref: EventHotKeyRef?
                    let status = RegisterEventHotKey(UInt32(binding.key), binding.modifiers,
                        EventHotKeyID(signature: Self.signature, id: nextID), GetEventDispatcherTarget(),
                        OptionBits(kEventHotKeyExclusive), &ref)
                    logger.notice("Shortcut registration: status=\(status)")
                    guard status == noErr, let ref else { throw HotKeyError(status: status) }
                    release = { UnregisterEventHotKey(ref) }
                }
                registrations[binding] = Registration(id: nextID, release: release)
                acquired.append(binding)
            }
        } catch {
            for binding in acquired { registrations.removeValue(forKey: binding)?.release() }
            throw error
        }
    }

    private func releaseUnused() {
        var keep: Set<Binding> = previousEnabled
            ? [binding(preferences, previous: false), binding(preferences, previous: true)]
            : [binding(preferences, previous: false)]
        keep.formUnion(captureBindings(preferences))
        for key in Array(registrations.keys) where !keep.contains(key) {
            if let registration = registrations.removeValue(forKey: key) {
                pressedIDs.remove(registration.id)
                registration.release()
            }
        }
    }

    private func installHandler() throws {
        let specifications = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            guard id.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            owner.receive(id: id.id, released: GetEventKind(event) == UInt32(kEventHotKeyReleased))
            return noErr
        }, specifications.count, specifications, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyError(status: status) }
    }

    func receive(id: UInt32, released: Bool) {
        guard let entry = registrations.first(where: { $0.value.id == id }) else { return }
        if released { pressedIDs.remove(id); return }
        let isRepeat = !pressedIDs.insert(id).inserted
        if let letter = preferences.pause, entry.key.key == ShortcutPreferences.keyCode(letter) {
            if !isRepeat { onPause?() }
            return
        }
        if let letter = preferences.skipNext, entry.key.key == ShortcutPreferences.keyCode(letter) {
            if !isRepeat { onSkipNext?() }
            return
        }
        onPress?(entry.key == binding(preferences, previous: false) ? 1 : -1, isRepeat)
    }

    /// History dismissal/gesture resets must not release held recording commands.
    func resetNavigationPressedKeys() {
        for previous in [false, true] {
            if let registration = registrations[binding(preferences, previous: previous)] {
                pressedIDs.remove(registration.id)
            }
        }
    }

    deinit {
        for registration in registrations.values { registration.release() }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct HotKeyError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        L10n.text("Не удалось зарегистрировать сочетание (\(status)). Возможно, оно занято другой программой или системой. Выберите другую базу или буквы. История доступна через значок в строке меню.")
    }
}
