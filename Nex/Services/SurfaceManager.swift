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

    /// Resolve the live `SurfaceView` whose libghostty surface matches
    /// `rawSurface`, by pointer identity against the registered views —
    /// mirrors `paneID(for:)` and, crucially, never dereferences
    /// `rawSurface` itself. Used by the `GHOSTTY_ACTION_RENDER` handler
    /// (issue #194): a render draining for a surface being freed off the
    /// main thread (issue #136 teardown) simply finds no match and is
    /// dropped, avoiding a use-after-free of the C surface struct.
    func surfaceView(forRawSurface rawSurface: ghostty_surface_t) -> SurfaceView? {
        lock.withLock {
            surfaces.first { _, view in
                view.ghosttySurface?.surface == rawSurface
            }?.value
        }
    }

    @MainActor
    func destroySurface(paneID: UUID) {
        let surfaceView = lock.withLock {
            surfaces.removeValue(forKey: paneID)
        }
        guard let surfaceView else { return }
        // Detach the view synchronously on main, then free the surface off
        // the main thread so a SIGHUP-trapping child can't hang the UI
        // (issue #136). detachForTeardown() nils ghosttySurface, so the
        // view's deinit won't double-free.
        guard let rawSurface = surfaceView.detachForTeardown() else { return }
        GhosttyApp.shared.freeSurfaceAsync(rawSurface, retaining: surfaceView)
    }

    @MainActor
    func destroyAll() {
        let all = lock.withLock {
            let copy = surfaces
            surfaces.removeAll()
            return copy
        }
        for (_, surfaceView) in all {
            guard let rawSurface = surfaceView.detachForTeardown() else { continue }
            GhosttyApp.shared.freeSurfaceAsync(rawSurface, retaining: surfaceView)
        }
    }

    /// Re-sync every live surface's size and request a redraw (issue #194).
    /// Called on app reactivation so panes spawned while Nex was
    /// background/occluded — which can miss their one output-/layout-driven
    /// draw and come up with a blank body — repaint. Each surface no-ops
    /// itself when detached (nil window / zero bounds), so this only touches
    /// panes currently visible in a window.
    @MainActor
    func resyncVisibleSurfaces() {
        let all = lock.withLock { Array(surfaces.values) }
        for surface in all {
            surface.resyncForRedraw()
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
    /// are dropped silently — broadcast is best-effort. Single lock
    /// acquisition so the group lookup and the surface dictionary
    /// snapshot can't drift between two acquisitions.
    func syncTargets(sourcePaneID: UUID) -> [SurfaceView] {
        lock.withLock {
            var result: [SurfaceView] = []
            for (_, group) in syncGroups where group.contains(sourcePaneID) {
                for id in group where id != sourcePaneID {
                    if let view = surfaces[id] {
                        result.append(view)
                    }
                }
            }
            return result
        }
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
