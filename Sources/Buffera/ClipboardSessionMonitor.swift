import AppKit
import CoreGraphics

/// Owns capture eligibility for this GUI session. All access is on the main thread.
final class ClipboardSessionMonitor {
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    var onTransition: (() -> Void)?

    private let snapshot: () -> [String: Any]?
    private let workspaceNotifications: NotificationCenter
    private let lockNotifications: NotificationCenter
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var isRunning = false
    private var screenIsLocked = false
    private var sessionIsInactive = false
    private var isSleeping = false
    private var lastAllowsCapture = false

    init(snapshot: @escaping () -> [String: Any]? = {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }, workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
       lockNotifications: NotificationCenter = DistributedNotificationCenter.default()) {
        self.snapshot = snapshot
        self.workspaceNotifications = workspaceNotifications
        self.lockNotifications = lockNotifications
    }

    /// Refresh before reading the pasteboard: recovery can discard pending changes.
    var allowsCapture: Bool {
        precondition(Thread.isMainThread)
        guard isRunning else { return false }
        refresh()
        return lastAllowsCapture
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !isRunning else { return }
        isRunning = true
        observe(Self.screenLocked, in: lockNotifications) { $0.screenIsLocked = true }
        observe(Self.screenUnlocked, in: lockNotifications) { $0.screenIsLocked = false }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: workspaceNotifications) {
            $0.sessionIsInactive = true
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspaceNotifications) {
            $0.sessionIsInactive = false
        }
        observe(NSWorkspace.willSleepNotification, in: workspaceNotifications) { $0.isSleeping = true }
        observe(NSWorkspace.didWakeNotification, in: workspaceNotifications) { $0.isSleeping = false }
        refresh(notifyAlways: true)
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        removeObservers()
        isRunning = false
        screenIsLocked = false
        sessionIsInactive = false
        isSleeping = false
        lastAllowsCapture = false
        onTransition?()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter,
                         update: @escaping (ClipboardSessionMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            update(self)
            // Even a duplicate boundary must discard clipboard changes: the screen
            // can lock and unlock entirely between two clipboard polls.
            self.refresh(notifyAlways: true)
        }
        observations.append((center, token))
    }

    private func refresh(notifyAlways: Bool = false) {
        let allowed = !screenIsLocked && !sessionIsInactive && !isSleeping && snapshotAllowsCapture()
        let changed = allowed != lastAllowsCapture
        lastAllowsCapture = allowed
        if changed || notifyAlways { onTransition?() }
    }

    private func snapshotAllowsCapture() -> Bool {
        guard let session = snapshot(),
              Self.boolean(session[kCGSessionOnConsoleKey as String]) == true,
              Self.boolean(session[kCGSessionLoginDoneKey as String]) == true else { return false }
        // CGSession has no public lock constant. This additional WindowServer key
        // is present when locked and absent in the normal unlocked snapshot.
        // Notifications are also undocumented, but used by Electron's macOS
        // power monitor. Keep their lock flag independent from session activation.
        guard let lockValue = session["CGSSessionScreenIsLocked"] else { return true }
        return Self.boolean(lockValue) == false
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func removeObservers() {
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
    }

    deinit { removeObservers() }
}
