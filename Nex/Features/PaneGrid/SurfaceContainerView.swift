import ComposableArchitecture
import SwiftUI

/// NSViewRepresentable that bridges SurfaceView (NSView) into SwiftUI.
/// Creates surfaces lazily and retrieves them from SurfaceManager by pane ID.
///
/// The hosting NSView (`SurfaceHostView`) only adopts the shared singleton
/// `SurfaceView` while it lives in the *primary* main window. A duplicate
/// main window — SwiftUI spawns one for a Finder "Open With" file-open on
/// the already-running app, which `DuplicateMainWindowCloser` then closes —
/// must never steal the surface: an NSView lives in a single view hierarchy,
/// so re-parenting it into the doomed duplicate strands it blank the moment
/// that window closes, wiping every visible terminal in the workspace (#260).
struct SurfaceContainerView: NSViewRepresentable {
    let paneID: UUID
    let workingDirectory: String
    let isFocused: Bool
    /// Optional launch command for the lazy-create fallback. When non-nil,
    /// a newly spawned surface runs this command instead of the default shell.
    var command: String?
    /// Workspace-profile name for the lazy-create fallback. This view races
    /// the reducer effect (first caller wins in SurfaceManager), so it must
    /// inject the same profile env or profiles apply only when the effect
    /// wins the race.
    var profileName: String?
    @Environment(\.surfaceManager) private var surfaceManager
    @Environment(\.ghosttyConfig) private var ghosttyConfig
    @Environment(\.sidebarTextEditingActive) private var sidebarTextEditingActive
    /// Resolved here — not at the call site — so the config-file read only
    /// happens when the lazy-create branch actually spawns, not per render.
    @Dependency(\.workspaceProfiles) private var workspaceProfiles

    func makeNSView(context _: Context) -> SurfaceHostView {
        // Create surface lazily if it doesn't exist yet
        if surfaceManager.surface(for: paneID) == nil {
            let env = workspaceProfiles.resolveEnv(
                profileName ?? WorkspaceProfilesClient.defaultProfileName
            )
            surfaceManager.createSurface(
                paneID: paneID,
                workingDirectory: workingDirectory,
                backgroundOpacity: ghosttyConfig.backgroundOpacity,
                command: command,
                env: env
            )
        }

        let host = SurfaceHostView(paneID: paneID, surfaceManager: surfaceManager)
        host.wantsFocus = isFocused
        host.sidebarEditing = sidebarTextEditingActive
        // Do NOT embed here: `makeNSView` runs before the view is parented in a
        // window, so we can't yet tell whether this is the primary window or a
        // duplicate. `SurfaceHostView.viewDidMoveToWindow` performs the
        // primary-gated embed once the window (and its role) is known.
        return host
    }

    func updateNSView(_ host: SurfaceHostView, context _: Context) {
        // SwiftUI may reuse a host across panes; keep its target current.
        host.paneID = paneID
        host.wantsFocus = isFocused
        host.sidebarEditing = sidebarTextEditingActive
        host.syncSurface()
    }
}

/// Container NSView that hosts a pane's shared singleton `SurfaceView`, but
/// only while parented in the primary main window (see `MainWindowRegistry`).
/// Adoption is deferred to `viewDidMoveToWindow` and gated on primary status
/// so a transient duplicate window can't steal the surface out of the primary
/// window and strand it blank when it closes (#260).
final class SurfaceHostView: NSView {
    var paneID: UUID
    let surfaceManager: SurfaceManager
    /// Whether this pane is the focused one; drives the first-responder grab.
    var wantsFocus = false
    /// True while the sidebar is inline-editing text; suppresses focus grabs
    /// so re-renders don't snatch first responder from an active TextField.
    var sidebarEditing = false

    init(paneID: UUID, surfaceManager: SurfaceManager) {
        self.paneID = paneID
        self.surfaceManager = surfaceManager
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSurface()
    }

    /// Adopt the shared surface and apply focus — but only in the primary main
    /// window. Idempotent; safe to call from `viewDidMoveToWindow` and
    /// `updateNSView`. A non-primary (duplicate) window leaves the surface
    /// untouched so it stays parented in the primary window.
    func syncSurface() {
        guard let window else { return }
        // `MainWindowRegistry.isPrimary` claims the primary slot for the first
        // window that asks and returns `false` for any later one — the same
        // routing `DuplicateMainWindowCloser` / `WindowFrameRestorer` use, so
        // the answer is stable regardless of which view's hook fires first.
        guard MainWindowRegistry.isPrimary(window) else { return }
        guard let surface = surfaceManager.surface(for: paneID) else { return }

        // Drop any stale subview that isn't our target surface (e.g. after
        // SwiftUI recycles this host onto a different pane).
        for subview in subviews where subview !== surface {
            subview.removeFromSuperview()
        }

        // Re-parent if needed (SwiftUI recreates the container after layout
        // changes, e.g. closing a sibling pane collapses a split).
        if surface.superview !== self {
            surface.removeFromSuperview()
            embed(surface)
        }

        if wantsFocus, !sidebarEditing {
            DispatchQueue.main.async {
                Self.focusSurfaceIfAppropriate(surface)
            }
        }
    }

    /// Add the surface using Auto Layout constraints. Constraints handle
    /// zero-initial-bounds correctly (unlike autoresizingMask), which matters
    /// when SwiftUI recreates the container during layout transitions.
    private func embed(_ surface: NSView) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// Grants first responder to the surface unless a text editor currently
    /// holds it. Safety net in addition to the `sidebarEditing` gate above.
    private static func focusSurfaceIfAppropriate(_ surface: NSView) {
        guard let window = surface.window else { return }
        if window.firstResponder === surface {
            return
        }
        if window.firstResponder is NSText {
            return
        }
        window.makeFirstResponder(surface)
    }
}

extension EnvironmentValues {
    @Entry var surfaceManager: SurfaceManager = .init()
    /// True while the sidebar is presenting an inline text editor (group
    /// rename, workspace rename, etc.). SurfaceContainerView watches this
    /// to suppress its focus-grab on state re-renders.
    @Entry var sidebarTextEditingActive: Bool = false
}
