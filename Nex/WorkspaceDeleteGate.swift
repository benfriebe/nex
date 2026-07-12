import AppKit
import Foundation

/// UserDefaults key shared by `WorkspaceDeleteGate` and
/// `SettingsFeature` so the dialog's "Don't ask again" checkbox and the
/// Settings toggle write the same value. Declared outside the
/// `@MainActor` gate so the (non-isolated) `SettingsFeature` can
/// reference it. Mirrors `QuitGateDefaults`.
enum WorkspaceDeleteGateDefaults {
    static let confirm = "settings.confirmWorkspaceDeleteWhenActive"
}

/// AppKit confirmation gate for deleting a workspace that still has
/// active agents (running or waiting-for-input panes). This is the
/// "equivalent of the app-quit messaging" for workspace deletion: a
/// warning `NSAlert` with a "Don't ask again" suppression, mirroring
/// `QuitGate`. The CLI enforces the same guard server-side via
/// `--force` (see `handleWorkspaceDelete`), independent of this
/// GUI-only setting.
///
/// Pure static helper — unlike `QuitGate` it needs no store bridge, so
/// callers pass the workspace name and active-agent count directly.
@MainActor
enum WorkspaceDeleteGate {
    /// Whether the dialog fires at all. `true` by default; the
    /// suppression button on the alert and the Settings toggle both
    /// flip this same key.
    static var confirmWhenActive: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: WorkspaceDeleteGateDefaults.confirm) == nil {
            return true
        }
        return defaults.bool(forKey: WorkspaceDeleteGateDefaults.confirm)
    }

    /// Persist the suppression flag (i.e. the dialog's "Don't ask again"
    /// checkbox) AND broadcast so `SettingsFeature` can re-sync its
    /// toggle if the Settings window happens to be open.
    static func setConfirmWhenActive(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: WorkspaceDeleteGateDefaults.confirm)
        NotificationCenter.default.post(
            name: confirmChangedNotification,
            object: nil,
            userInfo: ["value": value]
        )
    }

    static let confirmChangedNotification = Notification.Name("Nex.confirmWorkspaceDeleteWhenActiveChanged")

    /// Decide whether to proceed with deleting a workspace. Returns
    /// `true` immediately when there are no active agents or the setting
    /// is off; otherwise runs the modal warning and returns whether the
    /// user confirmed. Updates `confirmWhenActive` when the suppression
    /// box is ticked, regardless of which button was clicked (macOS HIG:
    /// honour suppression even on Cancel).
    static func shouldDelete(workspaceName: String, activeAgentCount: Int) -> Bool {
        guard activeAgentCount > 0, confirmWhenActive else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \u{201C}\(workspaceName)\u{201D}?"
        alert.informativeText = Self.message(activeAgentCount: activeAgentCount)

        // Cancel is the first/default button (Return key) so an accidental
        // confirm can't destroy a live session — same posture as QuitGate.
        alert.addButton(withTitle: "Cancel")
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        let confirmed = response == .alertSecondButtonReturn

        if alert.suppressionButton?.state == .on {
            Self.setConfirmWhenActive(false)
        }

        return confirmed
    }

    static func message(activeAgentCount: Int) -> String {
        let noun = activeAgentCount == 1 ? "agent" : "agents"
        return "This workspace has \(activeAgentCount) active \(noun). Deleting it will terminate \(activeAgentCount == 1 ? "it" : "them")."
    }
}
