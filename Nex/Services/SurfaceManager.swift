import ComposableArchitecture
import Foundation

/// Owns all SurfaceView instances across all workspaces.
/// Surfaces persist across workspace switches — they're removed from the
/// view hierarchy but kept alive so PTY processes continue running.
final class SurfaceManager: Sendable {
    private let lock = NSLock()
    /// nonisolated(unsafe) because access is protected by lock
    private nonisolated(unsafe) var surfaces: [UUID: SurfaceView] = [:]
    /// Per-workspace sync-input groups. When a key event lands in a
    /// pane that belongs to any group, the same event is mirrored to
    /// every other pane in that group via libghostty. Replaced
    /// wholesale by the WorkspaceFeature reducer on every sync state
    /// change; empty / missing entry = no mirroring for that workspace.
    /// See `Issue #121` (tmux-style synchronise-panes).
    private nonisolated(unsafe) var syncGroups: [UUID: Set<UUID>] = [:]

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

    /// Send a single named keystroke (Enter, Tab, Escape, ...) to a
    /// pane's terminal. Used by `nex pane send-key` to deliver an
    /// explicit keystroke outside any bracketed-paste envelope —
    /// `pane send "text"` followed by `pane send-key enter` is the
    /// reliable submit path for TUI targets (issue #98). Returns
    /// false if `keyName` is not in the supported allowlist.
    @MainActor
    @discardableResult
    func sendKey(to paneID: UUID, keyName: String) -> Bool {
        let surfaceView = lock.withLock { surfaces[paneID] }
        guard let surface = surfaceView?.ghosttySurface else { return false }
        return surface.sendNamedKey(keyName)
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

    // MARK: - Synchronise input (issue #121)

    /// Replace the sync-input group for one workspace. `paneIDs` is the
    /// full set of panes that should mirror each other; passing an
    /// empty set turns sync off for that workspace. Workspaces with
    /// no entry contribute nothing to broadcast lookups.
    func setSyncGroup(workspaceID: UUID, paneIDs: Set<UUID>) {
        lock.withLock {
            if paneIDs.isEmpty {
                syncGroups.removeValue(forKey: workspaceID)
            } else {
                syncGroups[workspaceID] = paneIDs
            }
        }
    }

    /// True if `paneID` is currently participating in any sync group.
    /// Read by the view layer (header chrome) to show the sync badge.
    func isSyncing(paneID: UUID) -> Bool {
        lock.withLock {
            syncGroups.values.contains { $0.contains(paneID) }
        }
    }

    /// Snapshot the set of pane IDs that should mirror a key event
    /// originating from `sourcePaneID`. Excludes the source itself.
    /// Returns the empty set when the source is not in any sync group.
    /// Exposed publicly so tests can assert the cross-workspace
    /// boundary without registering live `SurfaceView` instances.
    func syncTargetIDs(sourcePaneID: UUID) -> Set<UUID> {
        lock.withLock {
            var ids: Set<UUID> = []
            for (_, group) in syncGroups where group.contains(sourcePaneID) {
                ids.formUnion(group)
            }
            ids.remove(sourcePaneID)
            return ids
        }
    }

    /// Resolve the sibling pane IDs to live `SurfaceView` instances.
    /// Surfaces that have been torn down (PTY exited, view destroyed)
    /// are dropped silently — broadcast is best-effort.
    func syncTargets(sourcePaneID: UUID) -> [SurfaceView] {
        let targetIDs = syncTargetIDs(sourcePaneID: sourcePaneID)
        if targetIDs.isEmpty { return [] }
        let snapshot = lock.withLock { surfaces }
        return targetIDs.compactMap { snapshot[$0] }
    }

    /// Mirror a libghostty key event to every sibling pane in the
    /// source's sync group. Called by `SurfaceView.sendKey` immediately
    /// after the local delivery. Must be called inside any `withCString`
    /// that owns the `key.text` pointer — by the time we return, no
    /// pointer reads outlive the call. Returns synchronously after all
    /// libghostty calls have consumed their copies.
    @MainActor
    func broadcastKey(from sourcePaneID: UUID, key: ghostty_input_key_s) {
        for surface in syncTargets(sourcePaneID: sourcePaneID) {
            _ = surface.ghosttySurface?.sendKey(key)
        }
    }

    /// Mirror a UTF-8 text payload (dictation, services menu paste,
    /// drag-drop) to every sibling pane in the source's sync group.
    /// Called by `SurfaceView.insertText` outside the keyDown
    /// accumulator path (the keyDown path goes through `broadcastKey`
    /// after libghostty composition resolves).
    @MainActor
    func broadcastText(from sourcePaneID: UUID, text: String) {
        for surface in syncTargets(sourcePaneID: sourcePaneID) {
            surface.ghosttySurface?.sendText(text)
        }
    }

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
