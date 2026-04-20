import AppKit

/// Bring Nex to the foreground (or optionally hide on re-press).
///
/// When `hideOnRepress` is true and Nex is already the active application,
/// the hotkey acts as a toggle and hides the app. Otherwise we activate and
/// deminiaturize any miniaturized windows.
///
/// We deliberately do NOT pick a specific "main" window: `NSApp.windows`
/// contains Settings and Help alongside the primary content window, and
/// filtering them apart reliably is fragile (multiple windows pass
/// `canBecomeMain && isRestorable`). `NSApp.activate` already restores the
/// most-recently-focused window via the standard macOS window-ordering
/// behavior, so we let that happen and only step in when a window is
/// miniaturized (otherwise activation would only bring the menu bar
/// forward with no visible window).
@MainActor
func toggleAppFrontmost(hideOnRepress: Bool) {
    if hideOnRepress, NSApp.isActive {
        NSApp.hide(nil)
        return
    }

    NSApp.activate(ignoringOtherApps: true)

    for window in NSApp.windows
        where window.isMiniaturized && !(window is NSPanel) {
        window.deminiaturize(nil)
    }
}
