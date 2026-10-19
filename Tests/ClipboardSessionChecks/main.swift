import AppKit
import CoreGraphics

// Run from the repository root. Uses isolated notification centers and fake
// session snapshots; never locks the Mac or reads/writes the user's clipboard.
// mkdir -p .build/clipboard-session-checks
// swiftc -module-cache-path .build/ModuleCache Sources/Buffera/ClipboardSessionMonitor.swift Tests/ClipboardSessionChecks/main.swift -o .build/clipboard-session-checks/checks
// .build/clipboard-session-checks/checks

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checkCount += 1
    print("PASS", message)
}

let consoleKey = kCGSessionOnConsoleKey as String
let loginKey = kCGSessionLoginDoneKey as String
let lockKey = "CGSSessionScreenIsLocked"
let unlocked: [String: Any] = [consoleKey: true, loginKey: true]
var current: [String: Any]? = unlocked
let workspace = NotificationCenter()
let locks = NotificationCenter()
var transitions = 0
let monitor = ClipboardSessionMonitor(snapshot: { current }, workspaceNotifications: workspace,
                                      lockNotifications: locks)
monitor.onTransition = { transitions += 1 }
func post(_ name: Notification.Name, to center: NotificationCenter) {
    center.post(name: name, object: nil)
}

check(!monitor.allowsCapture, "capture is disabled before monitoring starts")
monitor.start()
check(monitor.allowsCapture, "normal unlocked snapshot permits capture without optional lock key")
check(transitions == 1, "start discards preexisting clipboard changes once")
monitor.start()
check(transitions == 1, "starting an already running monitor does not duplicate observers")
check(monitor.allowsCapture && transitions == 1, "unchanged polls do not discard fresh clipboard changes")

post(ClipboardSessionMonitor.screenLocked, to: locks)
check(!monitor.allowsCapture, "lock notification blocks even while session snapshot is still unlocked")
check(transitions == 2, "lock boundary discards changes immediately")
post(NSWorkspace.sessionDidBecomeActiveNotification, to: workspace)
check(!monitor.allowsCapture, "active session cannot override a screen lock")
post(NSWorkspace.didWakeNotification, to: workspace)
check(!monitor.allowsCapture, "wake cannot override a screen lock")
post(ClipboardSessionMonitor.screenUnlocked, to: locks)
check(monitor.allowsCapture, "matching unlock releases the lock boundary")
check(transitions == 5, "every boundary clears pending data even without intervening polls")

post(NSWorkspace.sessionDidResignActiveNotification, to: workspace)
check(!monitor.allowsCapture, "inactive user session blocks capture")
post(ClipboardSessionMonitor.screenUnlocked, to: locks)
check(!monitor.allowsCapture, "unlock cannot override an inactive session")
post(NSWorkspace.sessionDidBecomeActiveNotification, to: workspace)
check(monitor.allowsCapture, "session activation resumes capture when unlocked")

post(NSWorkspace.willSleepNotification, to: workspace)
check(!monitor.allowsCapture, "sleep blocks capture")
post(NSWorkspace.sessionDidBecomeActiveNotification, to: workspace)
post(ClipboardSessionMonitor.screenUnlocked, to: locks)
check(!monitor.allowsCapture, "unlock and activation cannot override sleep")
post(NSWorkspace.didWakeNotification, to: workspace)
check(monitor.allowsCapture, "wake resumes an active unlocked session")

let beforeFastLock = transitions
post(ClipboardSessionMonitor.screenLocked, to: locks)
post(ClipboardSessionMonitor.screenUnlocked, to: locks)
check(transitions == beforeFastLock + 2 && monitor.allowsCapture,
      "lock and unlock between polls both discard pending changes")
post(ClipboardSessionMonitor.screenUnlocked, to: locks)
check(transitions == beforeFastLock + 3, "duplicate boundary still discards pending changes")

current = [consoleKey: true, loginKey: true, lockKey: true]
let beforeSnapshotLock = transitions
check(!monitor.allowsCapture, "snapshot catches a lock even without its notification")
check(transitions == beforeSnapshotLock + 1, "snapshot detected lock discards pending changes")
post(ClipboardSessionMonitor.screenUnlocked, to: locks)
check(!monitor.allowsCapture, "unlock notification cannot override a still-locked snapshot")
current = unlocked
let beforeSnapshotRecovery = transitions
check(monitor.allowsCapture, "snapshot recovery resumes capture")
check(transitions == beforeSnapshotRecovery + 1, "snapshot recovery discards clipboard accumulated while blocked")

for (name, value): (String, [String: Any]?) in [
    ("unavailable", nil),
    ("empty", [:]),
    ("off console", [consoleKey: false, loginKey: true]),
    ("login incomplete", [consoleKey: true, loginKey: false]),
    ("missing console", [loginKey: true]),
    ("missing login", [consoleKey: true]),
    ("malformed console", [consoleKey: "true", loginKey: true]),
    ("malformed login", [consoleKey: true, loginKey: 1]),
    ("malformed lock", [consoleKey: true, loginKey: true, lockKey: "false"])
] {
    current = value
    check(!monitor.allowsCapture, "\(name) snapshot fails closed")
}
current = [consoleKey: true, loginKey: true, lockKey: false]
check(monitor.allowsCapture, "explicit unlocked boolean is accepted")

monitor.stop()
let afterStop = transitions
check(!monitor.allowsCapture, "stop disables capture")
post(ClipboardSessionMonitor.screenLocked, to: locks)
post(NSWorkspace.willSleepNotification, to: workspace)
check(transitions == afterStop, "stopped monitor has removed its notification observers")
monitor.stop()
check(transitions == afterStop, "stop is idempotent")

current = [consoleKey: true, loginKey: true, lockKey: true]
monitor.start()
check(!monitor.allowsCapture, "starting while already locked fails closed without a prior notification")
current = nil
monitor.stop()
monitor.start()
check(!monitor.allowsCapture, "starting without a GUI snapshot fails closed")
current = unlocked
check(monitor.allowsCapture, "valid session can recover after an unavailable initial snapshot")
monitor.stop()

var callbackAllowances: [Bool] = []
monitor.onTransition = { callbackAllowances.append(monitor.allowsCapture) }
monitor.start()
check(callbackAllowances == [true], "transition callback can read eligibility without recursion")
current = [consoleKey: true, loginKey: true, lockKey: true]
check(!monitor.allowsCapture && callbackAllowances == [true, false],
      "polled lock stores blocked state before the clipboard discard callback")
current = unlocked
check(monitor.allowsCapture && callbackAllowances == [true, false, true],
      "polled recovery stores allowed state before the clipboard discard callback")
monitor.stop()
check(callbackAllowances == [true, false, true, false], "stop callback safely observes disabled capture")
monitor.onTransition = nil

print("Passed \(checkCount) clipboard session checks")
