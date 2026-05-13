import AppKit
import Foundation

/// Snapshot of in-progress agent activity used to decide whether to
/// show a quit-confirmation dialog.
struct ActivitySummary: Equatable {
    let agentCount: Int
    let workspaceCount: Int

    static let zero = ActivitySummary(agentCount: 0, workspaceCount: 0)

    var isEmpty: Bool { agentCount == 0 }
}

/// UserDefaults keys shared by `QuitGate` and `SettingsFeature` so the
/// suppression checkbox on the dialog and the toggle in Settings write
/// the same value. Declared outside `@MainActor QuitGate` so non-
/// isolated callers (like `SettingsFeature`) can reference them.
enum QuitGateDefaults {
    static let confirmQuit = "settings.confirmQuitWhenActive"
}

/// Bridge between the AppKit termination callback and the TCA store.
/// `NexApp.onAppear` wires `summarize` to a closure that reads the
/// store; `NexAppDelegate.applicationShouldTerminate` calls it.
///
/// Lives outside TCA because `applicationShouldTerminate(_:)` is
/// invoked synchronously by AppKit before SwiftUI scenes get a chance
/// to forward the event, and the decision needs to return immediately.
@MainActor
final class QuitGate {
    static let shared = QuitGate()

    var summarize: () -> ActivitySummary = { .zero }

    /// Synchronously flush in-flight markdown auto-saves. Wired by
    /// `MarkdownEditorView` so the AppDelegate doesn't need to know
    /// about its internals.
    var flushPendingSaves: () -> Void = {}

    private init() {}

    /// Whether the dialog should fire at all. `true` by default; the
    /// suppression button on the alert and the Settings toggle both
    /// flip this same key.
    static var confirmQuitWhenActive: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: QuitGateDefaults.confirmQuit) == nil {
            return true
        }
        return defaults.bool(forKey: QuitGateDefaults.confirmQuit)
    }

    /// Set the suppression flag from the AppKit side (i.e. the
    /// dialog's "Don't ask again" checkbox). Persists to UserDefaults
    /// AND broadcasts so `SettingsFeature.State.confirmQuitWhenActive`
    /// can re-sync if the Settings window happens to be open.
    static func setConfirmQuitWhenActive(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: QuitGateDefaults.confirmQuit)
        NotificationCenter.default.post(
            name: confirmQuitChangedNotification,
            object: nil,
            userInfo: ["value": value]
        )
    }

    static let confirmQuitChangedNotification = Notification.Name("Nex.confirmQuitWhenActiveChanged")

    /// Run the modal NSAlert. Returns true when the user confirms quit.
    /// Updates `confirmQuitWhenActive` when the suppression box is ticked,
    /// regardless of which button the user clicked (macOS HIG: suppression
    /// state should be honoured even on Cancel).
    func presentQuitConfirmation(summary: ActivitySummary) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Nex?"
        alert.informativeText = Self.message(for: summary)

        // Cancel is the first/default button (Return key). Cmd+Q is the
        // accidental keystroke we're guarding against, so the safe option
        // wins by default. Issue #129 spec calls this out explicitly.
        alert.addButton(withTitle: "Cancel")
        let quitButton = alert.addButton(withTitle: "Quit")
        quitButton.hasDestructiveAction = true

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        let confirmed = response == .alertSecondButtonReturn

        if alert.suppressionButton?.state == .on {
            Self.setConfirmQuitWhenActive(false)
        }

        return confirmed
    }

    static func message(for summary: ActivitySummary) -> String {
        guard !summary.isEmpty else {
            return "Are you sure you want to quit Nex?"
        }
        let agentNoun = summary.agentCount == 1 ? "agent" : "agents"
        let workspaceNoun = summary.workspaceCount == 1 ? "workspace" : "workspaces"
        return "Nex has \(summary.agentCount) active \(agentNoun) across \(summary.workspaceCount) \(workspaceNoun). Quitting will terminate all sessions."
    }
}
