import SwiftUI

/// NSViewRepresentable that bridges SurfaceView (NSView) into SwiftUI.
/// Creates surfaces lazily and retrieves them from SurfaceManager by pane ID.
struct SurfaceContainerView: NSViewRepresentable {
    let paneID: UUID
    let workingDirectory: String
    let isFocused: Bool
    @Environment(\.surfaceManager) private var surfaceManager
    @Environment(\.ghosttyConfig) private var ghosttyConfig

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        // Create surface lazily if it doesn't exist yet
        if surfaceManager.surface(for: paneID) == nil {
            surfaceManager.createSurface(
                paneID: paneID,
                workingDirectory: workingDirectory,
                backgroundOpacity: ghosttyConfig.backgroundOpacity
            )
        }

        if let surface = surfaceManager.surface(for: paneID) {
            embedSurface(surface, in: container)

            if isFocused {
                DispatchQueue.main.async {
                    surface.window?.makeFirstResponder(surface)
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

        // Handle focus
        if isFocused {
            DispatchQueue.main.async {
                surface.window?.makeFirstResponder(surface)
            }
        }
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
}
