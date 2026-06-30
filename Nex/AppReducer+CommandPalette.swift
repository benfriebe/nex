import ComposableArchitecture
import Foundation

// MARK: - CommandPalette reduce-block

extension AppReducer {
    /// Extracted per-domain reduce-block owning the command-palette
    /// overlay's `Action` cases: open/close (with focus-handoff
    /// scheduling), query filtering, selection movement, and confirm.
    ///
    /// This is a reduce-block over the shared `AppReducer.State`, **not**
    /// a child reducer with its own State slice: the handlers compute
    /// selection over the `state.commandPaletteItems` computed property
    /// (which reads `state.workspaces`), and `commandPaletteConfirm`
    /// writes `state.activeWorkspaceID` + `lastAccessedAt` directly. The
    /// three UI fields (`isCommandPaletteVisible`, `commandPaletteQuery`,
    /// `commandPaletteSelectedIndex`) and the computed `commandPaletteItems`
    /// stay on `AppReducer.State` and are read/written here via `state`.
    ///
    /// The guard short-circuits every non-CommandPalette action via
    /// `Self.domain(of:)` (the exhaustive partition), so this block only
    /// ever runs the cases below. Case bodies, the focus-handoff helper,
    /// and the cancellation-ID enum are moved here verbatim from the
    /// original `AppReducer.body` switch and the struct body; dependency
    /// access (`surfaceManager`, `clock`) goes through `self` exactly as
    /// before.
    var commandPaletteReducer: some ReducerOf<Self> {
        Reduce { state, action in
            guard Self.domain(of: action) == .commandPalette else { return .none }
            switch action {
            case .toggleCommandPalette:
                state.isCommandPaletteVisible.toggle()
                if state.isCommandPaletteVisible {
                    state.commandPaletteQuery = ""
                    state.commandPaletteSelectedIndex = 0
                    // Reopening within the handoff window supersedes any
                    // pending focus grab scheduled by the prior close.
                    return .cancel(id: PaletteFocusID.pending)
                }
                let activePane = state.activeWorkspaceID.flatMap { state.workspaces[id: $0]?.focusedPaneID }
                return scheduleFocusAfterPaletteClose(paneID: activePane)

            case .dismissCommandPalette:
                state.isCommandPaletteVisible = false
                state.commandPaletteQuery = ""
                let activePane = state.activeWorkspaceID.flatMap { state.workspaces[id: $0]?.focusedPaneID }
                return scheduleFocusAfterPaletteClose(paneID: activePane)

            case .commandPaletteQueryChanged(let query):
                state.commandPaletteQuery = query
                state.commandPaletteSelectedIndex = 0
                return .none

            case .commandPaletteSelectIndex(let index):
                let count = state.commandPaletteItems.count
                if count > 0 {
                    state.commandPaletteSelectedIndex = min(max(index, 0), count - 1)
                }
                return .none

            case .commandPaletteSelectNext:
                let count = state.commandPaletteItems.count
                if count > 0 {
                    state.commandPaletteSelectedIndex = min(
                        state.commandPaletteSelectedIndex + 1, count - 1
                    )
                }
                return .none

            case .commandPaletteSelectPrevious:
                state.commandPaletteSelectedIndex = max(
                    state.commandPaletteSelectedIndex - 1, 0
                )
                return .none

            case .commandPaletteConfirm:
                let items = state.commandPaletteItems
                guard state.commandPaletteSelectedIndex < items.count else {
                    // Confirm with no items still closes the palette;
                    // focus the active pane so the window isn't left
                    // without keyboard focus.
                    state.isCommandPaletteVisible = false
                    let activePane = state.activeWorkspaceID.flatMap { state.workspaces[id: $0]?.focusedPaneID }
                    return scheduleFocusAfterPaletteClose(paneID: activePane)
                }
                let item = items[state.commandPaletteSelectedIndex]
                state.isCommandPaletteVisible = false
                state.commandPaletteQuery = ""

                // Set workspace directly to avoid effect indirection
                state.activeWorkspaceID = item.workspaceID
                state.workspaces[id: item.workspaceID]?.lastAccessedAt = Date()

                var effects: [Effect<Action>] = [
                    .send(.persistState),
                    .send(.refreshGitStatus)
                ]
                if let paneID = item.paneID {
                    effects.append(.send(.workspaces(.element(
                        id: item.workspaceID, action: .focusPane(paneID)
                    ))))
                }
                // Claim first responder for the destination pane once the
                // palette's fade-out completes. SurfaceContainerView's
                // passive focus grab bails while the palette's TextField
                // editor still holds first responder.
                let targetPaneID = item.paneID
                    ?? state.workspaces[id: item.workspaceID]?.focusedPaneID
                effects.append(scheduleFocusAfterPaletteClose(paneID: targetPaneID))
                return .merge(effects)

            default:
                return .none
            }
        }
    }

    // MARK: - Palette focus handoff + cancellation ID

    private enum PaletteFocusID: Hashable { case pending }

    /// Delay after the palette triggers a focus change before we claim
    /// first responder for the destination surface. Matches the palette
    /// overlay's fade-out (`ContentView` uses 0.15s) with a small margin
    /// so the palette's TextField has fully released its field editor.
    static let paletteFocusHandoffDelay: Duration = .milliseconds(200)

    /// Focus the surface for the currently-active workspace's focused
    /// pane after the palette's dismiss transition completes. Emitted by
    /// every palette-close path (confirm, dismiss, escape) so keyboard
    /// focus always lands back on a terminal pane. Cancellable via
    /// `PaletteFocusID.pending` so a subsequent palette interaction
    /// within the delay window supersedes any earlier pending focus.
    private func scheduleFocusAfterPaletteClose(
        paneID: UUID?
    ) -> Effect<Action> {
        guard let paneID else { return .none }
        return .run { [surfaceManager, clock] _ in
            try await clock.sleep(for: Self.paletteFocusHandoffDelay)
            await surfaceManager.focus(paneID: paneID)
        }
        .cancellable(id: PaletteFocusID.pending, cancelInFlight: true)
    }
}
