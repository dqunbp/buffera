import AppKit
import Carbon
import os

final class HotKeys {
    private var nextRef: EventHotKeyRef?
    private var previousRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressedIDs: Set<UInt32> = []
    private static let signature: OSType = 0x42554652
    private let logger = Logger(subsystem: "local.buffera.app", category: "hotkeys")
    var isRegistered: Bool { nextRef != nil }
    var onPress: ((Int, Bool) -> Void)?

    func register() throws {
        guard nextRef == nil else { return }
        if handler == nil { try installHandler() }
        try add(key: UInt32(kVK_ANSI_V), id: 1, ref: &nextRef)
    }

    private func installHandler() throws {
        var specifications = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            guard id.signature == HotKeys.signature, id.id == 1 || id.id == 2 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                owner.pressedIDs.remove(id.id)
                return noErr
            }
            let isRepeat = !owner.pressedIDs.insert(id.id).inserted
            owner.logger.notice("Global shortcut received: id=\(id.id)")
            owner.onPress?(id.id == 1 ? 1 : -1, isRepeat)
            return noErr
        }, specifications.count, &specifications, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyError(status: status) }
    }

    func setPreviousEnabled(_ enabled: Bool) throws {
        if enabled && previousRef == nil { try add(key: UInt32(kVK_ANSI_C), id: 2, ref: &previousRef) }
        if !enabled, let previousRef {
            UnregisterEventHotKey(previousRef); self.previousRef = nil; pressedIDs.remove(2)
        }
    }

    func resetPressedKeys() { pressedIDs.removeAll() }

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
    var errorDescription: String? { "Не удалось включить горячую клавишу (\(status)). Закройте Pasta или другой менеджер с этим сочетанием и перезапустите \(BrandIdentity.name). История доступна через значок в строке меню." }
}
