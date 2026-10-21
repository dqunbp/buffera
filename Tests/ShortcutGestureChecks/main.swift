import AppKit

// Run from the repository root (no windows, clipboard, history or preferences):
// mkdir -p .build/shortcut-gesture-checks
// swiftc -module-cache-path .build/ModuleCache Sources/Buffera/HistoryShortcutGesture.swift Tests/ShortcutGestureChecks/main.swift -o .build/shortcut-gesture-checks/checks
// .build/shortcut-gesture-checks/checks

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
    checkCount += 1
    print("PASS", message)
}

let held = HistoryShortcutGesture().requiredModifiers
var gesture = HistoryShortcutGesture()
check(!gesture.isActive, "a new gesture is inactive")
check(!gesture.modifiersChanged([]), "releasing modifiers without a shortcut does not confirm")

gesture.press()
check(gesture.isActive, "the first shortcut starts a gesture")
check(!gesture.modifiersChanged(held) && gesture.isActive, "holding both modifiers keeps the first press active")
check(!gesture.modifiersChanged([]) && !gesture.isActive, "releasing a single shortcut leaves history open")
gesture.press()
check(!gesture.modifiersChanged([]) && !gesture.isActive, "a separate single tap does not accumulate with the previous tap")

gesture.press(isRepeat: true)
check(!gesture.isActive, "autorepeat alone cannot start a gesture")
gesture.press()
for _ in 0..<5 { gesture.press(isRepeat: true) }
check(!gesture.modifiersChanged([]), "holding V for autorepeat does not arm confirmation")
check(!gesture.isActive, "releasing after autorepeat ends the single-press gesture")

gesture.press()
gesture.press()
check(!gesture.modifiersChanged(held) && gesture.isActive, "two distinct presses wait for modifier release")
check(gesture.modifiersChanged([]) && !gesture.isActive, "two distinct presses confirm on release")
check(!gesture.modifiersChanged([]), "the same release cannot confirm twice")

gesture.press()
gesture.press()
gesture.press()
check(gesture.modifiersChanged([]), "three presses still confirm once on release")
check(!gesture.modifiersChanged([]), "a longer cycling gesture also confirms only once")

gesture.press()
gesture.press()
check(gesture.modifiersChanged([.option]), "releasing Command first confirms cycling")
check(!gesture.modifiersChanged([]), "the subsequent Option release does not confirm again")
gesture.press()
gesture.press()
check(gesture.modifiersChanged([.command]), "releasing Option first confirms cycling")
check(!gesture.modifiersChanged([]), "the subsequent Command release does not confirm again")

gesture.press()
check(!gesture.modifiersChanged(held.union([.shift, .capsLock])) && gesture.isActive,
      "adding unrelated modifiers does not end a single-press gesture")
gesture.press()
check(!gesture.modifiersChanged(held.union([.capsLock])) && gesture.isActive,
      "releasing Shift while Command and Option remain held does not confirm")
check(!gesture.modifiersChanged(held) && gesture.isActive,
      "changing Caps Lock while required modifiers remain held does not confirm")
check(gesture.modifiersChanged([.shift, .capsLock]),
      "unrelated modifiers do not prevent confirmation when required modifiers release")

gesture.press()
gesture.cancel()
check(!gesture.isActive && !gesture.modifiersChanged([]), "cancelled first press cannot confirm")
gesture.press()
gesture.press()
gesture.cancel()
check(!gesture.isActive && !gesture.modifiersChanged([]), "cancelled cycling cannot confirm")
gesture.press()
check(!gesture.modifiersChanged([]), "the next press after cancellation starts a fresh gesture")

gesture.press()
gesture.press()
gesture.press(isRepeat: true)
check(gesture.modifiersChanged([]), "autorepeat does not disarm two deliberate presses")

print("Passed \(checkCount) shortcut gesture checks")
