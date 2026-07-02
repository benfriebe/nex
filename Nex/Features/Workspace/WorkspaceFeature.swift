import ComposableArchitecture
import Foundation

struct ClosedPaneSnapshot: Equatable {
    var workingDirectory: String
    var label: String?
    var type: PaneType
    var filePath: String?
    var scratchpadContent: String?
    var agentSessionID: String?
    var markdownFontSize: Double = 14
    /// Captured web-pane sidecar at the moment of close, so
    /// `reopenClosedPane` can restore the same URL/tab set. Nil for
    /// non-web panes and for closed private panes (which intentionally
    /// drop their tabs at quit/close time).
    var webState: WebPaneState?
}

@Reducer
struct WorkspaceFeature {
    @ObservableState
    struct State: Equatable, Identifiable {
        let id: UUID
        var name: String
        var slug: String
        var color: WorkspaceColor
        /// Optional avatar icon override (SF Symbol or emoji). `nil` falls
        /// back to the first letter of the workspace name.
        var icon: GroupIcon?
        var panes: IdentifiedArrayOf<Pane>
        var layout: PaneLayout
        var focusedPaneID: UUID?
        /// Per-session focus history, most-recent at end. Pushed on
        /// every focus change via `setFocus`; popped on pane close so
        /// focus returns to the previously-focused pane instead of an
        /// adjacent one. Not persisted: resets across app restart.
        var focusHistory: [UUID] = []
        var repoAssociations: IdentifiedArrayOf<RepoAssociation> = []
        var recentlyClosedPanes: [ClosedPaneSnapshot] = []
        /// Panes that are off-layout but whose ghostty surfaces/PTYs must
        /// stay alive (currently: sources parked by `nex open --here`).
        /// Not persisted — surfaces can't be restored across app
        /// restarts. A `Pane` lives in exactly one of `panes` or
        /// `parkedPanes` at any time.
        var parkedPanes: IdentifiedArrayOf<Pane> = []
        /// Sidecar state for `.web` panes — tab list, active tab,
        /// private flag. Kept off `Pane` itself so non-web consumers
        /// don't need to learn the type. Mirrors `parkedPanes`'s
        /// "lives alongside `panes`" model.
        var webPanes: [UUID: WebPaneState] = [:]
        var zoomedPaneID: UUID?
        var savedLayout: PaneLayout?
        var searchingPaneID: UUID?
        var searchNeedle: String = ""
        var searchTotal: Int?
        var searchSelected: Int?
        var currentLayoutIndex: Int?
        var createdAt: Date
        var lastAccessedAt: Date
        /// Free-form tags attached to this workspace. Ordered (preserves
        /// add order), deduplicated case-sensitively. Empty by default.
        /// Drives the sidebar filter — see `WorkspaceListView` filter
        /// field and `WorkspaceInspectorView` label editor.
        var labels: [String] = []
        /// Tmux-style synchronise-input toggle (issue #121). When true,
        /// keystrokes typed in any pane of this workspace are mirrored
        /// to every other pane that isn't in `syncInputExcluded`. New
        /// panes opened while sync is active auto-join the group.
        /// Transient — resets on app restart.
        var isSyncInputActive: Bool = false
        /// Panes explicitly opted out of the active sync group.
        /// Strictly ephemeral within a single on-cycle: the set is
        /// cleared on every transition of `isSyncInputActive` (both
        /// off→on and on→off) so each on-cycle starts from a fresh
        /// "all shell panes participate" baseline. This means
        /// `nex pane sync exclude` run while sync is off has no
        /// effect on the next on-cycle — coordinators should sequence
        /// `sync on` first, then `sync exclude --target <pane>`.
        /// Transient — also resets on app restart.
        var syncInputExcluded: Set<UUID> = []

        /// Pane IDs that should mirror each other's keystrokes right
        /// now. Empty when sync is off OR when fewer than two shell
        /// panes would participate (mirroring to nothing is a no-op
        /// anyway). Non-shell panes (markdown / scratchpad / diff /
        /// web) are filtered out even when they host a ghostty
        /// surface — e.g. markdown panes in `$EDITOR` mode register
        /// a surface to host vim/nano, and mirroring `/compact`-style
        /// agent prompts into that editor would be a footgun. Pushed
        /// into `SurfaceManager.setSyncGroup` by the reducer whenever
        /// `isSyncInputActive`, `syncInputExcluded`, or `panes` change.
        var syncedPaneIDs: Set<UUID> {
            guard isSyncInputActive else { return [] }
            let candidates = panes
                .lazy
                .filter { $0.type == .shell && !syncInputExcluded.contains($0.id) }
                .map(\.id)
            let result = Set(candidates)
            return result.count >= 2 ? result : []
        }

        /// The currently focused pane, if any. Used by the chrome (title
        /// bar / status bar) to surface the active pane's cwd, branch, and
        /// agent state.
        var focusedPane: Pane? {
            focusedPaneID.flatMap { panes[id: $0] }
        }

        init(
            id: UUID = UUID(),
            name: String,
            color: WorkspaceColor = .blue,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            slug = Self.makeSlug(from: name, id: id)
            self.color = color
            self.createdAt = createdAt
            lastAccessedAt = createdAt

            let paneID = UUID()
            let pane = Pane(id: paneID)
            panes = [pane]
            layout = .leaf(paneID)
            focusedPaneID = paneID
        }

        /// Restore from persisted state (no default pane creation).
        init(
            id: UUID,
            name: String,
            slug: String,
            color: WorkspaceColor,
            panes: IdentifiedArrayOf<Pane>,
            layout: PaneLayout,
            focusedPaneID: UUID?,
            repoAssociations: IdentifiedArrayOf<RepoAssociation> = [],
            createdAt: Date,
            lastAccessedAt: Date,
            labels: [String] = [],
            icon: GroupIcon? = nil,
            webPanes: [UUID: WebPaneState] = [:]
        ) {
            self.id = id
            self.name = name
            self.slug = slug
            self.color = color
            self.icon = icon
            self.panes = panes
            self.layout = layout
            self.focusedPaneID = focusedPaneID
            self.repoAssociations = repoAssociations
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
            self.labels = labels
            self.webPanes = webPanes
        }

        /// Read a pane wherever it lives — visible layout or the
        /// parked lane (sources hidden by `nex open --here`). Surface
        /// and agent lifecycle events can target parked panes; user
        /// commands (send/split/close) intentionally only look at
        /// `panes`.
        func pane(id paneID: UUID) -> Pane? {
            panes[id: paneID] ?? parkedPanes[id: paneID]
        }

        /// Mutate a pane wherever it lives (visible or parked). If the
        /// pane isn't found the closure is not invoked.
        mutating func mutatePane(id paneID: UUID, _ body: (inout Pane) -> Void) {
            if var pane = panes[id: paneID] {
                body(&pane)
                panes[id: paneID] = pane
            } else if var pane = parkedPanes[id: paneID] {
                body(&pane)
                parkedPanes[id: paneID] = pane
            }
        }

        /// Sync the pane header to reflect the currently-active web
        /// tab. Call after any change to `activeTabID` (open / close /
        /// select / cycle) so the header doesn't lag behind until the
        /// next KVO tick from the WebView. No-op when the title is
        /// already correct.
        mutating func syncWebPaneHeader(paneID: UUID) {
            guard let webState = webPanes[paneID] else { return }
            let newTitle = webState.activeTab?.displayLabel ?? "Web"
            guard panes[id: paneID]?.title != newTitle else { return }
            mutatePane(id: paneID) { $0.title = newTitle }
        }

        /// Update focused pane and push the previous focus onto
        /// `focusHistory` (deduped, capped). Use for every focus
        /// change EXCEPT pane-close: the closing pane is destroyed,
        /// not "left", and shouldn't be pushed onto its own history.
        mutating func setFocus(_ newID: UUID?) {
            if let current = focusedPaneID, current != newID {
                focusHistory.removeAll { $0 == current }
                focusHistory.append(current)
                if focusHistory.count > 8 {
                    focusHistory.removeFirst(focusHistory.count - 8)
                }
            }
            focusedPaneID = newID
        }

        /// Pop the most-recent live entry off `focusHistory`. Skips
        /// entries whose panes no longer exist. Returns nil when
        /// nothing live remains. `excluding` defends against returning
        /// the pane being closed; callers should pre-scrub too.
        mutating func popFocusFromHistory(excluding excludedID: UUID?) -> UUID? {
            if let excludedID { focusHistory.removeAll { $0 == excludedID } }
            while let candidate = focusHistory.popLast() {
                if panes[id: candidate] != nil { return candidate }
            }
            return nil
        }

        /// Generate a filesystem-safe slug from a display name.
        /// Appends a short ID suffix to guarantee uniqueness.
        static func makeSlug(from name: String, id: UUID) -> String {
            let base = name
                .lowercased()
                .replacing(/[^a-z0-9]+/, with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let suffix = id.uuidString.prefix(8).lowercased()
            return base.isEmpty ? suffix : "\(base)-\(suffix)"
        }
    }

    enum Action: Equatable {
        case rename(String)
        case setColor(WorkspaceColor)
        case addLabel(String)
        case removeLabel(String)
        case setLabels([String])
        // `newPaneID` (issue #117): when set, the new pane is created with
        // this caller-supplied UUID instead of a freshly minted one, so
        // `nex pane split` / `pane create` can return the id in their reply
        // before the pane is actually built. Defaulted to nil → all existing
        // call sites are unchanged.
        // `newPaneID` (issue #117): when set, the new pane is created with
        // this caller-supplied UUID instead of a freshly minted one, so
        // `nex pane split` / `pane create` can return the id in their reply
        // before the pane is built. `label` / `workingDirectory` let
        // `pane create` honour `--name` / `--path` when laying out the
        // first pane of an empty workspace (where there is nothing to
        // split). All defaulted to nil → existing call sites are unchanged.
        case createPane(newPaneID: UUID? = nil, label: String? = nil, workingDirectory: String? = nil)
        case splitPaneAtPath(String, label: String? = nil, direction: PaneLayout.SplitDirection = .horizontal, newPaneID: UUID? = nil)
        case splitPane(direction: PaneLayout.SplitDirection, sourcePaneID: UUID?, label: String? = nil, newPaneID: UUID? = nil)
        case closePane(UUID)
        case focusPane(UUID)
        case focusNextPane
        case focusPreviousPane
        case updateSplitRatio(splitPath: String, ratio: Double)
        case paneTitleChanged(paneID: UUID, title: String)
        case paneDirectoryChanged(paneID: UUID, directory: String)
        case paneProcessTerminated(paneID: UUID)
        case movePane(paneID: UUID, targetPaneID: UUID, zone: PaneLayout.DropZone)
        case agentStarted(paneID: UUID)
        case agentStopped(paneID: UUID)
        case agentError(paneID: UUID)
        case setPaneStatus(paneID: UUID, status: PaneStatus)
        case sessionStarted(paneID: UUID, sessionID: String)
        case sessionEnded(paneID: UUID, sessionID: String)
        case clearPaneStatus(UUID)
        case paneBranchChanged(paneID: UUID, branch: String?)
        case openMarkdownFile(filePath: String, reusePaneID: UUID? = nil)
        case openDiffPane(repoPath: String, targetPath: String?, reusePaneID: UUID? = nil)
        /// Open a web pane. Splits off the focused pane like
        /// `openDiffPane`, or replaces the focused pane (`reusePaneID`)
        /// when invoked via `nex open --here`-style flows. `isPrivate`
        /// is wired through Phase 5; Phase 1 always passes `false`.
        /// `paneID`/`tabID` are pre-allocated by the caller so the
        /// CLI reply (`nex web open`) can echo a concrete pane id
        /// before the workspace effect runs.
        case openWebPane(
            paneID: UUID,
            tabID: UUID,
            url: String,
            reusePaneID: UUID? = nil,
            isPrivate: Bool = false,
            // Pane to split off (issue #206 header button / context
            // menu). Nil → split the focused pane. `direction` picks
            // right (.horizontal) vs down (.vertical).
            sourcePaneID: UUID? = nil,
            direction: PaneLayout.SplitDirection = .horizontal
        )
        /// Tell the coordinator to navigate the active tab. The
        /// coordinator updates the WebView; the URL bar follows via
        /// the `stateDidChangeNotification` published from KVO.
        case webPaneNavigate(paneID: UUID, url: String)
        case webPaneBack(paneID: UUID)
        case webPaneForward(paneID: UUID)
        case webPaneReload(paneID: UUID, hard: Bool = false)
        /// Mirror coordinator-reported URL/title changes into state so
        /// persistence keeps a fresh URL even when the user navigates
        /// without typing in the URL bar.
        case webPaneStateChanged(paneID: UUID, tabID: UUID, url: String, title: String)
        /// Append a new tab to a web pane. `tabID` is supplied by the
        /// caller so request/response CLI replies can echo a concrete
        /// id before the effect runs.
        case webPaneTabOpen(paneID: UUID, tabID: UUID, url: String, makeActive: Bool = true)
        /// Close a tab inside a web pane. If `tabID == activeTabID`,
        /// the active selection falls back to the previous sibling
        /// (or the new first tab). Closing the last tab is rejected
        /// here — callers compose with `.closePane(paneID)` instead,
        /// matching how the priority ⌘W layer handles single-tab
        /// panes.
        case webPaneTabClose(paneID: UUID, tabID: UUID)
        case webPaneTabSelect(paneID: UUID, tabID: UUID)
        /// Cycle by signed offset. `+1` next, `-1` prev. Wraps around.
        case webPaneTabCycle(paneID: UUID, offset: Int)
        case webPaneTabReorder(paneID: UUID, orderedTabIDs: [UUID])
        /// Append a captured console line to the pane's ring buffer.
        /// Dispatched from `ContentView` when the coordinator posts a
        /// `consoleLineNotification`.
        case webConsoleLineReceived(paneID: UUID, line: ConsoleLine)
        /// Drop everything from the pane's console buffer (the
        /// `--clear` flag on `nex web console`). `seq` keeps counting.
        case webConsoleClear(paneID: UUID)
        /// Reset the pane's `droppedSinceLastDrain` counter to 0.
        /// Dispatched by `handleWebConsole` right after the reply
        /// goes out — without this, every subsequent
        /// `nex web console` call would re-report the same stale
        /// drop count.
        case webConsoleAcknowledgeDrops(paneID: UUID)
        /// Arm the picker for `paneID`, recording the destination
        /// pane id (if `--send-to` was supplied) plus the nonce the
        /// coordinator handed back. The coordinator has already
        /// asked the in-page JS to listen; this action just records
        /// the bookkeeping side so a delivered inspect-result can be
        /// routed.
        case webInspectArmedFor(paneID: UUID, sendTo: UUID?, nonce: String)
        /// Symmetric tear-down. Called when the coordinator reports a
        /// delivered click (auto-disarm) or when an explicit disarm
        /// is dispatched (tab close, target gone).
        case webInspectDisarm(paneID: UUID)
        /// A picker-captured payload arrived. Pushed onto the per-
        /// pane queue so `nex web inspect-result` can drain it.
        case webInspectResultReceived(paneID: UUID, result: InspectResult)
        /// Drop everything from the pane's inspect-result queue.
        case webInspectResultClear(paneID: UUID)
        /// Begin a batch-annotate session. Records the destination
        /// pane on `WebPaneState.batchInspect`; the AppReducer is
        /// responsible for arming the picker with `sticky: true`.
        case webBatchInspectBegin(paneID: UUID)
        case webBatchItemAdded(paneID: UUID, item: BatchInspectItem)
        case webBatchItemCommentChanged(paneID: UUID, itemID: UUID, comment: String)
        case webBatchItemRemoved(paneID: UUID, itemID: UUID)
        /// Tear down the batch session without sending. The
        /// AppReducer also disarms the sticky picker.
        case webBatchInspectCleared(paneID: UUID)
        /// Set the panel-visible flag on an active batch. The
        /// AppReducer pairs this with arming/disarming the picker and
        /// posting marker show/hide to the page. Used by the scope
        /// chrome toggle so the user can dismiss the panel without
        /// losing their pending items.
        case webBatchPanelVisible(paneID: UUID, visible: Bool)
        /// Flip / set the per-pane private flag. Pure state mutation —
        /// the AppReducer destroys the coordinator alongside so the
        /// host rebuilds tabs against the new data store.
        case webPaneSetIsPrivate(paneID: UUID, enabled: Bool)
        /// Focus an item in the active batch — used by both the
        /// list-row tap (which then highlights on page) and the
        /// page-side marker click (which then highlights the row).
        /// Pass nil to clear the focus highlight.
        case webBatchItemFocused(paneID: UUID, itemID: UUID?)
        case toggleMarkdownEdit(UUID)
        case increaseMarkdownFontSize(UUID)
        case decreaseMarkdownFontSize(UUID)
        case resetMarkdownFontSize(UUID)
        case createScratchpad
        case scratchpadContentChanged(paneID: UUID, content: String)
        case addRepoAssociation(RepoAssociation)
        case removeRepoAssociation(UUID)
        case reopenClosedPane
        case cycleLayout
        case selectLayout(PredefinedLayout)
        case movePaneInDirection(PaneLayout.Direction)
        case toggleZoomPane
        case toggleSearch
        case ghosttySearchStarted(paneID: UUID, needle: String)
        case ghosttySearchEnded(paneID: UUID)
        case searchNeedleChanged(String)
        case searchNavigateNext
        case searchNavigatePrevious
        case searchClose
        case searchTotalUpdated(paneID: UUID, total: Int)
        case searchSelectedUpdated(paneID: UUID, selected: Int)

        // Synchronise input (issue #121)
        case toggleSyncInput
        case setSyncInputActive(Bool)
        case setSyncInputExcluded(paneID: UUID, excluded: Bool)
    }

    private enum SearchDebounceID: Hashable { case debounce }

    /// Maximum label length after trimming. Generous enough for any
    /// reasonable status/tag string while preventing a multi-KB paste
    /// from blowing up row/inspector layout.
    static let maxLabelLength = 64

    /// Trim whitespace and clamp to `maxLabelLength`. Returns `""` for
    /// labels that are empty after trimming; callers should treat an
    /// empty result as "ignore".
    static func normalizeLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLabelLength { return trimmed }
        return String(trimmed.prefix(maxLabelLength))
    }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.ghosttyConfig) var ghosttyConfig
    @Dependency(\.gitService) var gitService
    @Dependency(\.editorService) var editorService
    @Dependency(\.webPaneStore) var webPaneStore
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    /// Push the workspace's current sync group to `SurfaceManager`.
    /// Cheap when sync is off (the manager clears the entry); cheap
    /// when on (a single dict assignment). Returned by any action
    /// that mutates `panes` or the sync-state fields.
    private func refreshSyncGroup(_ state: WorkspaceFeature.State) -> Effect<Action> {
        let workspaceID = state.id
        let paneIDs = state.syncedPaneIDs
        let mgr = surfaceManager
        return .run { _ in
            mgr.setSyncGroup(workspaceID: workspaceID, paneIDs: paneIDs)
        }
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .rename(let newName):
                state.name = newName
                state.slug = State.makeSlug(from: newName, id: state.id)
                return .none

            case .setColor(let color):
                state.color = color
                return .none

            case .addLabel(let raw):
                let normalized = WorkspaceFeature.normalizeLabel(raw)
                guard !normalized.isEmpty else { return .none }
                if !state.labels.contains(normalized) {
                    state.labels.append(normalized)
                }
                return .none

            case .removeLabel(let label):
                state.labels.removeAll { $0 == label }
                return .none

            case .setLabels(let raw):
                var seen = Set<String>()
                var deduped: [String] = []
                for entry in raw {
                    let normalized = WorkspaceFeature.normalizeLabel(entry)
                    guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                    deduped.append(normalized)
                }
                state.labels = deduped
                return .none

            case let .createPane(injectedID, label, workingDirectory):
                let newPaneID = injectedID ?? uuid()
                // `--path` (workingDirectory) and `--name` (label) let
                // `pane create` populate the first pane of an empty
                // workspace (issue #117); both default to nil for the
                // existing GUI/CLI callers. Resolve into `let`s so the
                // `@Sendable` effect below captures values, not a `var`.
                let resolvedDir = (workingDirectory?.isEmpty == false)
                    ? workingDirectory! : Pane(id: newPaneID).workingDirectory
                let newPane = Pane(id: newPaneID, label: label, workingDirectory: resolvedDir)
                state.panes.append(newPane)
                state.layout = .leaf(newPaneID)
                state.setFocus(newPaneID)
                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: resolvedDir,
                        backgroundOpacity: opacity
                    )
                }

            case let .splitPaneAtPath(path, label, direction, injectedID):
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }
                guard let sourceID = state.focusedPaneID else { return .none }

                let newPaneID = injectedID ?? uuid()
                let newPane = Pane(id: newPaneID, workingDirectory: path)

                let (newLayout, _) = state.layout.splitting(
                    paneID: sourceID,
                    direction: direction,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                if let label { state.panes[id: newPaneID]?.label = label }
                state.setFocus(newPaneID)
                state.currentLayoutIndex = nil

                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                }

            case let .splitPane(direction, sourcePaneID, label, injectedID):
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }
                let sourceID = sourcePaneID ?? state.focusedPaneID
                guard let sourceID else { return .none }
                guard let sourcPane = state.panes[id: sourceID] else { return .none }

                let newPaneID = injectedID ?? uuid()
                let newPane = Pane(
                    id: newPaneID,
                    workingDirectory: sourcPane.workingDirectory
                )

                let (newLayout, _) = state.layout.splitting(
                    paneID: sourceID,
                    direction: direction,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                if let label { state.panes[id: newPaneID]?.label = label }
                state.setFocus(newPaneID)
                state.currentLayoutIndex = nil

                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                }

            case .openMarkdownFile(let filePath, let reusePaneID):
                let newPaneID = uuid()
                let dir = (filePath as NSString).deletingLastPathComponent
                let fileName = (filePath as NSString).lastPathComponent
                let newPane = Pane(
                    id: newPaneID,
                    label: fileName,
                    type: .markdown,
                    title: fileName,
                    workingDirectory: dir,
                    filePath: filePath,
                    createdAt: now,
                    lastActivityAt: now
                )

                let branchEffect: Effect<Action> = .run { send in
                    let branch = try? await gitService.getCurrentBranch(dir)
                    await send(.paneBranchChanged(paneID: newPaneID, branch: branch))
                }

                if let reusePaneID, let oldPane = state.panes[id: reusePaneID] {
                    // `--here`: park the originating pane so its PTY
                    // stays alive off-layout. Closing the new markdown
                    // pane will unpark it and restore the terminal.
                    // Mirrors closePane's search/zoom cleanup.
                    if state.searchingPaneID == reusePaneID {
                        state.searchingPaneID = nil
                        state.searchNeedle = ""
                        state.searchTotal = nil
                        state.searchSelected = nil
                    }
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    var linkedPane = newPane
                    linkedPane.parkedSourcePaneID = reusePaneID
                    state.layout = state.layout.replacing(paneID: reusePaneID, with: .leaf(newPaneID))
                    state.panes.remove(id: reusePaneID)
                    state.parkedPanes.append(oldPane)
                    state.panes.append(linkedPane)
                    state.setFocus(newPaneID)
                    state.currentLayoutIndex = nil
                    return branchEffect
                }

                if let sourceID = state.focusedPaneID {
                    let (newLayout, _) = state.layout.splitting(
                        paneID: sourceID,
                        direction: .horizontal,
                        newPaneID: newPaneID
                    )
                    state.layout = newLayout
                } else {
                    state.layout = .leaf(newPaneID)
                }
                state.panes.append(newPane)
                state.setFocus(newPaneID)
                state.currentLayoutIndex = nil
                return branchEffect

            case .openDiffPane(let repoPath, let targetPath, let reusePaneID):
                let newPaneID = uuid()
                let scopeName: String = if let targetPath, !targetPath.isEmpty {
                    (targetPath as NSString).lastPathComponent
                } else {
                    (repoPath as NSString).lastPathComponent
                }
                let newPane = Pane(
                    id: newPaneID,
                    label: scopeName,
                    type: .diff,
                    title: "diff: \(scopeName)",
                    workingDirectory: repoPath,
                    filePath: targetPath,
                    createdAt: now,
                    lastActivityAt: now
                )

                let branchEffect: Effect<Action> = .run { send in
                    let branch = try? await gitService.getCurrentBranch(repoPath)
                    await send(.paneBranchChanged(paneID: newPaneID, branch: branch))
                }

                if let reusePaneID, let oldPane = state.panes[id: reusePaneID] {
                    if state.searchingPaneID == reusePaneID {
                        state.searchingPaneID = nil
                        state.searchNeedle = ""
                        state.searchTotal = nil
                        state.searchSelected = nil
                    }
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    var linkedPane = newPane
                    linkedPane.parkedSourcePaneID = reusePaneID
                    state.layout = state.layout.replacing(paneID: reusePaneID, with: .leaf(newPaneID))
                    state.panes.remove(id: reusePaneID)
                    state.parkedPanes.append(oldPane)
                    state.panes.append(linkedPane)
                    state.setFocus(newPaneID)
                    state.currentLayoutIndex = nil
                    return branchEffect
                }

                if let sourceID = state.focusedPaneID {
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    let (newLayout, _) = state.layout.splitting(
                        paneID: sourceID,
                        direction: .horizontal,
                        newPaneID: newPaneID
                    )
                    state.layout = newLayout
                } else {
                    state.layout = .leaf(newPaneID)
                }
                state.panes.append(newPane)
                state.setFocus(newPaneID)
                state.currentLayoutIndex = nil
                return branchEffect

            case .openWebPane(let newPaneID, let tabID, let url, let reusePaneID, let isPrivate, let sourcePaneID, let direction):
                let normalized = WebPaneCoordinator.normalizeURLInput(url)
                let tab = WebTab(id: tabID, url: normalized)
                let newPane = Pane(
                    id: newPaneID,
                    type: .web,
                    title: "Web",
                    workingDirectory: NSHomeDirectory(),
                    createdAt: now,
                    lastActivityAt: now
                )

                state.webPanes[newPaneID] = WebPaneState(
                    tabs: [tab],
                    activeTabID: tab.id,
                    isPrivate: isPrivate
                )

                if let reusePaneID, let oldPane = state.panes[id: reusePaneID] {
                    if state.searchingPaneID == reusePaneID {
                        state.searchingPaneID = nil
                        state.searchNeedle = ""
                        state.searchTotal = nil
                        state.searchSelected = nil
                    }
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    var linkedPane = newPane
                    linkedPane.parkedSourcePaneID = reusePaneID
                    state.layout = state.layout.replacing(paneID: reusePaneID, with: .leaf(newPaneID))
                    state.panes.remove(id: reusePaneID)
                    state.parkedPanes.append(oldPane)
                    state.panes.append(linkedPane)
                    state.setFocus(newPaneID)
                    state.currentLayoutIndex = nil
                    return .none
                }

                // Split off the caller-supplied pane (header button /
                // context menu, issue #206) when given, else the focused
                // pane; `direction` picks right vs down.
                if let sourceID = sourcePaneID ?? state.focusedPaneID {
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    let (newLayout, _) = state.layout.splitting(
                        paneID: sourceID,
                        direction: direction,
                        newPaneID: newPaneID
                    )
                    state.layout = newLayout
                } else {
                    state.layout = .leaf(newPaneID)
                }
                state.panes.append(newPane)
                state.setFocus(newPaneID)
                state.currentLayoutIndex = nil
                return .none

            case .webPaneNavigate(let paneID, let url):
                guard let webState = state.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let normalized = WebPaneCoordinator.normalizeURLInput(url)
                // Mirror into state so a save right now persists the
                // intended URL even before the coordinator's KVO
                // notification round-trips.
                if var ws = state.webPanes[paneID] {
                    if let idx = ws.tabs.firstIndex(where: { $0.id == tab.id }) {
                        ws.tabs[idx].url = normalized
                    }
                    state.webPanes[paneID] = ws
                }
                let store = webPaneStore
                let isPrivate = state.webPanes[paneID]?.isPrivate ?? false
                return .run { _ in
                    await MainActor.run {
                        let coord = store.coordinator(for: paneID, isPrivate: isPrivate)
                        _ = coord.navigate(tab: tab, to: normalized)
                    }
                }

            case .webPaneBack(let paneID):
                guard let webState = state.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let isPrivate = webState.isPrivate
                return .run { _ in
                    await MainActor.run {
                        _ = store.coordinator(for: paneID, isPrivate: isPrivate).goBack(tabID: tab.id)
                    }
                }

            case .webPaneForward(let paneID):
                guard let webState = state.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let isPrivate = webState.isPrivate
                return .run { _ in
                    await MainActor.run {
                        _ = store.coordinator(for: paneID, isPrivate: isPrivate).goForward(tabID: tab.id)
                    }
                }

            case .webPaneReload(let paneID, let hard):
                guard let webState = state.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let isPrivate = webState.isPrivate
                return .run { _ in
                    await MainActor.run {
                        _ = store.coordinator(for: paneID, isPrivate: isPrivate).reload(tabID: tab.id, hard: hard)
                    }
                }

            case .webPaneStateChanged(let paneID, let tabID, let url, let title):
                guard var webState = state.webPanes[paneID] else { return .none }
                guard let idx = webState.index(of: tabID) else { return .none }
                // Only overwrite the URL when the coordinator reports
                // something meaningful. about:blank shows up early in
                // a load and again on WKWebView's revert after a
                // failed navigation; both would wipe the URL bar.
                let isPlaceholder = url.isEmpty || url == "about:blank"
                let newURL = isPlaceholder ? webState.tabs[idx].url : url
                guard webState.tabs[idx].url != newURL || webState.tabs[idx].title != title else {
                    return .none
                }
                webState.tabs[idx].url = newURL
                webState.tabs[idx].title = title
                state.webPanes[paneID] = webState
                // Only echo to the pane header when this tab is the
                // resolved active one. webState.activeTab falls back to
                // tabs.first when activeTabID is stale, so this
                // matches what the UI is actually showing.
                if !title.isEmpty,
                   tabID == webState.activeTab?.id,
                   state.panes[id: paneID]?.title != title {
                    state.mutatePane(id: paneID) { $0.title = title }
                }
                return .none

            case .webPaneTabOpen(let paneID, let tabID, let url, let makeActive):
                guard var webState = state.webPanes[paneID] else { return .none }
                // Caller is responsible for allocating fresh UUIDs.
                guard !webState.contains(tabID: tabID) else { return .none }
                let normalized = WebPaneCoordinator.normalizeURLInput(url)
                webState.tabs.append(WebTab(id: tabID, url: normalized))
                if makeActive {
                    webState.activeTabID = tabID
                }
                state.webPanes[paneID] = webState
                if makeActive {
                    state.syncWebPaneHeader(paneID: paneID)
                }
                return .none

            case .webPaneTabClose(let paneID, let tabID):
                guard var webState = state.webPanes[paneID] else { return .none }
                guard webState.tabs.count > 1 else {
                    // Single-tab close = pane close. Use the proper
                    // closePane flow so the workspace cleanup (focus
                    // history, layout removal, coordinator teardown)
                    // happens. Callers that want different behaviour
                    // should compose explicitly.
                    return .send(.closePane(paneID))
                }
                guard let idx = webState.index(of: tabID) else { return .none }
                let wasActive = webState.activeTabID == tabID
                webState.tabs.remove(at: idx)
                if wasActive {
                    // Prefer the left neighbour of the closed tab;
                    // fall back to the new first when idx was 0.
                    let fallbackIdx = max(idx - 1, 0)
                    webState.activeTabID = webState.tabs[fallbackIdx].id
                }
                state.webPanes[paneID] = webState
                if wasActive {
                    state.syncWebPaneHeader(paneID: paneID)
                }
                let store = webPaneStore
                return .run { _ in
                    await store.destroyTab(paneID: paneID, tabID: tabID)
                }

            case .webPaneTabSelect(let paneID, let tabID):
                guard var webState = state.webPanes[paneID] else { return .none }
                guard webState.contains(tabID: tabID) else { return .none }
                guard webState.activeTabID != tabID else { return .none }
                webState.activeTabID = tabID
                state.webPanes[paneID] = webState
                state.syncWebPaneHeader(paneID: paneID)
                return .none

            case .webPaneTabCycle(let paneID, let offset):
                guard var webState = state.webPanes[paneID], webState.tabs.count > 1 else { return .none }
                let activeID = webState.activeTabID ?? webState.tabs.first?.id
                guard let activeID, let currentIdx = webState.index(of: activeID) else { return .none }
                let count = webState.tabs.count
                let nextIdx = ((currentIdx + offset) % count + count) % count
                webState.activeTabID = webState.tabs[nextIdx].id
                state.webPanes[paneID] = webState
                state.syncWebPaneHeader(paneID: paneID)
                return .none

            case .webPaneTabReorder(let paneID, let orderedTabIDs):
                guard var webState = state.webPanes[paneID] else { return .none }
                let currentOrder = webState.tabs.map(\.id)
                guard orderedTabIDs != currentOrder else { return .none }
                // Only reorder if the new sequence is a permutation
                // of the existing tab ids. Drop the action otherwise
                // rather than silently truncating / dropping tabs.
                guard Set(orderedTabIDs) == Set(currentOrder),
                      orderedTabIDs.count == webState.tabs.count else { return .none }
                webState.tabs = orderedTabIDs.compactMap { id in webState.tabs.first(where: { $0.id == id }) }
                state.webPanes[paneID] = webState
                return .none

            case .webConsoleLineReceived(let paneID, let line):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.consoleBuffer.append(line)
                state.webPanes[paneID] = webState
                return .none

            case .webConsoleClear(let paneID):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.consoleBuffer.clear()
                state.webPanes[paneID] = webState
                return .none

            case .webConsoleAcknowledgeDrops(let paneID):
                guard var webState = state.webPanes[paneID] else { return .none }
                _ = webState.consoleBuffer.acknowledgeDrops()
                state.webPanes[paneID] = webState
                return .none

            case .webInspectArmedFor(let paneID, let sendTo, let nonce):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.inspectorArmed = true
                webState.pendingInspectSendTo = sendTo
                webState.pendingInspectNonce = nonce
                state.webPanes[paneID] = webState
                return .none

            case .webInspectDisarm(let paneID):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.inspectorArmed = false
                webState.pendingInspectSendTo = nil
                webState.pendingInspectNonce = nil
                state.webPanes[paneID] = webState
                return .none

            case .webInspectResultReceived(let paneID, let result):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.inspectResultQueue.append(result)
                // Cap the queue. 32 entries is generous for the
                // interactive workflow — agents that don't drain
                // quickly should use `--clear` on `nex web inspect-result`.
                if webState.inspectResultQueue.count > 32 {
                    webState.inspectResultQueue.removeFirst(
                        webState.inspectResultQueue.count - 32
                    )
                }
                state.webPanes[paneID] = webState
                return .none

            case .webInspectResultClear(let paneID):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.inspectResultQueue.removeAll()
                state.webPanes[paneID] = webState
                return .none

            case .webBatchInspectBegin(let paneID):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.batchInspect = BatchInspectState(items: [])
                state.webPanes[paneID] = webState
                return .none

            case .webBatchItemAdded(let paneID, let item):
                guard var webState = state.webPanes[paneID],
                      webState.batchInspect != nil else { return .none }
                webState.batchInspect?.items.append(item)
                state.webPanes[paneID] = webState
                return .none

            case .webBatchItemCommentChanged(let paneID, let itemID, let comment):
                guard var webState = state.webPanes[paneID],
                      var batch = webState.batchInspect,
                      let idx = batch.items.firstIndex(where: { $0.id == itemID })
                else { return .none }
                batch.items[idx].comment = comment
                webState.batchInspect = batch
                state.webPanes[paneID] = webState
                return .none

            case .webBatchItemRemoved(let paneID, let itemID):
                guard var webState = state.webPanes[paneID],
                      webState.batchInspect != nil else { return .none }
                webState.batchInspect?.items.removeAll { $0.id == itemID }
                state.webPanes[paneID] = webState
                return .none

            case .webBatchInspectCleared(let paneID):
                guard var webState = state.webPanes[paneID] else { return .none }
                webState.batchInspect = nil
                state.webPanes[paneID] = webState
                return .none

            case .webBatchPanelVisible(let paneID, let visible):
                guard var webState = state.webPanes[paneID],
                      let batch = webState.batchInspect,
                      batch.panelVisible != visible else { return .none }
                webState.batchInspect?.panelVisible = visible
                state.webPanes[paneID] = webState
                return .none

            case .webPaneSetIsPrivate(let paneID, let enabled):
                guard var webState = state.webPanes[paneID],
                      webState.isPrivate != enabled else { return .none }
                webState.isPrivate = enabled
                state.webPanes[paneID] = webState
                return .none

            case .webBatchItemFocused(let paneID, let itemID):
                guard var webState = state.webPanes[paneID],
                      webState.batchInspect != nil else { return .none }
                webState.batchInspect?.focusedItemID = itemID
                state.webPanes[paneID] = webState
                return .none

            case .createScratchpad:
                let newPaneID = uuid()
                let newPane = Pane(
                    id: newPaneID,
                    type: .scratchpad,
                    title: "Scratchpad",
                    isEditing: true,
                    createdAt: now,
                    lastActivityAt: now
                )

                if let sourceID = state.focusedPaneID {
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    let (newLayout, _) = state.layout.splitting(
                        paneID: sourceID,
                        direction: .horizontal,
                        newPaneID: newPaneID
                    )
                    state.layout = newLayout
                } else {
                    state.layout = .leaf(newPaneID)
                }
                state.panes.append(newPane)
                state.setFocus(newPaneID)
                state.currentLayoutIndex = nil
                return .none

            case .scratchpadContentChanged(let paneID, let content):
                state.panes[id: paneID]?.scratchpadContent = content
                return .none

            case .closePane(let paneID):
                // Dismiss search if the pane being closed is the one being searched
                if state.searchingPaneID == paneID {
                    state.searchingPaneID = nil
                    state.searchNeedle = ""
                    state.searchTotal = nil
                    state.searchSelected = nil
                }
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }

                // Unpark: if the closing pane was created via `nex open
                // --here` and its source is still parked, restore the
                // source terminal instead of closing. The markdown
                // pane's own surface (if it entered external-editor
                // mode) still needs torn down.
                if let closingPane = state.panes[id: paneID],
                   let sourceID = closingPane.parkedSourcePaneID,
                   let parkedPane = state.parkedPanes[id: sourceID] {
                    let markdownHasSurface = closingPane.type == .markdown
                        && closingPane.isUsingExternalEditor
                    state.parkedPanes.remove(id: sourceID)
                    state.panes.remove(id: paneID)
                    state.panes.append(parkedPane)
                    state.layout = state.layout.replacing(
                        paneID: paneID, with: .leaf(sourceID)
                    )
                    // Direct assignment (not setFocus): the closing
                    // pane is destroyed in the same tick, so it must
                    // not be pushed onto its own history. Scrub stale
                    // entries for both the closing pane and the
                    // unparked source defensively.
                    state.focusHistory.removeAll { $0 == paneID || $0 == sourceID }
                    state.focusedPaneID = sourceID
                    state.currentLayoutIndex = nil
                    if markdownHasSurface {
                        return .run { _ in
                            await surfaceManager.destroySurface(paneID: paneID)
                        }
                    }
                    return .none
                }

                let paneType = state.panes[id: paneID]?.type ?? .shell
                // A markdown pane hosts a ghostty surface only while editing
                // via an external editor. We must destroy that surface on
                // close too or the PTY and editor process leak behind the
                // scenes, alongside stale SurfaceManager bookkeeping.
                let hasBackingSurface = paneType == .shell
                    || (state.panes[id: paneID]?.isUsingExternalEditor ?? false)
                let isWebPane = paneType == .web
                if let pane = state.panes[id: paneID] {
                    // For web panes the sidecar holds the URL — capture
                    // it into the snapshot so `reopenClosedPane` can
                    // rebuild the same tab list. Private panes get a
                    // nil webState so reopen restores a blank tab.
                    let snapshotWebState: WebPaneState? = {
                        guard pane.type == .web,
                              let ws = state.webPanes[paneID],
                              !ws.isPrivate
                        else { return nil }
                        return ws
                    }()
                    state.recentlyClosedPanes.append(
                        ClosedPaneSnapshot(
                            workingDirectory: pane.workingDirectory,
                            label: pane.label,
                            type: pane.type,
                            filePath: pane.filePath,
                            scratchpadContent: pane.scratchpadContent,
                            agentSessionID: pane.agentSessionID,
                            markdownFontSize: pane.markdownFontSize,
                            webState: snapshotWebState
                        )
                    )
                    if state.recentlyClosedPanes.count > 10 {
                        state.recentlyClosedPanes.removeFirst()
                    }
                }
                if isWebPane {
                    state.webPanes.removeValue(forKey: paneID)
                }
                state.panes.remove(id: paneID)
                let newLayout = state.layout.removing(paneID: paneID)
                state.layout = newLayout
                state.currentLayoutIndex = nil

                // Scrub the closing pane from history before any pop,
                // even if it wasn't focused: leaving stale UUIDs in
                // the stack works (popFocusFromHistory filters dead
                // panes) but burns slots and obscures intent.
                state.focusHistory.removeAll { $0 == paneID }

                // Update focus. Direct assignment (not setFocus): the
                // closing pane should not be pushed onto its own
                // history. Walk the per-session focus stack first;
                // fall back to layout-traversal order if it's empty.
                if state.focusedPaneID == paneID {
                    state.focusedPaneID = state.popFocusFromHistory(excluding: paneID)
                        ?? newLayout.allPaneIDs.first
                }

                if hasBackingSurface {
                    let store = webPaneStore
                    if isWebPane {
                        // Defensive — web panes never set hasBackingSurface
                        // today, but if that ever changes the destroy
                        // still has to run on the main actor.
                        return .run { _ in
                            await surfaceManager.destroySurface(paneID: paneID)
                            await store.destroyCoordinator(paneID: paneID)
                        }
                    }
                    return .run { _ in
                        await surfaceManager.destroySurface(paneID: paneID)
                    }
                }
                if isWebPane {
                    let store = webPaneStore
                    return .run { _ in
                        await store.destroyCoordinator(paneID: paneID)
                    }
                }
                return .none

            case .focusPane(let paneID):
                state.setFocus(paneID)
                return .none

            case .focusNextPane:
                guard let current = state.focusedPaneID,
                      let next = state.layout.nextPaneID(after: current) else { return .none }
                state.setFocus(next)
                return .none

            case .focusPreviousPane:
                guard let current = state.focusedPaneID,
                      let prev = state.layout.previousPaneID(before: current) else { return .none }
                state.setFocus(prev)
                return .none

            case .updateSplitRatio(let splitPath, let ratio):
                state.layout = state.layout.updatingSplitRatio(
                    atPath: splitPath,
                    to: ratio
                )
                state.currentLayoutIndex = nil
                return .none

            case .paneTitleChanged(let paneID, let title):
                let timestamp = now
                state.mutatePane(id: paneID) {
                    $0.title = title
                    $0.lastActivityAt = timestamp
                }
                return .none

            case .paneDirectoryChanged(let paneID, let directory):
                let timestamp = now
                state.mutatePane(id: paneID) {
                    $0.workingDirectory = directory
                    $0.lastActivityAt = timestamp
                }
                return .run { send in
                    let branch = try? await gitService.getCurrentBranch(directory)
                    await send(.paneBranchChanged(paneID: paneID, branch: branch))
                }

            case .paneProcessTerminated(let paneID):
                // If a parked pane's process died (SIGHUP, etc.), evict
                // it from the parked lane and clear references from
                // any markdown panes that were going to restore it.
                // The standard closePane path would be a no-op here
                // (parked panes aren't in state.panes or state.layout).
                if state.parkedPanes[id: paneID] != nil {
                    state.parkedPanes.remove(id: paneID)
                    for pane in state.panes where pane.parkedSourcePaneID == paneID {
                        state.panes[id: pane.id]?.parkedSourcePaneID = nil
                    }
                    return .run { _ in
                        await surfaceManager.destroySurface(paneID: paneID)
                    }
                }
                // If this was a markdown pane whose external editor just exited,
                // flip back to view mode instead of closing the pane. The
                // MarkdownPaneView file watcher will reload any on-disk changes.
                if let pane = state.panes[id: paneID],
                   pane.type == .markdown,
                   pane.isUsingExternalEditor {
                    state.panes[id: paneID]?.isEditing = false
                    state.panes[id: paneID]?.externalEditorCommand = nil
                    return .run { _ in
                        await surfaceManager.destroySurface(paneID: paneID)
                    }
                }
                // Close the pane when its shell exits
                return .send(.closePane(paneID))

            case .movePane(let paneID, let targetPaneID, let zone):
                guard state.panes[id: paneID] != nil,
                      state.panes[id: targetPaneID] != nil else { return .none }
                state.layout = state.layout.movingPane(
                    paneID, toAdjacentOf: targetPaneID, zone: zone
                )
                state.setFocus(paneID)
                state.currentLayoutIndex = nil
                return .none

            case .movePaneInDirection(let direction):
                guard state.zoomedPaneID == nil else { return .none }
                guard let focusedID = state.focusedPaneID else { return .none }
                guard let neighborID = state.layout.neighborPaneID(
                    of: focusedID, inDirection: direction
                ) else { return .none }
                state.layout = state.layout.swappingLeaves(focusedID, neighborID)
                state.currentLayoutIndex = nil
                return .none

            case .agentStarted(let paneID):
                state.mutatePane(id: paneID) {
                    // Start the elapsed clock only on a fresh run (a
                    // non-running → running transition) so repeated start
                    // pings within one run don't reset "claude · mm:ss".
                    if $0.status != .running { $0.agentStartedAt = now }
                    $0.status = .running
                }
                return .none

            case .agentStopped(let paneID):
                state.mutatePane(id: paneID) { $0.status = .waitingForInput }
                return .none

            case .agentError(let paneID):
                state.mutatePane(id: paneID) { $0.status = .waitingForInput }
                return .none

            case .setPaneStatus(let paneID, let status):
                // Manual status override from the pane context menu. Guard to
                // shell panes (defense-in-depth — the menu is already
                // shell-only, mirroring .toggleMarkdownEdit's type guard);
                // status is a shell-only concept. Mirror .agentStarted: start
                // the elapsed clock on a fresh transition into .running so the
                // "claude · mm:ss" badge ticks from now.
                guard state.pane(id: paneID)?.type == .shell else { return .none }
                state.mutatePane(id: paneID) {
                    if status == .running, $0.status != .running {
                        $0.agentStartedAt = now
                    }
                    $0.status = status
                }
                return .none

            case .sessionStarted(let paneID, let sessionID):
                state.mutatePane(id: paneID) { $0.agentSessionID = sessionID }
                return .none

            case .sessionEnded(let paneID, let sessionID):
                // The agent session exited (SessionEnd hook). Drop the
                // tracked id so it isn't resumed on next launch or via
                // reopen-closed-pane (issue #178). Only clear when the
                // ending id still matches what we hold: `/clear` and
                // compact fire SessionEnd(old) alongside SessionStart(new),
                // and the messages can arrive in either order — the match
                // guard keeps the live session tracked regardless.
                state.mutatePane(id: paneID) {
                    if $0.agentSessionID == sessionID { $0.agentSessionID = nil }
                }
                return .none

            case .clearPaneStatus(let paneID):
                // Only clear waitingForInput — don't clobber .running if the agent
                // already started again before the 600ms focus timer fired.
                if state.pane(id: paneID)?.status == .waitingForInput {
                    state.mutatePane(id: paneID) { $0.status = .idle }
                }
                return .none

            case .paneBranchChanged(let paneID, let branch):
                state.mutatePane(id: paneID) { $0.gitBranch = branch }
                return .none

            case .toggleMarkdownEdit(let paneID):
                guard let pane = state.panes[id: paneID], pane.type == .markdown else {
                    return .none
                }

                if pane.isEditing {
                    let wasExternal = pane.isUsingExternalEditor
                    state.panes[id: paneID]?.isEditing = false
                    state.panes[id: paneID]?.externalEditorCommand = nil
                    if wasExternal {
                        return .run { _ in
                            await surfaceManager.destroySurface(paneID: paneID)
                        }
                    }
                    return .none
                }

                // Entering edit mode: dismiss any active find on this pane.
                // The MarkdownPaneView is about to be replaced by the editor,
                // so the overlay would otherwise float over a non-functional
                // host (no coordinator → typed needles silently no-op).
                let wasSearching = state.searchingPaneID == paneID
                if wasSearching {
                    state.searchingPaneID = nil
                    state.searchNeedle = ""
                    state.searchTotal = nil
                    state.searchSelected = nil
                }

                // If we can resolve the user's $EDITOR, host it inside a
                // ghostty surface bound to this pane; otherwise fall back to
                // the built-in NSTextView editor.
                if let filePath = pane.filePath,
                   let command = editorService.buildCommand(filePath) {
                    state.panes[id: paneID]?.isEditing = true
                    state.panes[id: paneID]?.externalEditorCommand = command
                    let opacity = ghosttyConfig.backgroundOpacity
                    let cwd = pane.workingDirectory
                    return .run { _ in
                        if wasSearching {
                            await MainActor.run {
                                MarkdownFindController.shared.close(paneID: paneID)
                            }
                        }
                        await surfaceManager.createSurface(
                            paneID: paneID,
                            workingDirectory: cwd,
                            backgroundOpacity: opacity,
                            command: command
                        )
                    }
                }

                state.panes[id: paneID]?.isEditing = true
                state.panes[id: paneID]?.externalEditorCommand = nil
                if wasSearching {
                    return .run { _ in
                        await MainActor.run {
                            MarkdownFindController.shared.close(paneID: paneID)
                        }
                    }
                }
                return .none

            case .increaseMarkdownFontSize(let paneID):
                guard let pane = state.panes[id: paneID],
                      pane.type == .markdown,
                      !pane.isEditing
                else { return .none }
                let next = min(pane.markdownFontSize + 1, 32)
                state.panes[id: paneID]?.markdownFontSize = next
                return .none

            case .decreaseMarkdownFontSize(let paneID):
                guard let pane = state.panes[id: paneID],
                      pane.type == .markdown,
                      !pane.isEditing
                else { return .none }
                let next = max(pane.markdownFontSize - 1, 8)
                state.panes[id: paneID]?.markdownFontSize = next
                return .none

            case .resetMarkdownFontSize(let paneID):
                guard state.panes[id: paneID]?.type == .markdown,
                      state.panes[id: paneID]?.isEditing == false
                else { return .none }
                state.panes[id: paneID]?.markdownFontSize = Pane.defaultMarkdownFontSize
                return .none

            case .addRepoAssociation(let assoc):
                state.repoAssociations.append(assoc)
                return .none

            case .removeRepoAssociation(let id):
                state.repoAssociations.remove(id: id)
                return .none

            case .cycleLayout:
                guard state.panes.count > 1 else { return .none }

                // Un-zoom if zoomed
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }

                let layouts = PredefinedLayout.allCases
                let nextIndex = if let current = state.currentLayoutIndex {
                    (current + 1) % layouts.count
                } else {
                    0
                }

                // Reorder so focused pane is first (becomes "main" in main-* layouts)
                let currentIDs = state.layout.allPaneIDs
                var reordered = currentIDs
                if let focusedID = state.focusedPaneID,
                   let idx = reordered.firstIndex(of: focusedID), idx != 0 {
                    reordered.remove(at: idx)
                    reordered.insert(focusedID, at: 0)
                }

                state.layout = layouts[nextIndex].buildLayout(for: reordered)
                state.currentLayoutIndex = nextIndex
                return .none

            case .selectLayout(let predefinedLayout):
                guard state.panes.count > 1 else { return .none }

                // Un-zoom if zoomed
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }

                let layouts = PredefinedLayout.allCases
                guard let index = layouts.firstIndex(of: predefinedLayout) else { return .none }

                let currentIDs = state.layout.allPaneIDs
                var reordered = currentIDs
                if let focusedID = state.focusedPaneID,
                   let idx = reordered.firstIndex(of: focusedID), idx != 0 {
                    reordered.remove(at: idx)
                    reordered.insert(focusedID, at: 0)
                }

                state.layout = predefinedLayout.buildLayout(for: reordered)
                state.currentLayoutIndex = index
                return .none

            case .toggleZoomPane:
                if state.zoomedPaneID != nil {
                    // Un-zoom: restore saved layout
                    if let saved = state.savedLayout {
                        state.layout = saved
                    }
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                } else if let focusedID = state.focusedPaneID,
                          state.panes.count > 1 {
                    // Zoom: save layout and show only focused pane
                    state.savedLayout = state.layout
                    state.zoomedPaneID = focusedID
                    state.layout = .leaf(focusedID)
                }
                return .none

            case .toggleSearch:
                guard let focusedID = state.focusedPaneID,
                      let pane = state.panes[id: focusedID],
                      pane.type == .shell || (pane.type == .markdown && !pane.isEditing)
                else { return .none }
                if state.searchingPaneID != nil {
                    return .send(.searchClose)
                }
                state.searchingPaneID = focusedID
                state.searchNeedle = ""
                state.searchTotal = nil
                state.searchSelected = nil
                return .none

            case .ghosttySearchStarted(let paneID, let needle):
                guard state.panes[id: paneID]?.type == .shell else { return .none }
                state.searchingPaneID = paneID
                state.searchNeedle = needle
                state.searchTotal = nil
                state.searchSelected = nil
                return .none

            case .ghosttySearchEnded(let paneID):
                guard state.searchingPaneID == paneID else { return .none }
                state.searchingPaneID = nil
                state.searchNeedle = ""
                state.searchTotal = nil
                state.searchSelected = nil
                return .none

            case .searchNeedleChanged(let needle):
                state.searchNeedle = needle
                state.searchSelected = nil
                guard let paneID = state.searchingPaneID else { return .none }
                let isMarkdown = state.panes[id: paneID]?.type == .markdown
                if isMarkdown {
                    // WKWebView find runs locally in JS; no backend round-trip
                    // to debounce. Drive it directly so typing feels responsive.
                    return .run { _ in
                        await MainActor.run {
                            MarkdownFindController.shared.update(paneID: paneID, needle: needle)
                        }
                    }
                    .cancellable(id: SearchDebounceID.debounce, cancelInFlight: true)
                }
                let mgr = surfaceManager
                if needle.isEmpty {
                    return .run { _ in
                        await mgr.performBindingAction(on: paneID, action: "search:")
                    }
                }
                // Debounce short queries to avoid expensive partial searches
                if needle.count < 3 {
                    return .run { _ in
                        try await Task.sleep(for: .milliseconds(300))
                        await mgr.performBindingAction(on: paneID, action: "search:\(needle)")
                    }
                    .cancellable(id: SearchDebounceID.debounce, cancelInFlight: true)
                }
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "search:\(needle)")
                }
                .cancellable(id: SearchDebounceID.debounce, cancelInFlight: true)

            case .searchNavigateNext:
                guard let paneID = state.searchingPaneID else { return .none }
                if state.panes[id: paneID]?.type == .markdown {
                    return .run { _ in
                        await MainActor.run {
                            MarkdownFindController.shared.navigateNext(paneID: paneID)
                        }
                    }
                }
                let mgr = surfaceManager
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "navigate_search:next")
                }

            case .searchNavigatePrevious:
                guard let paneID = state.searchingPaneID else { return .none }
                if state.panes[id: paneID]?.type == .markdown {
                    return .run { _ in
                        await MainActor.run {
                            MarkdownFindController.shared.navigatePrevious(paneID: paneID)
                        }
                    }
                }
                let mgr = surfaceManager
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "navigate_search:previous")
                }

            case .searchClose:
                guard let paneID = state.searchingPaneID else { return .none }
                let isMarkdown = state.panes[id: paneID]?.type == .markdown
                state.searchingPaneID = nil
                state.searchNeedle = ""
                state.searchTotal = nil
                state.searchSelected = nil
                if isMarkdown {
                    return .run { _ in
                        await MainActor.run {
                            MarkdownFindController.shared.close(paneID: paneID)
                        }
                    }
                }
                let mgr = surfaceManager
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "end_search")
                }

            case .searchTotalUpdated(let paneID, let total):
                guard state.searchingPaneID == paneID else { return .none }
                state.searchTotal = total
                // Drop any stale selection when matches go to zero (e.g.
                // a markdown live-reload turns a doc with hits into one
                // without). Otherwise the overlay would render a count
                // like "3/0".
                if total == 0 { state.searchSelected = nil }
                return .none

            case .searchSelectedUpdated(let paneID, let selected):
                guard state.searchingPaneID == paneID else { return .none }
                state.searchSelected = selected
                return .none

            case .toggleSyncInput:
                state.isSyncInputActive.toggle()
                // Clear on every transition so re-enabling sync always
                // starts from a fresh "all panes participate" baseline.
                // Clearing on toggle-off alone would let a pre-staged
                // `pane sync exclude` (run while sync was off) survive
                // into the next on-cycle and silently exclude a pane.
                state.syncInputExcluded.removeAll()
                return refreshSyncGroup(state)

            case .setSyncInputActive(let active):
                guard state.isSyncInputActive != active else { return .none }
                state.isSyncInputActive = active
                state.syncInputExcluded.removeAll()
                return refreshSyncGroup(state)

            case .setSyncInputExcluded(let paneID, let excluded):
                guard state.panes[id: paneID] != nil else { return .none }
                if excluded {
                    state.syncInputExcluded.insert(paneID)
                } else {
                    state.syncInputExcluded.remove(paneID)
                }
                return refreshSyncGroup(state)

            case .reopenClosedPane:
                guard let snapshot = state.recentlyClosedPanes.popLast() else { return .none }
                guard let focusedID = state.focusedPaneID else { return .none }

                let newPaneID = uuid()
                let newPane = Pane(
                    id: newPaneID,
                    label: snapshot.label,
                    type: snapshot.type,
                    workingDirectory: snapshot.workingDirectory,
                    filePath: snapshot.filePath,
                    isEditing: snapshot.type == .scratchpad,
                    scratchpadContent: snapshot.scratchpadContent,
                    markdownFontSize: snapshot.markdownFontSize
                )

                let (newLayout, _) = state.layout.splitting(
                    paneID: focusedID,
                    direction: .horizontal,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                if snapshot.type == .web, let webState = snapshot.webState {
                    state.webPanes[newPaneID] = webState
                }
                state.setFocus(newPaneID)
                state.currentLayoutIndex = nil

                // Non-shell pane types don't need a ghostty surface
                if snapshot.type == .markdown || snapshot.type == .scratchpad
                    || snapshot.type == .diff || snapshot.type == .web {
                    return .none
                }

                let opacity = ghosttyConfig.backgroundOpacity
                let sessionID = snapshot.agentSessionID
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                    if let sessionID {
                        try? await Task.sleep(for: .seconds(2))
                        await surfaceManager.sendCommand(
                            to: newPaneID,
                            command: "claude --resume \(sessionID)"
                        )
                    }
                }
            }
        }
        // Sync-input bookkeeping (issue #121). When sync is active for
        // this workspace and an action mutated the pane set, push the
        // updated group to `SurfaceManager` so brand-new panes join
        // and closed panes drop out without the caller having to
        // remember. The explicit sync-toggle actions already refresh
        // synchronously, so they're filtered out here.
        Reduce { state, action in
            guard state.isSyncInputActive else { return .none }
            switch action {
            case .createPane, .splitPane, .splitPaneAtPath, .closePane,
                 .openMarkdownFile, .openDiffPane, .openWebPane,
                 .createScratchpad, .reopenClosedPane,
                 .paneProcessTerminated:
                return refreshSyncGroup(state)
            default:
                return .none
            }
        }
    }
}

extension IdentifiedArrayOf where Element == WorkspaceFeature.State {
    /// Returns a random `WorkspaceColor` for a newly created workspace, avoiding
    /// the colour of the trailing workspace so an appended workspace is visually
    /// distinct from its neighbour in the sidebar. See benfriebe/nex#26.
    func nextRandomColor() -> WorkspaceColor {
        let excluded = last?.color
        return WorkspaceColor.allCases
            .filter { $0 != excluded }
            .randomElement() ?? .blue
    }
}
