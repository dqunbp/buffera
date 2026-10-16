import AppKit
import Carbon
import os

final class HotKeys {
    private var nextRef: EventHotKeyRef?
    private var previousRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x42554652
    private let logger = Logger(subsystem: "local.bufera.app", category: "hotkeys")
    var isRegistered: Bool { nextRef != nil }
    var onPress: ((Int) -> Void)?

    func register() throws {
        guard nextRef == nil else { return }
        if handler == nil { try installHandler() }
        try add(key: UInt32(kVK_ANSI_V), id: 1, ref: &nextRef)
    }

    private func installHandler() throws {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            guard id.signature == HotKeys.signature, id.id == 1 || id.id == 2 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            owner.logger.notice("Global shortcut received: id=\(id.id)")
            owner.onPress?(id.id == 1 ? 1 : -1)
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyError(status: status) }
    }

    func setPreviousEnabled(_ enabled: Bool) throws {
        if enabled && previousRef == nil { try add(key: UInt32(kVK_ANSI_C), id: 2, ref: &previousRef) }
        if !enabled, let previousRef { UnregisterEventHotKey(previousRef); self.previousRef = nil }
    }

    private func add(key: UInt32, id: UInt32, ref: inout EventHotKeyRef?) throws {
        let status = RegisterEventHotKey(key, UInt32(cmdKey | optionKey), EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        logger.notice("Shortcut registration: id=\(id), status=\(status)")
        guard status == noErr else { throw HotKeyError(status: status) }
    }

    deinit {
        if let nextRef { UnregisterEventHotKey(nextRef) }
        if let previousRef { UnregisterEventHotKey(previousRef) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct HotKeyError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Не удалось включить горячую клавишу (\(status)). Закройте Pasta или другой менеджер с этим сочетанием и перезапустите Bufera. История доступна через значок в строке меню." }
}
