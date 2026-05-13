import AppKit
import os.log

/// Workaround for a SwiftUI WindowGroup quirk: after a system restart,
/// macOS's per-bundle Spaces binding ("Assign To: All Desktops" via the
/// Dock context menu) isn't reliably applied to the SwiftUI-managed
/// window before it's first shown (issue #102). The window appears on
/// only one desktop until the user toggles the Dock setting off and
/// back on, which causes the Dock to re-push the binding to
/// WindowServer.
///
/// We mirror what AppKit does for non-SwiftUI apps: read the user's
/// per-bundle assignment from `com.apple.spaces` defaults and
/// explicitly add `.canJoinAllSpaces` to the window's
/// `collectionBehavior` when the user picked "All Desktops". Native
/// AppKit apps only consult this binding at window creation, so we
/// match that semantics — runtime changes to the Dock setting are
/// still handled by the OS.
///
/// The `app-bindings` key in `com.apple.spaces` is undocumented Apple
/// plumbing. If Apple changes the format, this helper silently no-ops
/// (back to the bug it works around — not worse). The os_log line
/// when bindings is non-empty but our bundle is absent is the only
/// practical signal that the format has shifted.
enum WindowSpacesBinding {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.benfriebe.nex",
        category: "WindowSpacesBinding"
    )

    @MainActor
    static func applyIfNeeded(to window: NSWindow) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let bindings = systemAppBindings()
        if isAssignedToAllDesktops(bundleID: bundleID, bindings: bindings) {
            // Idempotent: insert is a no-op if .canJoinAllSpaces is already
            // set (CollectionBehavior is an OptionSet).
            window.collectionBehavior.insert(.canJoinAllSpaces)
            os_log(
                .info,
                log: log,
                "applied .canJoinAllSpaces from com.apple.spaces (bundle=%{public}@)",
                bundleID
            )
        } else if !bindings.isEmpty {
            // Surfaced at .info (not .debug) so it shows in Console.app
            // by default. This is the canary that the plist format has
            // shifted under us (Apple changed the entry shape and our
            // matcher no longer recognises the user's binding).
            os_log(
                .info,
                log: log,
                "no all-desktops binding for %{public}@ in %d entries",
                bundleID,
                bindings.count
            )
        }
    }

    /// Pure parsing logic. The Dock writes one entry per bound app to
    /// the `app-bindings` array. Observed entry shapes:
    ///   - `<bundle-id>`                          — All Desktops
    ///   - `<bundle-id> space:<UUID>`             — A specific desktop
    ///   - `<bundle-id> display:<UUID>`           — All Desktops + this display
    ///   - `<bundle-id> space:<UUID> display:...` — A specific desktop on this display
    /// Apps not in the array have no per-app binding (system default).
    ///
    /// "All desktops" is true for the bare bundle ID and for the
    /// display-only suffix (the user picked "All Desktops" alongside a
    /// monitor pin). It's false when a `space:` segment is present.
    ///
    /// Exact-prefix matching is load-bearing. A different bundle ID like
    /// `com.foo.helper` must not match when our bundle ID `com.foo` is
    /// a string-prefix of it; we always require either an exact match or
    /// a separator (space) before the suffix. Do not weaken to
    /// `contains(where:)` substring checks.
    static func isAssignedToAllDesktops(bundleID: String, bindings: [String]) -> Bool {
        let displayOnlyPrefix = bundleID + " display:"
        for entry in bindings {
            if entry == bundleID { return true }
            if entry.hasPrefix(displayOnlyPrefix), !entry.contains("space:") {
                return true
            }
        }
        return false
    }

    private static func systemAppBindings() -> [String] {
        guard let defaults = UserDefaults(suiteName: "com.apple.spaces"),
              let raw = defaults.array(forKey: "app-bindings") as? [String]
        else { return [] }
        return raw
    }
}
