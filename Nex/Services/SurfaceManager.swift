import ComposableArchitecture
import Foundation

/// Owns all SurfaceView instances across all workspaces.
/// Surfaces persist across workspace switches — they're removed from the
/// view hierarchy but kept alive so PTY processes continue running.
final class SurfaceManager: Sendable {
    private let lock = NSLock()
    /// nonisolated(unsafe) because access is protected by lock
    private nonisolated(unsafe) var surfaces: [UUID: SurfaceView] = [:]

    @MainActor
    func createSurface(
        paneID: UUID,
        workingDirectory: String,
        backgroundOpacity: Double = 1.0,
        command: String? = nil
    ) {
        // Guard against duplicate creation. Both the TCA effect and
        // SurfaceContainerView.makeNSView can call this; whichever runs
        // first wins. Without this check, the second call replaces the
        // displayed surface with a fresh one, orphaning the user's session.
        let exists = lock.withLock { surfaces[paneID] != nil }
        guard !exists else { return }

        let surface = SurfaceView(
            paneID: paneID,
            workingDirectory: workingDirectory,
            backgroundOpacity: backgroundOpacity,
            command: command
        )
        lock.withLock {
            surfaces[paneID] = surface
        }
    }

    func surface(for paneID: UUID) -> SurfaceView? {
        lock.withLock {
            surfaces[paneID]
        }
    }

    @MainActor
    func destroySurface(paneID: UUID) {
        let surfaceView = lock.withLock {
            surfaces.removeValue(forKey: paneID)
        }
        surfaceView?.ghosttySurface?.destroy()
        surfaceView?.ghosttySurface = nil // Prevent double-free in SurfaceView.deinit
    }

    @MainActor
    func destroyAll() {
        let all = lock.withLock {
            let copy = surfaces
            surfaces.removeAll()
            return copy
        }
        for (_, surfaceView) in all {
            surfaceView.ghosttySurface?.destroy()
            surfaceView.ghosttySurface = nil
        }
    }

    @MainActor
    func setAllSurfacesOpaque(_ isOpaque: Bool) {
        let all = lock.withLock { Array(surfaces.values) }
        for surface in all {
            surface.layer?.isOpaque = isOpaque
            surface.needsDisplay = true
        }
    }

    @MainActor
    func sendText(to paneID: UUID, text: String) {
        let surfaceView = lock.withLock { surfaces[paneID] }
        surfaceView?.ghosttySurface?.sendText(text)
    }

    /// Query the terminal grid dimensions (columns x rows) for a pane.
    @MainActor
    func gridSize(for paneID: UUID) -> (columns: UInt16, rows: UInt16)? {
        let surfaceView = lock.withLock { surfaces[paneID] }
        guard let size = surfaceView?.ghosttySurface?.size else { return nil }
        guard size.columns > 0, size.rows > 0 else { return nil }
        return (size.columns, size.rows)
    }

    /// Query the terminal cell size in points for a pane.
    @MainActor
    func cellSize(for paneID: UUID) -> (width: CGFloat, height: CGFloat)? {
        let surfaceView = lock.withLock { surfaces[paneID] }
        guard let size = surfaceView?.ghosttySurface?.size else { return nil }
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        let scale = surfaceView?.window?.backingScaleFactor ?? 2.0
        return (CGFloat(size.cell_width_px) / scale, CGFloat(size.cell_height_px) / scale)
    }

    /// Execute a ghostty binding action on a pane's surface.
    @MainActor
    @discardableResult
    func performBindingAction(on paneID: UUID, action: String) -> Bool {
        let surfaceView = lock.withLock { surfaces[paneID] }
        return surfaceView?.ghosttySurface?.performBindingAction(action) ?? false
    }

    /// Send text to a pane's terminal and press Enter to execute it.
    @MainActor
    func sendCommand(to paneID: UUID, command: String) {
        let surfaceView = lock.withLock { surfaces[paneID] }
        guard let surface = surfaceView?.ghosttySurface else { return }
        surface.sendText(command)
        surface.sendEnterKey()
    }

    /// Read the terminal contents of a pane as plain text. Returns nil if no
    /// surface is registered for the pane (e.g. it was destroyed concurrently).
    /// When `includeScrollback` is false, returns just the visible viewport.
    @MainActor
    func captureContents(paneID: UUID, includeScrollback: Bool) -> String? {
        let surfaceView = lock.withLock { surfaces[paneID] }
        return surfaceView?.ghosttySurface?.readText(includeScrollback: includeScrollback)
    }

    /// Grant keyboard focus to a pane's surface, overriding whatever
    /// currently holds first responder (e.g. the command palette's
    /// TextField editor). Unlike `SurfaceContainerView`'s passive focus
    /// grab — which bails when an NSText holds first responder — this
    /// is an authoritative move used by reducer effects.
    @MainActor
    func focus(paneID: UUID) {
        _focusCalls.append(paneID)
        let surfaceView = lock.withLock { surfaces[paneID] }
        guard let surface = surfaceView, let window = surface.window else { return }
        window.makeFirstResponder(surface)
    }

    /// Test-only record of paneIDs passed to `focus(paneID:)`, in order.
    /// Lets reducer-level tests assert on focus effects without a
    /// live window hierarchy.
    private nonisolated(unsafe) var _focusCalls: [UUID] = []
    @MainActor
    var focusCalls: [UUID] { _focusCalls }

    func paneID(for rawSurface: ghostty_surface_t) -> UUID? {
        lock.withLock {
            surfaces.first { _, view in
                view.ghosttySurface?.surface == rawSurface
            }?.key
        }
    }

    var activeSurfaceCount: Int {
        lock.withLock { surfaces.count }
    }
}

// MARK: - TCA Dependency

extension SurfaceManager: DependencyKey {
    static let liveValue = SurfaceManager()
    static let testValue = SurfaceManager()
}

extension DependencyValues {
    var surfaceManager: SurfaceManager {
        get { self[SurfaceManager.self] }
        set { self[SurfaceManager.self] = newValue }
    }
}
