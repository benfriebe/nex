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
        // Stop every active graft session so the `.git/nex-graft-active`
        // breadcrumbs get cleared on a clean quit — otherwise the
        // orphan-recovery banner would fire on every launch even when
        // the user shut down cleanly.
        QuitGate.shared.flushGraftSessions()

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

    /// Receives files opened from Finder ("Open With" / double-click) and
    /// forwards markdown ones into the existing open pipeline via
    /// `FileOpenGate`, reusing the same `.openFileAtPath` action as
    /// drag-and-drop (issue #197). Only the modern unified `open:` method
    /// is implemented — when present, AppKit never calls the legacy
    /// `application(_:openFiles:)`, so there is no double-open. Handles
    /// multi-file open events and both the running and cold-launch cases
    /// (the gate buffers cold-launch arrivals until the store is wired).
    func application(_: NSApplication, open urls: [URL]) {
        var forwarded = false
        for url in urls where url.isFileURL
            && FileOpenGate.markdownExtensions.contains(url.pathExtension.lowercased()) {
            FileOpenGate.shared.open(url.path)
            forwarded = true
        }
        // Surface the window so an open triggered while Nex is running but
        // minimised/hidden actually shows the new pane rather than adding it
        // to an off-screen window. No-op on cold launch (no window yet;
        // Launch Services activates us anyway).
        if forwarded {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
