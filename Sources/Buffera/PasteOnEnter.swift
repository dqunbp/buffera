import AppKit
import Carbon

struct PasteOnEnter {
    let target: NSRunningApplication
    let clipboardVersion: Int

    /// Activation is asynchronous. Abandon the request if another app wins focus.
    func afterActivation(frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
                         canPost: @escaping () -> Bool = CGPreflightPostEventAccess,
                         post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) },
                         isCurrent: @escaping () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        func deliver() {
            guard isCurrent(), !target.isTerminated, canPost(),
                  ProcessInfo.processInfo.systemUptime <= deadline,
                  let front = frontmost() else { return }
            guard front == target else {
                if front == .current {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: deliver)
                }
                return
            }
            let key = CGKeyCode(kVK_ANSI_V)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            post(down, target.processIdentifier)
            post(up, target.processIdentifier)
        }
        deliver()
    }
}
