import AppKit

/// A single shortcut tap keeps history open. Cycling within the same modifier
/// hold confirms the selection when that hold ends.
struct HistoryShortcutGesture {
    var requiredModifiers: NSEvent.ModifierFlags = [.command, .option]

    private(set) var isActive = false
    private var pressCount = 0

    mutating func press(isRepeat: Bool = false) {
        guard !isRepeat else { return }
        pressCount = min(2, pressCount + 1)
        isActive = true
    }

    /// Returns true once when a cycling gesture releases either required key.
    mutating func modifiersChanged(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard !flags.contains(requiredModifiers) else { return false }
        let shouldConfirm = pressCount >= 2
        cancel()
        return shouldConfirm
    }

    mutating func cancel() {
        pressCount = 0
        isActive = false
    }
}
