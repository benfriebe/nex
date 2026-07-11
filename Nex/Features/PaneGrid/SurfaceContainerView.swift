import ComposableArchitecture
import SwiftUI

/// NSViewRepresentable that bridges SurfaceView (NSView) into SwiftUI.
/// Creates surfaces lazily and retrieves them from SurfaceManager by pane ID.
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

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

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

        if let surface = surfaceManager.surface(for: paneID) {
            embedSurface(surface, in: container)

            if isFocused, !sidebarTextEditingActive {
                DispatchQueue.main.async {
                    Self.focusSurfaceIfAppropriate(surface)
                }
            }
        }
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        guard let surface = surfaceManager.surface(for: paneID) else { return }

        // Remove any stale subviews that aren't our target surface
        for subview in container.subviews where subview !== surface {
            subview.removeFromSuperview()
        }

        // Re-parent if needed (happens when SwiftUI recreates the container
        // after layout changes, e.g., closing a sibling pane collapses a split)
        if surface.superview !== container {
            surface.removeFromSuperview()
            embedSurface(surface, in: container)
        }

        // Handle focus — but skip while the sidebar is editing text (inline
        // group rename, etc.) so unrelated re-renders don't snatch focus
        // back from the active TextField.
        if isFocused, !sidebarTextEditingActive {
            DispatchQueue.main.async {
                Self.focusSurfaceIfAppropriate(surface)
            }
        }
    }

    /// Grants first responder to the surface unless a text editor currently
    /// holds it. Safety net in addition to the `sidebarTextEditingActive`
    /// environment gate above.
    private static func focusSurfaceIfAppropriate(_ surface: NSView) {
        guard let window = surface.window else { return }
        if window.firstResponder === surface { return }
        if window.firstResponder is NSText { return }
        window.makeFirstResponder(surface)
    }

    /// Add the surface to the container using Auto Layout constraints.
    /// Constraints handle zero-initial-bounds correctly (unlike autoresizingMask),
    /// which matters when SwiftUI recreates the container during layout transitions.
    private func embedSurface(_ surface: NSView, in container: NSView) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

extension EnvironmentValues {
    @Entry var surfaceManager: SurfaceManager = .init()
    /// True while the sidebar is presenting an inline text editor (group
    /// rename, workspace rename, etc.). SurfaceContainerView watches this
    /// to suppress its focus-grab on state re-renders.
    @Entry var sidebarTextEditingActive: Bool = false
}
