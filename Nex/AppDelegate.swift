import AppKit

/// AppDelegate that intercepts Cmd+Q / "Quit Nex" so we can show a
/// confirmation dialog before the app terminates (issue #129).
///
/// Hooks every termination path: menu-bar Quit, Cmd+Q, AppleScript quit,
/// system logout, and `NSApp.terminate(_:)` calls (including Sparkle
/// auto-update relaunches). The dialog fires unconditionally unless the
/// user has disabled it; when active agents exist the dialog body names
/// them so an accidental quit doesn't silently lose work.
final class NexAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Always flush pending markdown saves before we go anywhere
        // near a termination decision. The editor's 500ms debounce can
        // still have a write outstanding when Cmd+Q fires; if we don't
        // flush here, a `.terminateNow` (e.g. dialog disabled) kills
        // the process before the debounced Task can run (issue #129).
        QuitGate.shared.flushPendingSaves()

        // Skip the dialog during XCTest runs and when the user has
        // disabled it via Settings or the suppression checkbox.
        guard !NexApp.isTestMode, QuitGate.confirmQuitWhenActive else {
            return .terminateNow
        }

        let summary = QuitGate.shared.summarize()
        return QuitGate.shared.presentQuitConfirmation(summary: summary)
            ? .terminateNow
            : .terminateCancel
    }
}
