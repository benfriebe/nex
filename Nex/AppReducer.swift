import AppKit
import ComposableArchitecture
import Foundation

@Reducer
struct AppReducer {
    @ObservableState
    struct State: Equatable {
        var workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = []
        var groups: IdentifiedArrayOf<WorkspaceGroup> = []
        var topLevelOrder: [SidebarID] = []
        var activeWorkspaceID: UUID?
        var isSidebarVisible: Bool = true
        var isNewWorkspaceSheetPresented: Bool = false
        var pendingSheetGroupID: UUID?
        var renamingWorkspaceID: UUID?
        var renamingPaneID: UUID?
        var renamingGroupID: UUID?
        var groupDeleteConfirmation: GroupDeleteConfirmation?
        var groupBulkCreatePrompt: GroupBulkCreatePrompt?
        var groupCustomEmojiPrompt: GroupCustomEmojiPrompt?
        var selectedWorkspaceIDs: Set<UUID> = []
        var lastSelectionAnchor: UUID?
        var bulkDeleteConfirmationIDs: [UUID]?
        var settings = SettingsFeature.State()
        var repoRegistry: IdentifiedArrayOf<Repo> = []
        var gitStatuses: [UUID: RepoGitStatus] = [:]
        var isInspectorVisible: Bool = false
        var keybindings: KeyBindingMap = .defaults
        var focusFollowsMouse: Bool = false
        var focusFollowsMouseDelay: Int = 100
        var tcpPort: Int = 0
        var tcpPortError: String?
        var globalHotkey: KeyTrigger?
        var globalHotkeyHideOnRepress: Bool = true
        var globalHotkeyRegistrationError: String?

        /// Collision between the current global hotkey and an in-app
        /// keybinding. Computed so it always reflects the latest state —
        /// `keybindings` and `globalHotkey` can land in state in either
        /// order during `appLaunched`, and either one may change later.
        var globalHotkeyConflictWithInApp: KeybindingConflict? {
            guard let trigger = globalHotkey else { return nil }
            return KeybindingConflict.check(
                trigger: trigger,
                in: keybindings,
                globalHotkey: nil,
                ignoreGlobalHotkey: true
            )
        }

        // Command Palette
        var isCommandPaletteVisible: Bool = false
        var commandPaletteQuery: String = ""
        var commandPaletteSelectedIndex: Int = 0

        var activeWorkspace: WorkspaceFeature.State? {
            guard let id = activeWorkspaceID else { return nil }
            return workspaces[id: id]
        }

        /// Sidebar entry that the active workspace occupies, used as an
        /// insertion anchor for `.nearSelection` group placement. Returns
        /// the workspace's own entry when it's top-level, or its parent
        /// group's entry when nested. `nil` when there's no active
        /// workspace or it isn't yet in the sidebar.
        var activeWorkspaceSidebarAnchor: SidebarID? {
            sidebarAnchor(for: activeWorkspaceID)
        }

        /// Anchor used by `.nearSelection` group placement. Prefers the
        /// first workspace being folded into the new group (so a row-level
        /// "New Group..." on a non-active workspace lands next to that
        /// row, not next to the previously active workspace). Falls back
        /// to the active workspace for the empty-group flow.
        func nearSelectionAnchor(for initialWorkspaceIDs: [UUID]) -> SidebarID? {
            if let firstInitial = initialWorkspaceIDs.first,
               let anchor = sidebarAnchor(for: firstInitial) {
                return anchor
            }
            return activeWorkspaceSidebarAnchor
        }

        /// Resolve a workspace ID to its sidebar entry: the workspace's
        /// own top-level entry when it's top-level, its parent group's
        /// entry when nested, or `nil` if the workspace isn't placed yet.
        private func sidebarAnchor(for workspaceID: UUID?) -> SidebarID? {
            guard let workspaceID else { return nil }
            if topLevelOrder.contains(.workspace(workspaceID)) {
                return .workspace(workspaceID)
            }
            for group in groups where group.childOrder.contains(workspaceID) {
                return .group(group.id)
            }
            return nil
        }

        var commandPaletteItems: [CommandPaletteItem] {
            var items: [CommandPaletteItem] = []
            let home = NSHomeDirectory()

            for workspace in workspaces {
                items.append(CommandPaletteItem(
                    id: "ws:\(workspace.id)",
                    icon: "rectangle.stack",
                    title: workspace.name,
                    subtitle: "\(workspace.panes.count) pane\(workspace.panes.count == 1 ? "" : "s")",
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    paneID: nil,
                    workspaceColor: workspace.color
                ))

                let paneIDs = workspace.layout.allPaneIDs
                for paneID in paneIDs {
                    guard let pane = workspace.panes[id: paneID] else { continue }
                    let title = pane.label ?? pane.title ?? pane.workingDirectory
                        .replacingOccurrences(of: home, with: "~")
                    let path = pane.workingDirectory
                        .replacingOccurrences(of: home, with: "~")
                    let subtitle: String = if let label = pane.label, let paneTitle = pane.title, label != paneTitle {
                        paneTitle
                    } else if pane.label != nil {
                        path
                    } else {
                        ""
                    }
                    let icon = switch pane.type {
                    case .shell: "terminal"
                    case .markdown: "doc.text"
                    case .scratchpad: "note.text"
                    }
                    items.append(CommandPaletteItem(
                        id: "pane:\(paneID)",
                        icon: icon,
                        title: title,
                        subtitle: subtitle,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        paneID: paneID,
                        workspaceColor: workspace.color
                    ))
                }
            }

            if commandPaletteQuery.isEmpty { return items }
            let terms = commandPaletteQuery.lowercased()
                .split(separator: " ")
                .filter { !$0.isEmpty }
            guard !terms.isEmpty else { return items }
            return items.filter { item in
                let searchable = (item.title + " " + item.subtitle + " " + item.workspaceName).lowercased()
                return terms.allSatisfy { searchable.contains($0) }
            }
        }

        // MARK: - Workspace group helpers

        /// The top-level slot a workspace currently occupies: its own slot if
        /// ungrouped, or the parent group's slot when it's a child.
        func topLevelSlot(forWorkspace workspaceID: UUID) -> SidebarID? {
            if let groupID = groupID(forWorkspace: workspaceID) {
                return .group(groupID)
            }
            if topLevelOrder.contains(.workspace(workspaceID)) {
                return .workspace(workspaceID)
            }
            return nil
        }

        func groupID(forWorkspace workspaceID: UUID) -> UUID? {
            groups.first(where: { $0.childOrder.contains(workspaceID) })?.id
        }

        /// Resolve a name-or-UUID string to a `WorkspaceGroup`. Used by
        /// the CLI / socket surface to accept human-friendly names.
        /// Tries UUID parse first so typing a UUID always wins over a
        /// legacy name match. Falls back to a case-sensitive exact
        /// name match; ambiguous names (>1 group with the same name)
        /// return `nil` so callers fail fast instead of silently
        /// mutating the wrong group.
        func resolveGroup(_ nameOrID: String) -> WorkspaceGroup? {
            if let uuid = UUID(uuidString: nameOrID), let group = groups[id: uuid] {
                return group
            }
            let matches = groups.filter { $0.name == nameOrID }
            return matches.count == 1 ? matches.first : nil
        }

        /// Same contract as `resolveGroup(_:)` but for workspaces.
        func resolveWorkspace(_ nameOrID: String) -> WorkspaceFeature.State? {
            if let uuid = UUID(uuidString: nameOrID), let ws = workspaces[id: uuid] {
                return ws
            }
            let matches = workspaces.filter { $0.name == nameOrID }
            return matches.count == 1 ? matches.first : nil
        }

        func workspaces(inGroup groupID: UUID) -> [WorkspaceFeature.State] {
            guard let group = groups[id: groupID] else { return [] }
            return group.childOrder.compactMap { workspaces[id: $0] }
        }

        /// Phase 1 invariant: with no groups, `topLevelOrder` mirrors the flat
        /// workspaces list. Call after any mutation that adds, removes, or
        /// reorders workspaces. Will be replaced with granular updates once
        /// groups become user-creatable in Phase 3.
        mutating func syncTopLevelOrderToFlatList() {
            topLevelOrder = workspaces.map { .workspace($0.id) }
        }

        /// Workspaces the user can actually see in the sidebar, in the
        /// order they're rendered. Walks `topLevelOrder` and descends into
        /// expanded groups only. Collapsed groups contribute nothing to
        /// the order so Cmd+N, the row's ⌘N badge, next/previous cycling,
        /// and shift-range select all operate on the visible rows.
        ///
        /// Differs from `state.workspaces` (insertion order) once groups
        /// exist or a bulk top-level move has touched `topLevelOrder`.
        var visibleWorkspaceOrder: [UUID] {
            var result: [UUID] = []
            for item in topLevelOrder {
                switch item {
                case .workspace(let id):
                    if workspaces[id: id] != nil { result.append(id) }
                case .group(let gID):
                    guard let group = groups[id: gID], !group.isCollapsed else { continue }
                    for childID in group.childOrder where workspaces[id: childID] != nil {
                        result.append(childID)
                    }
                }
            }
            return result
        }

        /// Flatten `topLevelOrder` into a list the sidebar can render directly.
        /// Honours per-group collapse state: a collapsed group emits only its
        /// header; an expanded group emits its header followed by its children
        /// (or an empty placeholder if the group has none).
        var renderedEntries: [RenderedEntry] {
            var entries: [RenderedEntry] = []
            for item in topLevelOrder {
                switch item {
                case .workspace(let wsID):
                    guard workspaces[id: wsID] != nil else { continue }
                    entries.append(.workspaceRow(workspaceID: wsID, depth: 0))
                case .group(let gID):
                    guard let group = groups[id: gID] else { continue }
                    entries.append(.groupHeader(groupID: gID))
                    if !group.isCollapsed {
                        let children = group.childOrder.filter { workspaces[id: $0] != nil }
                        if children.isEmpty {
                            entries.append(.groupEmpty(groupID: gID))
                        } else {
                            for childID in children {
                                entries.append(.workspaceRow(workspaceID: childID, depth: 1))
                            }
                        }
                    }
                }
            }
            return entries
        }
    }

    enum Action: Equatable {
        case appLaunched
        case createWorkspace(name: String, color: WorkspaceColor? = nil, repos: [Repo] = [], workingDirectory: String? = nil, groupID: UUID? = nil)
        case deleteWorkspace(UUID)
        case moveWorkspace(id: UUID, toIndex: Int)
        case moveGroup(id: UUID, toIndex: Int)
        case moveWorkspacesToGroup(ids: [UUID], groupID: UUID?, index: Int?)
        case setActiveWorkspace(UUID)
        case switchToWorkspaceByIndex(Int)
        case switchToNextWorkspace
        case switchToPreviousWorkspace
        case toggleSidebar
        case showNewWorkspaceSheet(groupID: UUID? = nil)
        case dismissNewWorkspaceSheet
        case beginRenameActiveWorkspace
        case setRenamingWorkspaceID(UUID?)
        case setRenamingPaneID(UUID?)
        case toggleWorkspaceSelection(UUID)
        case rangeSelectWorkspace(UUID)
        case clearWorkspaceSelection
        case selectAllWorkspaces
        case setBulkColor(WorkspaceColor)
        case requestBulkDelete
        case confirmBulkDelete
        case cancelBulkDelete
        case persistState
        case stateLoaded(
            IdentifiedArrayOf<WorkspaceFeature.State>,
            groups: IdentifiedArrayOf<WorkspaceGroup>,
            topLevelOrder: [SidebarID],
            activeWorkspaceID: UUID?,
            repoRegistry: IdentifiedArrayOf<Repo>
        )

        // Workspace groups
        case toggleGroupCollapse(UUID)
        case createGroup(name: String, color: WorkspaceColor? = nil, insertAfter: SidebarID? = nil, initialWorkspaceIDs: [UUID] = [], autoRename: Bool = false)
        case renameGroup(id: UUID, name: String)
        case setGroupColor(id: UUID, color: WorkspaceColor?)
        case setGroupIcon(id: UUID, icon: GroupIcon?)
        case requestGroupCustomEmoji(UUID)
        case cancelGroupCustomEmoji
        case confirmGroupCustomEmoji(String)
        case deleteGroup(id: UUID, cascade: Bool)
        case moveWorkspaceToGroup(workspaceID: UUID, groupID: UUID?, index: Int? = nil)
        case beginRenameGroup(UUID)
        case setRenamingGroupID(UUID?)
        case requestGroupDelete(UUID)
        case cancelGroupDelete
        case requestBulkCreateGroup
        case cancelBulkCreateGroup
        case confirmBulkCreateGroup(name: String, color: WorkspaceColor?)
        case seedTestGroup // DEBUG-only menu hook; safe to dispatch in tests
        case workspaces(IdentifiedActionOf<WorkspaceFeature>)
        case settings(SettingsFeature.Action)

        /// Socket messages (agent lifecycle + pane/workspace commands).
        /// `reply` is non-nil only for request-style commands (currently
        /// only `pane-list`). The reducer writes a single JSON line via
        /// `reply.send(...)` and closes the connection with
        /// `reply.close()`.
        case socketMessage(SocketMessage, reply: SocketServer.ReplyHandle?)

        // Cross-workspace surface notifications
        case surfaceTitleChanged(paneID: UUID, title: String)
        case surfaceDirectoryChanged(paneID: UUID, directory: String)
        case surfaceProcessExited(paneID: UUID)

        /// Desktop notifications (OSC 9/99/777)
        case desktopNotification(paneID: UUID, title: String, body: String)

        // Repo Registry
        case scanForRepos(rootPath: String)
        case scanCompleted([ScannedRepo])
        case addRepo(path: String, name: String?)
        case repoAdded(Repo)
        case removeRepo(UUID)
        case renameRepo(id: UUID, name: String)

        // Worktree Operations
        case createWorktree(workspaceID: UUID, repoID: UUID, worktreeName: String, branchName: String)
        case worktreeCreated(workspaceID: UUID, repoID: UUID, worktreePath: String, branchName: String)
        case worktreeCreationFailed(workspaceID: UUID, error: String)
        case removeWorktreeAssociation(workspaceID: UUID, associationID: UUID, deleteWorktree: Bool)

        // Auto-detected repo associations
        case autoLinkRepoForPane(workspaceID: UUID, paneID: UUID, directory: String)
        case autoLinkResolved(workspaceID: UUID, paneID: UUID, info: RepoRootInfo)
        case autoUnlinkUnusedRepos(workspaceID: UUID)
        case repoRemoteURLResolved(repoID: UUID, remoteURL: String?)
        case repoAssociationBranchResolved(workspaceID: UUID, associationID: UUID, branch: String?)

        // File Opening
        case openFile
        case openFileAtPath(String, fromPaneID: UUID?)

        // Inspector + Git Status
        case toggleInspector
        case refreshGitStatus
        case gitStatusUpdated(associationID: UUID, status: RepoGitStatus)
        case startGitStatusTimer

        /// External indicators (menu bar, dock badge)
        case updateExternalIndicators

        // Search
        case ghosttySearchStarted(paneID: UUID, needle: String)
        case ghosttySearchEnded(paneID: UUID)
        case searchTotalUpdated(paneID: UUID, total: Int)
        case searchSelectedUpdated(paneID: UUID, selected: Int)

        // Keybindings
        case keybindingsLoaded(KeyBindingMap)
        case setKeybinding(KeyTrigger, NexAction)
        case removeKeybinding(KeyTrigger)
        case resetBindingsForAction(NexAction)
        case resetKeybindings

        // Command Palette
        case toggleCommandPalette
        case dismissCommandPalette
        case commandPaletteQueryChanged(String)
        case commandPaletteSelectIndex(Int)
        case commandPaletteSelectNext
        case commandPaletteSelectPrevious
        case commandPaletteConfirm

        /// General config
        case configLoaded(
            focusFollowsMouse: Bool,
            focusFollowsMouseDelay: Int,
            theme: String?,
            tcpPort: Int,
            globalHotkey: KeyTrigger?,
            globalHotkeyHideOnRepress: Bool
        )
        case setFocusFollowsMouse(Bool)
        case setFocusFollowsMouseDelay(Int)
        case setTCPPort(Int)
        case tcpPortStartFailed(Int)

        // Global Hotkey
        case setGlobalHotkey(KeyTrigger?)
        case setGlobalHotkeyHideOnRepress(Bool)
        case globalHotkeyPressed
        case globalHotkeyRegistrationFailed(reason: String)
        case globalHotkeyRegistrationRejected(revertTo: KeyTrigger?, reason: String)
    }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.persistenceService) var persistenceService
    @Dependency(\.gitService) var gitService
    @Dependency(\.socketServer) var socketServer
    @Dependency(\.notificationService) var notificationService
    @Dependency(\.statusBarController) var statusBarController
    @Dependency(\.ghosttyConfig) var ghosttyConfig
    @Dependency(\.globalHotkeyService) var globalHotkeyService
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock

    private enum GitStatusTimerID: Hashable { case timer }
    private enum AutoLinkResolveID: Hashable { case pane(UUID) }
    private enum AutoLinkDebounceID: Hashable { case pane(UUID) }
    private enum AutoUnlinkDebounceID: Hashable { case workspace(UUID) }
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

    /// Coalesce rapid `cd`s before scanning the directory for a repo root.
    static let autoLinkDebounce: Duration = .milliseconds(500)
    /// Wait before tearing down an auto-detected association, in case a pane
    /// briefly leaves a directory and returns.
    static let autoUnlinkDebounce: Duration = .seconds(5)

    private func scheduleAutoLink(
        workspaceID: UUID,
        paneID: UUID,
        directory: String,
        in state: State
    ) -> Effect<Action> {
        guard state.settings.autoDetectRepos else { return .none }
        return .run { [clock] send in
            try await clock.sleep(for: Self.autoLinkDebounce)
            await send(.autoLinkRepoForPane(
                workspaceID: workspaceID,
                paneID: paneID,
                directory: directory
            ))
        }
        .cancellable(id: AutoLinkDebounceID.pane(paneID), cancelInFlight: true)
    }

    private func scheduleAutoUnlink(workspaceID: UUID, in state: State) -> Effect<Action> {
        guard state.settings.autoDetectRepos else { return .none }
        return .run { [clock] send in
            try await clock.sleep(for: Self.autoUnlinkDebounce)
            await send(.autoUnlinkUnusedRepos(workspaceID: workspaceID))
        }
        .cancellable(id: AutoUnlinkDebounceID.workspace(workspaceID), cancelInFlight: true)
    }

    // MARK: - Socket command helpers

    /// Dispatch `workspace-create` from the CLI. If a `group` is
    /// supplied, the workspace is created first (which synchronously
    /// mutates state) then the new workspace is moved into the group
    /// — creating the group if it doesn't already exist. Resolving
    /// the group name AFTER the workspace is appended means a
    /// pre-existing group is picked up by `resolveGroup`, and a
    /// missing one spawns a new bare group that we can target by id.
    private func handleSocketWorkspaceCreate(
        _ state: inout State,
        name: String?,
        path: String?,
        color: WorkspaceColor?,
        group: String?
    ) -> Effect<Action> {
        let createEffect: Effect<Action> = .send(.createWorkspace(
            name: name ?? "Workspace",
            color: color,
            workingDirectory: path
        ))
        // A missing `group` OR a group that's all whitespace falls
        // back to the top-level create path. Whitespace-only names
        // wouldn't survive the existing `createGroup` trim check
        // anyway, so treat them as "no group specified."
        let trimmedGroup = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedGroup, !trimmedGroup.isEmpty else { return createEffect }

        // Resolve BEFORE any state mutation so an ambiguous-name
        // match can cleanly abort the whole message. `resolveGroup`
        // returns nil for both "missing" and "ambiguous" — we
        // disambiguate by checking for ANY match on that name
        // before deciding to create a new group.
        let existingGroup = state.resolveGroup(trimmedGroup)
        if existingGroup == nil,
           state.groups.contains(where: { $0.name == trimmedGroup }) {
            // Multiple groups share this name — don't silently
            // create a third. The user needs to disambiguate (e.g.
            // by passing a UUID) or rename one of the existing
            // groups first.
            return .none
        }

        // `createWorkspace` uses `@Dependency(\.uuid)` so we
        // pre-compute the id here to keep the move-into-group
        // dispatch precise. Then we seed state directly so the
        // follow-up move lands deterministically even when the
        // reducer batches effects.
        let newWorkspaceID = uuid()
        let workspace = WorkspaceFeature.State(
            id: newWorkspaceID,
            name: name ?? "Workspace",
            color: color ?? state.workspaces.nextRandomColor()
        )
        var seeded = workspace
        if let path {
            seeded.panes[seeded.panes.startIndex].workingDirectory = path
        }
        // Capture the anchor for `.nearSelection` BEFORE overwriting
        // `activeWorkspaceID` — the previously active workspace is what
        // we want the new one to land next to within the target group.
        let previousActiveID = state.activeWorkspaceID
        state.workspaces.append(seeded)
        state.topLevelOrder.append(.workspace(newWorkspaceID))
        state.activeWorkspaceID = newWorkspaceID

        // Resolve or create the group.
        let targetGroupID: UUID
        if let existing = existingGroup {
            targetGroupID = existing.id
        } else {
            let newGroup = WorkspaceGroup(id: uuid(), name: trimmedGroup)
            state.groups.append(newGroup)
            state.topLevelOrder.append(.group(newGroup.id))
            targetGroupID = newGroup.id
        }

        // Mirror the `createWorkspace` + groupID path: honor the
        // `newWorkspacePlacement` setting when picking the slot in
        // the target group's childOrder. `.endOfList` appends (nil),
        // `.nearSelection` inserts right after the previously-active
        // workspace's slot when it's in the same group. A freshly
        // created group has an empty childOrder, so both modes land
        // on append for the "new group" branch above.
        let targetIndex: Int? = {
            switch state.settings.newWorkspacePlacement {
            case .endOfList:
                return nil
            case .nearSelection:
                guard let previousActiveID,
                      let idx = state.groups[id: targetGroupID]?.childOrder.firstIndex(of: previousActiveID)
                else {
                    return nil
                }
                return idx + 1
            }
        }()

        // Create the initial surface for the workspace, then move it
        // under the resolved group, then persist. Mirrors the
        // effects `createWorkspace` would run in the non-group path.
        let paneID = seeded.panes.first!.id
        let cwd = seeded.panes.first!.workingDirectory
        let opacity = ghosttyConfig.backgroundOpacity
        // `moveWorkspaceToGroup` persists, so an explicit persist
        // here would race it. Only the surface-creation side-effect
        // needs to fire alongside.
        return .merge(
            .run { _ in
                await surfaceManager.createSurface(
                    paneID: paneID,
                    workingDirectory: cwd,
                    backgroundOpacity: opacity
                )
            },
            .send(.moveWorkspaceToGroup(
                workspaceID: newWorkspaceID,
                groupID: targetGroupID,
                index: targetIndex
            ))
        )
    }

    /// Dispatch `workspace-move`. `group == nil` targets the top
    /// level; `group` non-nil resolves an existing group (creating
    /// one is deliberately not supported here — use
    /// `workspace-create --group` for that).
    private func handleSocketWorkspaceMove(
        _ state: inout State,
        nameOrID: String,
        group: String?,
        index: Int?
    ) -> Effect<Action> {
        guard let workspace = state.resolveWorkspace(nameOrID) else { return .none }
        let targetGroupID: UUID?
        if let group {
            guard let resolved = state.resolveGroup(group) else { return .none }
            targetGroupID = resolved.id
        } else {
            targetGroupID = nil
        }
        return .send(.moveWorkspaceToGroup(
            workspaceID: workspace.id,
            groupID: targetGroupID,
            index: index
        ))
    }

    /// Dispatch `group-create`. Trims + rejects whitespace-only
    /// names to match the existing `.createGroup` reducer handler
    /// — a blank group name would render as empty header chrome
    /// and isn't reachable by `resolveGroup` once more than one
    /// exists. Icon is intentionally not exposed via this path:
    /// setting an icon is a UI-only affordance (context menu).
    private func handleSocketGroupCreate(
        _ state: inout State,
        name: String,
        color: WorkspaceColor?
    ) -> Effect<Action> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let newID = uuid()
        let createdGroup = WorkspaceGroup(id: newID, name: trimmed, color: color)
        state.groups.append(createdGroup)
        state.topLevelOrder.append(.group(newID))
        return .send(.persistState)
    }

    /// Build the `pane-list` response payload and write it to the
    /// reply handle. Pure read of in-memory state — runs on the main
    /// actor and returns before any effects would fire.
    ///
    /// Filter semantics:
    /// - `workspace` and `scope == "current"` are mutually exclusive
    ///   (server replies with an error if both are set).
    /// - `scope == "current"` requires a valid `paneID`; the response
    ///   contains the panes in the workspace that owns it.
    /// - Unknown `workspace` → error response; unknown `scope` (other
    ///   than `nil` / `"all"` / `"current"`) → error response.
    func handlePaneList(
        state: State,
        paneID: UUID?,
        workspaceFilter: String?,
        scope: String?,
        reply: SocketServer.ReplyHandle?
    ) {
        guard let reply else { return }

        // Validate mutually exclusive filters.
        if workspaceFilter != nil, scope == "current" {
            reply.send(["ok": false, "error": "workspace and --current are mutually exclusive"])
            reply.close()
            return
        }

        // Resolve which workspaces to include.
        let workspaces: [WorkspaceFeature.State]
        switch scope {
        case nil, "all":
            if let filter = workspaceFilter {
                guard let ws = state.resolveWorkspace(filter) else {
                    reply.send(["ok": false, "error": "workspace not found: \(filter)"])
                    reply.close()
                    return
                }
                workspaces = [ws]
            } else {
                workspaces = Array(state.workspaces)
            }
        case "current":
            guard let paneID,
                  let ws = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) else {
                reply.send(["ok": false, "error": "no workspace contains the requesting pane"])
                reply.close()
                return
            }
            workspaces = [ws]
        default:
            reply.send(["ok": false, "error": "unknown scope: \(scope ?? "")"])
            reply.close()
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var panes: [[String: Any]] = []
        for workspace in workspaces {
            for paneID in workspace.layout.allPaneIDs {
                guard let pane = workspace.panes[id: paneID] else { continue }
                var entry: [String: Any] = [
                    "id": pane.id.uuidString,
                    "type": pane.type.rawValue,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_name": workspace.name,
                    "working_directory": pane.workingDirectory,
                    "status": pane.status.rawValue,
                    "is_focused": workspace.focusedPaneID == pane.id,
                    "is_active_workspace": state.activeWorkspaceID == workspace.id,
                    "created_at": iso.string(from: pane.createdAt),
                    "last_activity_at": iso.string(from: pane.lastActivityAt)
                ]
                if let label = pane.label { entry["label"] = label }
                if let title = pane.title { entry["title"] = title }
                if let branch = pane.gitBranch { entry["git_branch"] = branch }
                if let sessionID = pane.claudeSessionID { entry["claude_session_id"] = sessionID }
                if let filePath = pane.filePath { entry["file_path"] = filePath }
                panes.append(entry)
            }
        }

        reply.send(["ok": true, "panes": panes])
        reply.close()
    }

    /// Resolve + dispatch a `pane-close` request. `paneID` comes from
    /// `NEX_PANE_ID` (no-flag form); `target` is the `--target
    /// <name-or-uuid>` value; `workspaceFilter` optionally narrows
    /// label resolution to a specific workspace. Writes a structured
    /// `{ok,...}` reply and closes the connection. `reply` is nil on
    /// the legacy fire-and-forget path used by older CLIs (pre
    /// request/response) — we still dispatch the close in that case so
    /// old clients keep working against a new server.
    func handlePaneClose(
        state: State,
        paneID: UUID?,
        target: String?,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        func fail(_ error: String) -> Effect<Action> {
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        // If `--workspace` was supplied, resolve it up front so an
        // unknown workspace returns a specific error rather than
        // cascading into "unresolved target".
        let scopedWorkspace: WorkspaceFeature.State?
        if let filter = workspaceFilter {
            guard let ws = state.resolveWorkspace(filter) else {
                return fail("workspace not found: \(filter)")
            }
            scopedWorkspace = ws
        } else {
            scopedWorkspace = nil
        }

        // Resolve the pane to close. `target` wins over `paneID` when
        // both are present (documented precedence).
        let resolvedID: UUID
        if let target {
            if let uuid = UUID(uuidString: target) {
                if let scopedWorkspace {
                    guard scopedWorkspace.panes[id: uuid] != nil else {
                        return fail("no pane with UUID '\(target)' in workspace '\(scopedWorkspace.name)'")
                    }
                } else {
                    guard state.workspaces.contains(where: { $0.panes[id: uuid] != nil }) else {
                        return fail("no pane with UUID '\(target)'")
                    }
                }
                resolvedID = uuid
            } else {
                // Label lookup. Workspace scope wins when supplied;
                // otherwise prefer the origin workspace (caller's own)
                // before falling back to a globally-unique match.
                let candidates: [Pane]
                if let scopedWorkspace {
                    candidates = Array(scopedWorkspace.panes.filter { $0.label == target })
                } else if let paneID,
                          let origin = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
                    let local = origin.panes.filter { $0.label == target }
                    if local.count == 1 {
                        candidates = Array(local)
                    } else if local.isEmpty {
                        candidates = state.workspaces.flatMap(\.panes).filter { $0.label == target }
                    } else {
                        // Ambiguous within origin workspace — extremely
                        // rare (label uniqueness isn't enforced) but
                        // surface rather than closing an arbitrary one.
                        candidates = Array(local)
                    }
                } else {
                    candidates = state.workspaces.flatMap(\.panes).filter { $0.label == target }
                }

                switch candidates.count {
                case 0:
                    let scope = scopedWorkspace.map { " in workspace '\($0.name)'" } ?? ""
                    return fail("no pane with label '\(target)'\(scope)")
                case 1:
                    resolvedID = candidates[0].id
                default:
                    return fail(
                        "label '\(target)' is ambiguous (\(candidates.count) matches); " +
                            "pass --workspace <name-or-id> to disambiguate"
                    )
                }
            }
        } else if let paneID {
            guard state.workspaces.contains(where: { $0.panes[id: paneID] != nil }) else {
                return fail("no pane with UUID '\(paneID.uuidString)'")
            }
            resolvedID = paneID
        } else {
            // The wire decoder rejects this case, so it should never
            // reach here in production — defensive fail keeps the
            // contract honest.
            return fail("missing pane_id and target")
        }

        guard let workspace = state.workspaces.first(where: { $0.panes[id: resolvedID] != nil }) else {
            // Same defensive branch — resolution above already
            // verified the pane exists.
            return fail("pane not found: \(resolvedID.uuidString)")
        }

        // If `--workspace` was supplied, confirm the resolved pane
        // actually lives there. UUID resolution already enforces this;
        // the guard covers future paths that might bypass the check.
        if let scopedWorkspace, scopedWorkspace.id != workspace.id {
            return fail("pane '\(resolvedID.uuidString)' is not in workspace '\(scopedWorkspace.name)'")
        }

        var payload: [String: Any] = [
            "ok": true,
            "pane_id": resolvedID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name
        ]
        if let label = workspace.panes[id: resolvedID]?.label {
            payload["label"] = label
        }
        reply?.send(payload)
        reply?.close()
        return .send(.workspaces(.element(id: workspace.id, action: .closePane(resolvedID))))
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appLaunched:
                return .merge(
                    .run { send in
                        let result = await persistenceService.load()
                        await send(.stateLoaded(
                            result.workspaces,
                            groups: result.groups,
                            topLevelOrder: result.topLevelOrder,
                            activeWorkspaceID: result.activeWorkspaceID,
                            repoRegistry: result.repoRegistry
                        ))
                    },
                    .send(.settings(.loadSettings)),
                    .run { send in
                        let bindings = KeybindingService.loadFromDisk()
                        await send(.keybindingsLoaded(bindings))
                    },
                    .run { send in
                        let config = ConfigParser.parseGeneralSettings(
                            fromFile: KeybindingService.configPath
                        )
                        await send(.configLoaded(
                            focusFollowsMouse: config.focusFollowsMouse,
                            focusFollowsMouseDelay: config.focusFollowsMouseDelay,
                            theme: config.theme,
                            tcpPort: config.tcpPort,
                            globalHotkey: config.globalHotkey,
                            globalHotkeyHideOnRepress: config.globalHotkeyHideOnRepress
                        ))
                    }
                )

            case .createWorkspace(let name, let color, let repos, let workingDirectory, let groupID):
                let previousActiveID = state.activeWorkspaceID
                let resolvedColor = color ?? state.workspaces.nextRandomColor()
                var workspace = WorkspaceFeature.State(
                    id: uuid(),
                    name: name,
                    color: resolvedColor
                )

                // If exactly one repo, start the first pane in that repo's directory
                if repos.count == 1 {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = repos[0].path
                } else if let workingDirectory {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = workingDirectory
                }

                // Register repos and add associations
                for repo in repos {
                    if state.repoRegistry[id: repo.id] == nil {
                        state.repoRegistry.append(repo)
                    }
                    let assoc = RepoAssociation(
                        id: uuid(),
                        repoID: repo.id,
                        worktreePath: repo.path
                    )
                    workspace.repoAssociations.append(assoc)
                }

                state.workspaces.append(workspace)
                // Place into the target group if one was supplied and exists.
                // Placement within the group (or at top level when no group is
                // supplied) follows the `newWorkspacePlacement` setting:
                //   - `.endOfList` always appends.
                //   - `.nearSelection` inserts after the previously-active
                //     workspace's slot (its entry in the group's childOrder,
                //     or its top-level sidebar anchor when ungrouped).
                // Fall back to top-level append when the supplied group is
                // missing (defensive).
                let placement = state.settings.newWorkspacePlacement
                if let groupID, state.groups[id: groupID] != nil {
                    let insertIndex: Int = {
                        let count = state.groups[id: groupID]?.childOrder.count ?? 0
                        switch placement {
                        case .endOfList:
                            return count
                        case .nearSelection:
                            guard let previousActiveID,
                                  let idx = state.groups[id: groupID]?.childOrder.firstIndex(of: previousActiveID)
                            else {
                                return count
                            }
                            return idx + 1
                        }
                    }()
                    state.groups[id: groupID]?.childOrder.insert(workspace.id, at: insertIndex)
                    // Match the .setActiveWorkspace behavior: expand the parent
                    // group so the just-created (and now active) workspace is
                    // visible rather than tucked inside a collapsed group.
                    if state.groups[id: groupID]?.isCollapsed == true {
                        state.groups[id: groupID]?.isCollapsed = false
                    }
                } else {
                    switch placement {
                    case .endOfList:
                        state.topLevelOrder.append(.workspace(workspace.id))
                    case .nearSelection:
                        if let anchor = state.activeWorkspaceSidebarAnchor,
                           let idx = state.topLevelOrder.firstIndex(of: anchor) {
                            state.topLevelOrder.insert(.workspace(workspace.id), at: idx + 1)
                        } else {
                            state.topLevelOrder.append(.workspace(workspace.id))
                        }
                    }
                }
                state.activeWorkspaceID = workspace.id
                state.isNewWorkspaceSheetPresented = false
                state.pendingSheetGroupID = nil

                // Create the initial surface for the default pane
                let paneID = workspace.panes.first!.id
                let cwd = workspace.panes.first!.workingDirectory
                let opacity = ghosttyConfig.backgroundOpacity
                return .merge(
                    .run { _ in
                        await surfaceManager.createSurface(paneID: paneID, workingDirectory: cwd, backgroundOpacity: opacity)
                    },
                    .send(.persistState)
                )

            case .deleteWorkspace(let id):
                guard let workspace = state.workspaces[id: id] else { return .none }
                let paneIDs = workspace.layout.allPaneIDs
                state.workspaces.remove(id: id)
                state.topLevelOrder.removeAll { $0 == .workspace(id) }
                for groupID in state.groups.ids {
                    state.groups[id: groupID]?.childOrder.removeAll { $0 == id }
                }

                if state.activeWorkspaceID == id {
                    state.activeWorkspaceID = state.workspaces
                        .max(by: { $0.lastAccessedAt < $1.lastAccessedAt })?
                        .id
                }

                if state.renamingWorkspaceID == id {
                    state.renamingWorkspaceID = nil
                }
                if let renamingPaneID = state.renamingPaneID,
                   !state.workspaces.contains(where: { $0.panes[id: renamingPaneID] != nil }) {
                    state.renamingPaneID = nil
                }

                state.selectedWorkspaceIDs.remove(id)
                if state.lastSelectionAnchor == id {
                    state.lastSelectionAnchor = nil
                }

                return .merge(
                    .run { _ in
                        for paneID in paneIDs {
                            await surfaceManager.destroySurface(paneID: paneID)
                        }
                    },
                    .send(.persistState)
                )

            case .moveWorkspace(let id, let toIndex):
                // Reorders `id` within the top-level sidebar order. `toIndex`
                // is an index into `state.topLevelOrder` (which interleaves
                // ungrouped workspaces and group headers). Also mirrors the
                // move into `state.workspaces` so Cmd+N numbering stays
                // aligned with the visual order.
                guard let fromTop = state.topLevelOrder.firstIndex(of: .workspace(id)),
                      fromTop != toIndex,
                      toIndex >= 0,
                      toIndex < state.topLevelOrder.count
                else { return .none }
                let entry = state.topLevelOrder.remove(at: fromTop)
                state.topLevelOrder.insert(entry, at: min(toIndex, state.topLevelOrder.endIndex))

                if let fromFlat = state.workspaces.index(id: id) {
                    let workspace = state.workspaces.remove(at: fromFlat)
                    let flatTarget = min(toIndex, state.workspaces.endIndex)
                    state.workspaces.insert(workspace, at: flatTarget)
                }

                return .send(.persistState)

            case .moveWorkspacesToGroup(let ids, let targetGroupID, let index):
                // Atomic bulk move. Removes all `ids` from their current
                // parents (top-level or any group), then inserts them in
                // order at the destination. `index` uses the post-remove
                // convention — same semantics the DropTarget walker
                // already produces when passed the full multi-source set.
                //
                // Doing this in one pass avoids the drift that sequential
                // single-workspace moves cause when sources and target
                // overlap (e.g., reordering a subset within a single
                // group, or moving top-level + grouped sources together).
                if let gid = targetGroupID, state.groups[id: gid] == nil {
                    return .none
                }
                let ordered = ids.filter { state.workspaces[id: $0] != nil }
                guard !ordered.isEmpty else { return .none }
                let moved = Set(ordered)

                state.topLevelOrder.removeAll { entry in
                    if case .workspace(let id) = entry { return moved.contains(id) }
                    return false
                }
                for gid in state.groups.ids {
                    state.groups[id: gid]?.childOrder.removeAll { moved.contains($0) }
                }

                if let gid = targetGroupID {
                    var children = state.groups[id: gid]?.childOrder ?? []
                    let insertAt = index.map { max(0, min($0, children.count)) } ?? children.count
                    children.insert(contentsOf: ordered, at: insertAt)
                    state.groups[id: gid]?.childOrder = children
                    if state.groups[id: gid]?.isCollapsed == true {
                        state.groups[id: gid]?.isCollapsed = false
                    }
                } else {
                    let entries: [SidebarID] = ordered.map { .workspace($0) }
                    let insertAt = index.map { max(0, min($0, state.topLevelOrder.count)) }
                        ?? state.topLevelOrder.count
                    state.topLevelOrder.insert(contentsOf: entries, at: insertAt)
                }
                return .send(.persistState)

            case .moveGroup(let id, let toIndex):
                // Reorders `.group(id)` within `topLevelOrder`. Groups only
                // ever live at the top level (no nesting), so this action
                // doesn't touch `state.workspaces` or `childOrder`. Index
                // follows the post-remove convention that matches
                // `.moveWorkspace`.
                guard let fromTop = state.topLevelOrder.firstIndex(of: .group(id)),
                      fromTop != toIndex,
                      toIndex >= 0,
                      toIndex < state.topLevelOrder.count
                else { return .none }
                let entry = state.topLevelOrder.remove(at: fromTop)
                state.topLevelOrder.insert(entry, at: min(toIndex, state.topLevelOrder.endIndex))
                return .send(.persistState)

            case .setActiveWorkspace(let id):
                state.activeWorkspaceID = id
                state.workspaces[id: id]?.lastAccessedAt = Date()
                // Auto-expand the parent group if the activated workspace is
                // tucked inside a collapsed group. Otherwise the user just
                // hit a hidden item and would not see why focus moved.
                if let groupID = state.groupID(forWorkspace: id),
                   state.groups[id: groupID]?.isCollapsed == true {
                    state.groups[id: groupID]?.isCollapsed = false
                }
                return .merge(
                    .send(.persistState),
                    .send(.refreshGitStatus)
                )

            case .switchToWorkspaceByIndex(let index):
                // Walk the visible sidebar order so Cmd+N maps to the
                // user's visual numbering, not `state.workspaces`'
                // insertion order (which drifts once groups or bulk
                // top-level drags touch `topLevelOrder`).
                let visible = state.visibleWorkspaceOrder
                guard index >= 0, index < visible.count else { return .none }
                return .send(.setActiveWorkspace(visible[index]))

            case .switchToNextWorkspace:
                let visible = state.visibleWorkspaceOrder
                guard !visible.isEmpty,
                      let current = state.activeWorkspaceID,
                      let currentIndex = visible.firstIndex(of: current)
                else { return .none }
                let nextIndex = (currentIndex + 1) % visible.count
                return .send(.setActiveWorkspace(visible[nextIndex]))

            case .switchToPreviousWorkspace:
                let visible = state.visibleWorkspaceOrder
                guard !visible.isEmpty,
                      let current = state.activeWorkspaceID,
                      let currentIndex = visible.firstIndex(of: current)
                else { return .none }
                let prevIndex = (currentIndex - 1 + visible.count) % visible.count
                return .send(.setActiveWorkspace(visible[prevIndex]))

            case .toggleSidebar:
                state.isSidebarVisible.toggle()
                return .none

            case .showNewWorkspaceSheet(let groupID):
                state.isNewWorkspaceSheetPresented = true
                state.pendingSheetGroupID = groupID
                return .none

            case .dismissNewWorkspaceSheet:
                state.isNewWorkspaceSheetPresented = false
                state.pendingSheetGroupID = nil
                return .none

            case .beginRenameActiveWorkspace:
                state.renamingWorkspaceID = state.activeWorkspaceID
                return .none

            case .setRenamingWorkspaceID(let id):
                state.renamingWorkspaceID = id
                return .none

            case .setRenamingPaneID(let id):
                state.renamingPaneID = id
                return .none

            case .toggleWorkspaceSelection(let id):
                guard state.workspaces[id: id] != nil else { return .none }
                if state.selectedWorkspaceIDs.contains(id) {
                    state.selectedWorkspaceIDs.remove(id)
                } else {
                    state.selectedWorkspaceIDs.insert(id)
                }
                state.lastSelectionAnchor = id
                return .none

            case .rangeSelectWorkspace(let id):
                // Walk the visible sidebar order (top-level + each group's
                // children) so shift-select picks the contiguous run the
                // user actually sees. `state.workspaces` is insertion
                // order and diverges from visible order once groups exist.
                let visible = state.visibleWorkspaceOrder
                guard let targetIdx = visible.firstIndex(of: id) else { return .none }
                let anchorID = state.lastSelectionAnchor
                    ?? state.selectedWorkspaceIDs.first
                    ?? state.activeWorkspaceID
                    ?? id
                let anchorIdx = visible.firstIndex(of: anchorID) ?? targetIdx
                let lo = min(anchorIdx, targetIdx)
                let hi = max(anchorIdx, targetIdx)
                state.selectedWorkspaceIDs.formUnion(visible[lo ... hi])
                state.lastSelectionAnchor = id
                return .none

            case .clearWorkspaceSelection:
                state.selectedWorkspaceIDs.removeAll()
                state.lastSelectionAnchor = nil
                return .none

            case .selectAllWorkspaces:
                state.selectedWorkspaceIDs = Set(state.workspaces.ids)
                state.lastSelectionAnchor = state.workspaces.last?.id
                return .none

            case .setBulkColor(let color):
                for id in state.selectedWorkspaceIDs {
                    state.workspaces[id: id]?.color = color
                }
                return .send(.persistState)

            case .requestBulkDelete:
                let ids = Array(state.selectedWorkspaceIDs)
                guard !ids.isEmpty, ids.count < state.workspaces.count else { return .none }
                state.bulkDeleteConfirmationIDs = ids
                return .none

            case .cancelBulkDelete:
                state.bulkDeleteConfirmationIDs = nil
                return .none

            case .confirmBulkDelete:
                guard let ids = state.bulkDeleteConfirmationIDs else { return .none }
                state.bulkDeleteConfirmationIDs = nil
                guard ids.count < state.workspaces.count else { return .none }

                var panesToDestroy: [UUID] = []
                for id in ids {
                    guard let workspace = state.workspaces[id: id] else { continue }
                    panesToDestroy.append(contentsOf: workspace.layout.allPaneIDs)
                    state.workspaces.remove(id: id)
                }
                let removedSet = Set(ids)
                state.topLevelOrder.removeAll {
                    if case .workspace(let wsID) = $0, removedSet.contains(wsID) { return true }
                    return false
                }
                for groupID in state.groups.ids {
                    state.groups[id: groupID]?.childOrder.removeAll { removedSet.contains($0) }
                }

                if let activeID = state.activeWorkspaceID, ids.contains(activeID) {
                    state.activeWorkspaceID = state.workspaces
                        .max(by: { $0.lastAccessedAt < $1.lastAccessedAt })?
                        .id
                }
                if let renamingID = state.renamingWorkspaceID, ids.contains(renamingID) {
                    state.renamingWorkspaceID = nil
                }
                if let renamingPaneID = state.renamingPaneID,
                   !state.workspaces.contains(where: { $0.panes[id: renamingPaneID] != nil }) {
                    state.renamingPaneID = nil
                }
                state.selectedWorkspaceIDs.subtract(ids)
                state.lastSelectionAnchor = nil

                let paneIDs = panesToDestroy
                return .merge(
                    .run { _ in
                        for paneID in paneIDs {
                            await surfaceManager.destroySurface(paneID: paneID)
                        }
                    },
                    .send(.persistState)
                )

            case .toggleGroupCollapse(let groupID):
                guard state.groups[id: groupID] != nil else { return .none }
                state.groups[id: groupID]?.isCollapsed.toggle()
                return .send(.persistState)

            case .createGroup(let name, let color, let insertAfter, let initialWorkspaceIDs, let autoRename):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }

                // Preserve request order but drop duplicates and missing IDs.
                var seen = Set<UUID>()
                var validInitial: [UUID] = []
                for id in initialWorkspaceIDs {
                    guard state.workspaces[id: id] != nil, seen.insert(id).inserted else { continue }
                    validInitial.append(id)
                }

                // Resolve the insertion anchor before any mutations. When
                // the caller specifies an explicit anchor, use it. Otherwise
                // fall back to the `newGroupPlacement` setting:
                //   - `.endOfList` always appends.
                //   - `.nearSelection` prefers the first `initialWorkspaceIDs`
                //     entry (the row the action was launched from in the
                //     workspace-row "New Group..." flow) and only falls back
                //     to the active workspace for the empty-group flow.
                let resolvedInsertAfter: SidebarID? = if let insertAfter {
                    insertAfter
                } else {
                    switch state.settings.newGroupPlacement {
                    case .endOfList:
                        nil
                    case .nearSelection:
                        state.nearSelectionAnchor(for: validInitial)
                    }
                }

                // Capture the anchor's position and whether it will be
                // detached *before* mutating `topLevelOrder`, so the new
                // group can slot into the spot the row occupied even when
                // that row is about to be folded into the new group.
                let anchorIndexBefore: Int? =
                    resolvedInsertAfter.flatMap { state.topLevelOrder.firstIndex(of: $0) }
                let anchorWillBeDetached: Bool = {
                    guard case .workspace(let id) = resolvedInsertAfter else { return false }
                    return validInitial.contains(id)
                }()
                let removedBeforeAnchor: Int = {
                    guard let anchorIdx = anchorIndexBefore, !validInitial.isEmpty else { return 0 }
                    let moved = Set(validInitial)
                    var count = 0
                    for i in 0 ..< anchorIdx {
                        if case .workspace(let id) = state.topLevelOrder[i], moved.contains(id) {
                            count += 1
                        }
                    }
                    return count
                }()

                let newGroup = WorkspaceGroup(
                    id: uuid(),
                    name: trimmed,
                    color: color,
                    isCollapsed: false,
                    childOrder: validInitial
                )
                state.groups.append(newGroup)

                // Detach any initial workspaces from their previous parent
                // group so they only live in one place.
                if !validInitial.isEmpty {
                    let moved = Set(validInitial)
                    for groupID in state.groups.ids where groupID != newGroup.id {
                        state.groups[id: groupID]?.childOrder.removeAll { moved.contains($0) }
                    }
                    state.topLevelOrder.removeAll { entry in
                        if case .workspace(let id) = entry { return moved.contains(id) }
                        return false
                    }
                }

                // Insertion position in `topLevelOrder`.
                let newEntry: SidebarID = .group(newGroup.id)
                if let anchorIdx = anchorIndexBefore {
                    // Adjust for removals that were strictly before the anchor.
                    let adjusted = anchorIdx - removedBeforeAnchor
                    // If the anchor itself was removed (it was the workspace
                    // being grouped), its slot is now free and becomes the
                    // insertion point. Otherwise insert right after the anchor.
                    let target = anchorWillBeDetached ? adjusted : adjusted + 1
                    let bounded = max(0, min(target, state.topLevelOrder.count))
                    state.topLevelOrder.insert(newEntry, at: bounded)
                } else {
                    state.topLevelOrder.append(newEntry)
                }

                // Reset any dangling prompt state that triggered this.
                state.groupBulkCreatePrompt = nil
                // Drop the user straight into inline rename so they can
                // replace the placeholder name without another click.
                if autoRename {
                    state.renamingGroupID = newGroup.id
                }
                return .send(.persistState)

            case .renameGroup(let id, let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, state.groups[id: id] != nil else { return .none }
                state.groups[id: id]?.name = trimmed
                if state.renamingGroupID == id {
                    state.renamingGroupID = nil
                }
                return .send(.persistState)

            case .setGroupColor(let id, let color):
                guard state.groups[id: id] != nil else { return .none }
                state.groups[id: id]?.color = color
                return .send(.persistState)

            case .setGroupIcon(let id, let icon):
                guard state.groups[id: id] != nil else { return .none }
                state.groups[id: id]?.icon = icon
                return .send(.persistState)

            case .requestGroupCustomEmoji(let id):
                guard let group = state.groups[id: id] else { return .none }
                state.groupCustomEmojiPrompt = GroupCustomEmojiPrompt(
                    groupID: id,
                    groupName: group.name
                )
                return .none

            case .cancelGroupCustomEmoji:
                state.groupCustomEmojiPrompt = nil
                return .none

            case .confirmGroupCustomEmoji(let emoji):
                // Enforce the "1 emoji grapheme" rule server-side so a
                // stray plain character can't slip past the sheet's
                // input filter. A non-emoji payload clears the prompt
                // without changing the icon.
                let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let prompt = state.groupCustomEmojiPrompt,
                      let firstGrapheme = trimmed.first,
                      firstGrapheme.isGraphemeEmoji
                else {
                    state.groupCustomEmojiPrompt = nil
                    return .none
                }
                state.groupCustomEmojiPrompt = nil
                guard state.groups[id: prompt.groupID] != nil else { return .none }
                state.groups[id: prompt.groupID]?.icon = .emoji(String(firstGrapheme))
                return .send(.persistState)

            case .deleteGroup(let id, let cascade):
                guard let group = state.groups[id: id] else { return .none }
                let childIDs = group.childOrder
                let insertionIndex = state.topLevelOrder.firstIndex(of: .group(id))
                state.topLevelOrder.removeAll { $0 == .group(id) }
                state.groups.remove(id: id)

                if cascade {
                    // Drop each child workspace. Mirrors `deleteWorkspace` so
                    // surfaces are destroyed and downstream state stays clean.
                    var paneIDs: [UUID] = []
                    for wsID in childIDs {
                        guard let workspace = state.workspaces[id: wsID] else { continue }
                        paneIDs.append(contentsOf: workspace.layout.allPaneIDs)
                        state.workspaces.remove(id: wsID)
                    }
                    let removedSet = Set(childIDs)
                    if let activeID = state.activeWorkspaceID, removedSet.contains(activeID) {
                        state.activeWorkspaceID = state.workspaces
                            .max(by: { $0.lastAccessedAt < $1.lastAccessedAt })?
                            .id
                    }
                    if let renamingID = state.renamingWorkspaceID, removedSet.contains(renamingID) {
                        state.renamingWorkspaceID = nil
                    }
                    if let renamingPaneID = state.renamingPaneID,
                       !state.workspaces.contains(where: { $0.panes[id: renamingPaneID] != nil }) {
                        state.renamingPaneID = nil
                    }
                    state.selectedWorkspaceIDs.subtract(removedSet)
                    if let anchor = state.lastSelectionAnchor, removedSet.contains(anchor) {
                        state.lastSelectionAnchor = nil
                    }
                    state.groupDeleteConfirmation = nil

                    let captured = paneIDs
                    return .merge(
                        .run { _ in
                            for paneID in captured {
                                await surfaceManager.destroySurface(paneID: paneID)
                            }
                        },
                        .send(.persistState)
                    )
                } else {
                    // Promote children to the top level, in order, at the
                    // group's former position.
                    let newEntries: [SidebarID] = childIDs
                        .filter { state.workspaces[id: $0] != nil }
                        .map { .workspace($0) }
                    if let insertionIndex {
                        state.topLevelOrder.insert(contentsOf: newEntries, at: insertionIndex)
                    } else {
                        state.topLevelOrder.append(contentsOf: newEntries)
                    }
                    state.groupDeleteConfirmation = nil
                    return .send(.persistState)
                }

            case .moveWorkspaceToGroup(let workspaceID, let targetGroupID, let index):
                guard state.workspaces[id: workspaceID] != nil else { return .none }
                // Validate destination BEFORE detaching so a stale caller
                // referencing a deleted group can't leave the workspace
                // orphaned (removed from its source but never reattached).
                if let targetGroupID, state.groups[id: targetGroupID] == nil {
                    return .none
                }

                let currentGroupID = state.groupID(forWorkspace: workspaceID)
                // Remove from current parent (group or top level).
                if let currentGroupID {
                    state.groups[id: currentGroupID]?.childOrder.removeAll { $0 == workspaceID }
                } else {
                    state.topLevelOrder.removeAll { $0 == .workspace(workspaceID) }
                }

                if let targetGroupID {
                    var order = state.groups[id: targetGroupID]?.childOrder ?? []
                    let insertAt = index.map { max(0, min($0, order.count)) } ?? order.count
                    order.insert(workspaceID, at: insertAt)
                    state.groups[id: targetGroupID]?.childOrder = order
                    if state.settings.expandGroupOnWorkspaceDrop,
                       state.groups[id: targetGroupID]?.isCollapsed == true {
                        state.groups[id: targetGroupID]?.isCollapsed = false
                    }
                } else {
                    let entry: SidebarID = .workspace(workspaceID)
                    let insertAt: Int = if let index {
                        max(0, min(index, state.topLevelOrder.count))
                    } else {
                        state.topLevelOrder.count
                    }
                    state.topLevelOrder.insert(entry, at: insertAt)
                }

                return .send(.persistState)

            case .beginRenameGroup(let id):
                guard state.groups[id: id] != nil else { return .none }
                state.renamingGroupID = id
                return .none

            case .setRenamingGroupID(let id):
                state.renamingGroupID = id
                return .none

            case .requestGroupDelete(let id):
                guard let group = state.groups[id: id] else { return .none }
                let count = group.childOrder.count(where: { state.workspaces[id: $0] != nil })
                state.groupDeleteConfirmation = GroupDeleteConfirmation(
                    groupID: id,
                    groupName: group.name,
                    workspaceCount: count
                )
                return .none

            case .cancelGroupDelete:
                state.groupDeleteConfirmation = nil
                return .none

            case .requestBulkCreateGroup:
                let ids = state.selectedWorkspaceIDs
                guard !ids.isEmpty else { return .none }
                // Preserve the order the user sees in the sidebar.
                var ordered: [UUID] = []
                for entry in state.topLevelOrder {
                    switch entry {
                    case .workspace(let id) where ids.contains(id):
                        ordered.append(id)
                    case .group(let gID):
                        guard let group = state.groups[id: gID] else { continue }
                        for childID in group.childOrder where ids.contains(childID) {
                            ordered.append(childID)
                        }
                    default:
                        break
                    }
                }
                guard !ordered.isEmpty else { return .none }
                state.groupBulkCreatePrompt = GroupBulkCreatePrompt(workspaceIDs: ordered)
                return .none

            case .cancelBulkCreateGroup:
                state.groupBulkCreatePrompt = nil
                return .none

            case .confirmBulkCreateGroup(let name, let color):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let ids = state.groupBulkCreatePrompt?.workspaceIDs,
                      !ids.isEmpty
                else {
                    state.groupBulkCreatePrompt = nil
                    return .none
                }
                state.groupBulkCreatePrompt = nil
                // Clear selection so the new group header becomes the visual anchor.
                state.selectedWorkspaceIDs.removeAll()
                state.lastSelectionAnchor = nil
                return .send(.createGroup(
                    name: trimmed,
                    color: color,
                    insertAfter: nil,
                    initialWorkspaceIDs: ids
                ))

            case .seedTestGroup:
                let groupID = uuid()
                let ws1ID = uuid()
                let ws2ID = uuid()
                let ws1 = WorkspaceFeature.State(
                    id: ws1ID,
                    name: "Test Monitor 1",
                    color: .gray
                )
                let ws2 = WorkspaceFeature.State(
                    id: ws2ID,
                    name: "Test Monitor 2",
                    color: .gray
                )
                state.workspaces.append(ws1)
                state.workspaces.append(ws2)
                let group = WorkspaceGroup(
                    id: groupID,
                    name: "Test Group",
                    color: .gray,
                    isCollapsed: false,
                    childOrder: [ws1ID, ws2ID]
                )
                state.groups.append(group)
                state.topLevelOrder.append(.group(groupID))

                let opacity = ghosttyConfig.backgroundOpacity
                let panes: [(id: UUID, cwd: String)] = [
                    (id: ws1.panes.first!.id, cwd: ws1.panes.first!.workingDirectory),
                    (id: ws2.panes.first!.id, cwd: ws2.panes.first!.workingDirectory)
                ]
                return .merge(
                    .run { _ in
                        for pane in panes {
                            await surfaceManager.createSurface(
                                paneID: pane.id,
                                workingDirectory: pane.cwd,
                                backgroundOpacity: opacity
                            )
                        }
                    },
                    .send(.persistState)
                )

            case .persistState:
                let snapshot = PersistenceSnapshot(state: state)
                return .run { _ in
                    await persistenceService.save(snapshot: snapshot)
                }

            case .stateLoaded(let workspaces, let groups, let topLevelOrder, let activeID, let repoRegistry):
                if workspaces.isEmpty {
                    // First launch — create a default workspace
                    return .send(.createWorkspace(name: "Default"))
                }
                state.workspaces = workspaces
                state.groups = groups
                state.activeWorkspaceID = activeID ?? workspaces.first?.id
                state.repoRegistry = repoRegistry

                // Use persisted topLevelOrder if present; otherwise synthesize
                // from the flat workspaces list (legacy DBs predate groups).
                if topLevelOrder.isEmpty {
                    state.syncTopLevelOrderToFlatList()
                } else {
                    state.topLevelOrder = topLevelOrder
                }

                // Collect panes eligible for auto-resume before clearing.
                // Any pane with a claudeSessionID is resumable — the session
                // remains valid regardless of the pane's current status.
                var resumablePanes: [(paneID: UUID, sessionID: String)] = []
                for workspace in workspaces {
                    for pane in workspace.panes {
                        if let sessionID = pane.claudeSessionID {
                            resumablePanes.append((paneID: pane.id, sessionID: sessionID))
                        }
                    }
                }

                // Clear session IDs and reset status to prevent stale resumes on next restart
                for workspace in state.workspaces {
                    for pane in workspace.panes {
                        if pane.claudeSessionID != nil {
                            state.workspaces[id: workspace.id]?.panes[id: pane.id]?.claudeSessionID = nil
                            state.workspaces[id: workspace.id]?.panes[id: pane.id]?.status = .idle
                        }
                    }
                }

                // Create surfaces for shell panes only (markdown panes use WKWebView)
                let panesToResume = resumablePanes
                let opacity = ghosttyConfig.backgroundOpacity
                let shellPanes: [(id: UUID, cwd: String)] = workspaces.flatMap { ws in
                    ws.panes.filter { $0.type == .shell }.map { (id: $0.id, cwd: $0.workingDirectory) }
                }
                return .merge(
                    .run { send in
                        for pane in shellPanes {
                            await surfaceManager.createSurface(
                                paneID: pane.id,
                                workingDirectory: pane.cwd,
                                backgroundOpacity: opacity
                            )
                        }

                        // Auto-resume Claude Code sessions after surfaces are ready.
                        // Persist AFTER sending resume commands so session IDs survive
                        // if the app crashes before the resume actually executes.
                        if !panesToResume.isEmpty {
                            try? await clock.sleep(for: .seconds(2))
                            for entry in panesToResume {
                                await surfaceManager.sendCommand(
                                    to: entry.paneID,
                                    command: "claude --resume \(entry.sessionID)"
                                )
                            }
                        }

                        // Now that resume commands have been sent, persist the cleared state
                        await send(.persistState)
                    },
                    .send(.refreshGitStatus),
                    .send(.startGitStatusTimer)
                )

            case .workspaces(.element(_, action: .agentStarted)):
                return .merge(
                    .send(.persistState),
                    .send(.updateExternalIndicators)
                )

            case .workspaces(.element(_, action: .agentStopped)):
                return .merge(
                    .send(.persistState),
                    .send(.updateExternalIndicators)
                )

            case .workspaces(.element(_, action: .agentError)):
                return .merge(
                    .send(.persistState),
                    .send(.updateExternalIndicators)
                )

            case .workspaces(.element(_, action: .sessionStarted)):
                return .merge(
                    .send(.persistState),
                    .send(.updateExternalIndicators)
                )

            case .workspaces(.element(_, action: .clearPaneStatus(let paneID))):
                let notifService = notificationService
                return .merge(
                    .send(.persistState),
                    .send(.updateExternalIndicators),
                    .run { _ in notifService.removeNotification(for: paneID) }
                )

            case .workspaces(.element(id: let wsID, action: .paneDirectoryChanged(let paneID, let directory))):
                return .merge(
                    .send(.persistState),
                    scheduleAutoLink(workspaceID: wsID, paneID: paneID, directory: directory, in: state),
                    scheduleAutoUnlink(workspaceID: wsID, in: state)
                )

            case .workspaces(.element(id: let wsID, action: .closePane)):
                if let renamingPaneID = state.renamingPaneID,
                   !state.workspaces.contains(where: { $0.panes[id: renamingPaneID] != nil }) {
                    state.renamingPaneID = nil
                }
                return .merge(
                    .send(.persistState),
                    scheduleAutoUnlink(workspaceID: wsID, in: state)
                )

            case .workspaces(.element(id: let wsID, action: .paneProcessTerminated)):
                if let renamingPaneID = state.renamingPaneID,
                   !state.workspaces.contains(where: { $0.panes[id: renamingPaneID] != nil }) {
                    state.renamingPaneID = nil
                }
                return .merge(
                    .send(.persistState),
                    scheduleAutoUnlink(workspaceID: wsID, in: state)
                )

            case .workspaces:
                // Child workspace actions — persist after mutations
                return .send(.persistState)

            case .settings:
                return .none

            // MARK: - Command Palette

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

            // MARK: - Keybindings

            case .keybindingsLoaded(let bindings):
                state.keybindings = bindings
                return .none

            case .setKeybinding(let trigger, let action):
                state.keybindings.setBinding(trigger: trigger, action: action)
                return .run { [keybindings = state.keybindings] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(keybindings, toFile: path)
                }

            case .removeKeybinding(let trigger):
                state.keybindings.removeBinding(trigger: trigger)
                return .run { [keybindings = state.keybindings] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(keybindings, toFile: path)
                }

            case .resetBindingsForAction(let action):
                state.keybindings.removeAllBindings(for: action)
                for trigger in KeyBindingMap.defaults.triggers(for: action) {
                    state.keybindings.setBinding(trigger: trigger, action: action)
                }
                return .run { [keybindings = state.keybindings] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(keybindings, toFile: path)
                }

            case .resetKeybindings:
                state.keybindings = .defaults
                return .run { _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(.defaults, toFile: path)
                }

            // MARK: - General Config

            case .configLoaded(
                let focusFollowsMouse,
                let focusFollowsMouseDelay,
                let themeID,
                let tcpPort,
                let globalHotkey,
                let globalHotkeyHideOnRepress
            ):
                state.focusFollowsMouse = focusFollowsMouse
                state.focusFollowsMouseDelay = focusFollowsMouseDelay
                state.tcpPort = tcpPort
                state.globalHotkey = globalHotkey
                state.globalHotkeyHideOnRepress = globalHotkeyHideOnRepress
                state.globalHotkeyRegistrationError = nil
                let themeEffect: Effect<Action> = {
                    if let themeID, let theme = NexTheme.named(themeID) {
                        return .send(.settings(.selectTheme(theme)))
                    }
                    return .none
                }()
                let hotkeyEffect: Effect<Action> = .run { [trigger = globalHotkey, service = globalHotkeyService] send in
                    do {
                        try await service.register(trigger)
                    } catch {
                        await send(.globalHotkeyRegistrationFailed(reason: "\(error)"))
                    }
                }
                return .merge(themeEffect, hotkeyEffect)

            case .setFocusFollowsMouse(let enabled):
                state.focusFollowsMouse = enabled
                return .run { _ in
                    let path = KeybindingService.configPath
                    ConfigParser.setGeneralSetting(
                        "focus-follows-mouse",
                        value: enabled ? "true" : "false",
                        inFile: path
                    )
                }

            case .setFocusFollowsMouseDelay(let ms):
                state.focusFollowsMouseDelay = max(0, ms)
                return .run { [delay = state.focusFollowsMouseDelay] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.setGeneralSetting(
                        "focus-follows-mouse-delay",
                        value: "\(delay)",
                        inFile: path
                    )
                }

            case .setTCPPort(let port):
                state.tcpPort = max(0, min(port, 65535))
                state.tcpPortError = nil
                return .run { [port = state.tcpPort] send in
                    socketServer.stopTCP()
                    if port > 0 {
                        let started = socketServer.startTCP(port: port)
                        if !started {
                            await send(.tcpPortStartFailed(port))
                            return
                        }
                    }
                    ConfigParser.setGeneralSetting(
                        "tcp-port",
                        value: "\(port)",
                        inFile: KeybindingService.configPath
                    )
                }

            case .tcpPortStartFailed(let port):
                state.tcpPortError = "Port \(port) is unavailable"
                return .none

            // MARK: - Global Hotkey

            case .setGlobalHotkey(let trigger):
                // Optimistically update state; if Carbon rejects the new
                // trigger, `globalHotkeyRegistrationRejected` will roll it
                // back to `previousTrigger` and the config file is left
                // untouched. The service keeps the previous registration
                // alive on failure, so the user's working hotkey is never
                // silently dropped.
                let previousTrigger = state.globalHotkey
                state.globalHotkey = trigger
                state.globalHotkeyRegistrationError = nil
                return .run { [trigger, previousTrigger, service = globalHotkeyService] send in
                    do {
                        try await service.register(trigger)
                    } catch {
                        await send(.globalHotkeyRegistrationRejected(
                            revertTo: previousTrigger,
                            reason: "\(error)"
                        ))
                        return
                    }
                    ConfigParser.setGeneralSetting(
                        "global-hotkey",
                        value: trigger?.configString ?? "none",
                        inFile: KeybindingService.configPath
                    )
                }

            case .setGlobalHotkeyHideOnRepress(let hide):
                state.globalHotkeyHideOnRepress = hide
                return .run { _ in
                    ConfigParser.setGeneralSetting(
                        "global-hotkey-hide-on-repress",
                        value: hide ? "true" : "false",
                        inFile: KeybindingService.configPath
                    )
                }

            case .globalHotkeyPressed:
                return .run { [hide = state.globalHotkeyHideOnRepress] _ in
                    await MainActor.run {
                        toggleAppFrontmost(hideOnRepress: hide)
                    }
                }

            case .globalHotkeyRegistrationFailed(let reason):
                // Used only by the config-load path — we want state to keep
                // reflecting what's in the config file so the user can see
                // and edit the failing value from Settings.
                state.globalHotkeyRegistrationError = reason
                return .none

            case .globalHotkeyRegistrationRejected(let revertTo, let reason):
                state.globalHotkey = revertTo
                state.globalHotkeyRegistrationError = reason
                return .none

            // MARK: - File Opening

            case .openFile:
                return .run { send in
                    let path: String? = await MainActor.run {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.message = "Choose a Markdown file to open"
                        if panel.runModal() == .OK, let url = panel.url {
                            return url.path
                        }
                        return nil
                    }
                    if let path {
                        await send(.openFileAtPath(path, fromPaneID: nil))
                    }
                }

            case .openFileAtPath(let path, let fromPaneID):
                guard let activeID = state.activeWorkspaceID else { return .none }
                var resolvedPath = path
                if !path.hasPrefix("/") {
                    let workspace = state.workspaces[id: activeID]
                    let cwd: String? = {
                        if let fromPaneID, let pane = workspace?.panes.first(where: { $0.id == fromPaneID }) {
                            return pane.workingDirectory
                        }
                        if let focusedID = workspace?.focusedPaneID,
                           let pane = workspace?.panes.first(where: { $0.id == focusedID }) {
                            return pane.workingDirectory
                        }
                        return nil
                    }()
                    if let cwd, !cwd.isEmpty {
                        resolvedPath = (cwd as NSString).appendingPathComponent(path)
                    }
                }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .openMarkdownFile(filePath: resolvedPath)
                )))

            // MARK: - Socket Messages

            case .socketMessage(let message, let reply):
                switch message {
                // MARK: Agent lifecycle

                case .agentStarted(let paneID):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }

                    // If we get a "start" while already running, the previous "stop"
                    // was missed (e.g. user interrupted Claude). Reset to idle first
                    // so the status lifecycle stays clean.
                    if workspace.panes[id: paneID]?.status == .running {
                        state.workspaces[id: workspace.id]?.panes[id: paneID]?.status = .idle
                    }

                    return .merge(
                        .send(.workspaces(.element(id: workspace.id, action: .agentStarted(paneID: paneID)))),
                        .send(.updateExternalIndicators)
                    )

                case .agentStopped(let paneID):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }

                    let isFocused = state.activeWorkspaceID == workspace.id && workspace.focusedPaneID == paneID
                    let notifService = notificationService
                    let wsID = workspace.id
                    let isAppActive = MainActor.assumeIsolated { NSApp.isActive }
                    let shouldNotify = !isFocused || !isAppActive
                    let shouldBounce = !isAppActive
                    let title = workspace.panes[id: paneID]?.title ?? workspace.name

                    return .merge(
                        .send(.workspaces(.element(id: workspace.id, action: .agentStopped(paneID: paneID)))),
                        .send(.updateExternalIndicators),
                        .run { _ in
                            if shouldNotify {
                                notifService.post(
                                    title: title,
                                    body: "Agent is waiting for input",
                                    paneID: paneID,
                                    workspaceID: wsID
                                )
                            }
                            if shouldBounce {
                                _ = await MainActor.run {
                                    NSApp.requestUserAttention(.informationalRequest)
                                }
                            }
                        }
                    )

                case .agentError(let paneID, let message):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }

                    let notifService = notificationService
                    let wsID = workspace.id

                    return .merge(
                        .send(.workspaces(.element(id: workspace.id, action: .agentError(paneID: paneID)))),
                        .send(.updateExternalIndicators),
                        .run { _ in
                            notifService.post(
                                title: "Agent Error",
                                body: message,
                                paneID: paneID,
                                workspaceID: wsID
                            )
                        }
                    )

                case .notification(let paneID, let title, let body):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }

                    let isFocused = state.activeWorkspaceID == workspace.id && workspace.focusedPaneID == paneID
                    let notifService = notificationService
                    let wsID = workspace.id
                    let isAppActive = MainActor.assumeIsolated { NSApp.isActive }

                    var effects: [Effect<Action>] = [
                        .send(.workspaces(.element(id: workspace.id, action: .agentStopped(paneID: paneID)))),
                        .send(.updateExternalIndicators)
                    ]
                    if !isFocused || !isAppActive {
                        effects.append(.run { _ in
                            notifService.post(title: title, body: body, paneID: paneID, workspaceID: wsID)
                        })
                    }
                    return .merge(effects)

                case .sessionStarted(let paneID, let sessionID):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }

                    return .merge(
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .sessionStarted(paneID: paneID, sessionID: sessionID)
                        ))),
                        .send(.updateExternalIndicators)
                    )

                // MARK: Pane commands

                case .paneSplit(let paneID, let direction, let path, let name, let target):
                    // Resolve which pane to split: target (by name/UUID) or pane_id
                    let sourcePaneID = Self.resolveTarget(target, from: paneID, state: state) ?? paneID
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: sourcePaneID] != nil })
                    else { return .none }
                    state.workspaces[id: workspace.id]?.focusedPaneID = sourcePaneID
                    if let path {
                        return .send(.workspaces(.element(
                            id: workspace.id,
                            action: .splitPaneAtPath(path, label: name, direction: direction ?? .horizontal)
                        )))
                    }
                    return .send(.workspaces(.element(
                        id: workspace.id,
                        action: .splitPane(direction: direction ?? .horizontal, sourcePaneID: sourcePaneID, label: name)
                    )))

                case .paneCreate(let paneID, let path, let name, let target):
                    let sourcePaneID = Self.resolveTarget(target, from: paneID, state: state) ?? paneID
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: sourcePaneID] != nil })
                    else { return .none }
                    state.workspaces[id: workspace.id]?.focusedPaneID = sourcePaneID
                    if let path {
                        return .send(.workspaces(.element(
                            id: workspace.id, action: .splitPaneAtPath(path, label: name)
                        )))
                    }
                    return .send(.workspaces(.element(
                        id: workspace.id,
                        action: .splitPane(direction: .horizontal, sourcePaneID: sourcePaneID, label: name)
                    )))

                case .paneClose(let paneID, let target, let workspaceFilter):
                    return handlePaneClose(
                        state: state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case .paneName(let paneID, let name):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    state.workspaces[id: workspace.id]?.panes[id: paneID]?.label = name.isEmpty ? nil : name
                    return .send(.persistState)

                case .paneSend(let paneID, let target, let text):
                    guard state.workspaces.first(where: { $0.panes[id: paneID] != nil }) != nil
                    else { return .none }

                    guard let resolvedID = Self.resolveTarget(target, from: paneID, state: state)
                    else { return .none }

                    let mgr = surfaceManager
                    return .run { _ in
                        await mgr.sendCommand(to: resolvedID, command: text)
                    }

                case .paneMove(let paneID, let direction):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    state.workspaces[id: workspace.id]?.focusedPaneID = paneID
                    return .send(.workspaces(.element(
                        id: workspace.id, action: .movePaneInDirection(direction)
                    )))

                case .paneMoveToWorkspace(let paneID, let toWorkspace, let create):
                    // Find source workspace
                    guard let sourceWS = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }

                    // Resolve target workspace
                    var targetWSID = Self.resolveWorkspace(toWorkspace, state: state)

                    // Auto-create if requested
                    if targetWSID == nil, create {
                        let newID = uuid()
                        let newWS = WorkspaceFeature.State(
                            id: newID, name: toWorkspace,
                            slug: WorkspaceFeature.State.makeSlug(from: toWorkspace, id: newID),
                            color: state.workspaces.nextRandomColor(), panes: [], layout: .empty,
                            focusedPaneID: nil, createdAt: Date(), lastAccessedAt: Date()
                        )
                        state.workspaces.append(newWS)
                        state.topLevelOrder.append(.workspace(newID))
                        targetWSID = newID
                    }

                    guard let targetWSID, targetWSID != sourceWS.id else { return .none }
                    guard let pane = sourceWS.panes[id: paneID] else { return .none }

                    let sourceWSID = sourceWS.id

                    // Remove from source
                    state.workspaces[id: sourceWSID]?.panes.remove(id: paneID)
                    let newSourceLayout = state.workspaces[id: sourceWSID]!.layout.removing(paneID: paneID)
                    state.workspaces[id: sourceWSID]?.layout = newSourceLayout
                    state.workspaces[id: sourceWSID]?.currentLayoutIndex = nil

                    if state.workspaces[id: sourceWSID]?.focusedPaneID == paneID {
                        state.workspaces[id: sourceWSID]?.focusedPaneID = newSourceLayout.allPaneIDs.first
                    }
                    if state.workspaces[id: sourceWSID]?.searchingPaneID == paneID {
                        state.workspaces[id: sourceWSID]?.searchingPaneID = nil
                        state.workspaces[id: sourceWSID]?.searchNeedle = ""
                    }
                    if state.workspaces[id: sourceWSID]?.zoomedPaneID == paneID {
                        if let saved = state.workspaces[id: sourceWSID]?.savedLayout {
                            state.workspaces[id: sourceWSID]?.layout = saved.removing(paneID: paneID)
                        }
                        state.workspaces[id: sourceWSID]?.zoomedPaneID = nil
                        state.workspaces[id: sourceWSID]?.savedLayout = nil
                    }

                    // Add to target
                    state.workspaces[id: targetWSID]?.panes.append(pane)

                    let targetLayout = state.workspaces[id: targetWSID]?.layout ?? .empty
                    if targetLayout.isEmpty {
                        state.workspaces[id: targetWSID]?.layout = .leaf(paneID)
                    } else {
                        let anchorID = state.workspaces[id: targetWSID]?.focusedPaneID
                            ?? targetLayout.allPaneIDs.first
                        if let anchorID {
                            let newLayout = targetLayout.splitting(
                                paneID: anchorID, direction: .horizontal, newPaneID: paneID
                            ).layout
                            state.workspaces[id: targetWSID]?.layout = newLayout
                        }
                    }

                    state.workspaces[id: targetWSID]?.focusedPaneID = paneID
                    state.workspaces[id: targetWSID]?.currentLayoutIndex = nil
                    state.activeWorkspaceID = targetWSID

                    return .send(.persistState)

                // MARK: Workspace commands

                case .workspaceCreate(let name, let path, let color, let group):
                    return handleSocketWorkspaceCreate(
                        &state,
                        name: name,
                        path: path,
                        color: color,
                        group: group
                    )

                case .workspaceMove(let nameOrID, let group, let index):
                    return handleSocketWorkspaceMove(
                        &state,
                        nameOrID: nameOrID,
                        group: group,
                        index: index
                    )

                case .groupCreate(let name, let color):
                    return handleSocketGroupCreate(&state, name: name, color: color)

                case .groupRename(let nameOrID, let newName):
                    guard let group = state.resolveGroup(nameOrID) else { return .none }
                    return .send(.renameGroup(id: group.id, name: newName))

                case .groupDelete(let nameOrID, let cascade):
                    guard let group = state.resolveGroup(nameOrID) else { return .none }
                    return .send(.deleteGroup(id: group.id, cascade: cascade))

                // MARK: File commands

                case .openFile(let path, let paneID):
                    if let paneID,
                       let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
                        state.workspaces[id: workspace.id]?.focusedPaneID = paneID
                        return .send(.workspaces(.element(
                            id: workspace.id,
                            action: .openMarkdownFile(filePath: path)
                        )))
                    }
                    guard let activeID = state.activeWorkspaceID else { return .none }
                    return .send(.workspaces(.element(
                        id: activeID,
                        action: .openMarkdownFile(filePath: path)
                    )))

                // MARK: Layout commands

                case .layoutCycle(let paneID):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    return .send(.workspaces(.element(id: workspace.id, action: .cycleLayout)))

                case .layoutSelect(let paneID, let name):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }),
                          let layout = PredefinedLayout(rawValue: name)
                    else { return .none }
                    return .send(.workspaces(.element(id: workspace.id, action: .selectLayout(layout))))

                // MARK: Request / response

                case .paneList(let paneID, let workspaceFilter, let scope):
                    handlePaneList(
                        state: state,
                        paneID: paneID,
                        workspaceFilter: workspaceFilter,
                        scope: scope,
                        reply: reply
                    )
                    return .none
                }

            // MARK: - Cross-Workspace Surface Notifications

            case .surfaceTitleChanged(let paneID, let title):
                guard let workspace = state.workspaces.first(where: { ws in
                    ws.panes[id: paneID] != nil
                }) else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .paneTitleChanged(paneID: paneID, title: title)
                )))

            case .surfaceDirectoryChanged(let paneID, let directory):
                guard let workspace = state.workspaces.first(where: { ws in
                    ws.panes[id: paneID] != nil
                }) else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .paneDirectoryChanged(paneID: paneID, directory: directory)
                )))

            case .surfaceProcessExited(let paneID):
                guard let workspace = state.workspaces.first(where: { ws in
                    ws.panes[id: paneID] != nil
                }) else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .paneProcessTerminated(paneID: paneID)
                )))

            // MARK: - Desktop Notifications (OSC)

            case .desktopNotification(let paneID, let title, let body):
                // Suppress if this pane is focused and app is active
                if let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }),
                   state.activeWorkspaceID == workspace.id,
                   workspace.focusedPaneID == paneID,
                   MainActor.assumeIsolated({ NSApp.isActive }) {
                    return .none
                }
                let notifService = notificationService
                return .run { _ in
                    notifService.post(title: title, body: body, paneID: paneID)
                }

            // MARK: - Repo Registry

            case .scanForRepos(let rootPath):
                return .run { send in
                    let repos = try await gitService.scanForRepos(rootPath, 3)
                    await send(.scanCompleted(repos))
                }

            case .scanCompleted(let scannedRepos):
                var effects: [Effect<Action>] = []
                for scanned in scannedRepos {
                    // Skip repos already in registry
                    if state.repoRegistry.contains(where: { $0.path == scanned.path }) {
                        continue
                    }
                    effects.append(.send(.addRepo(path: scanned.path, name: scanned.name)))
                }
                return effects.isEmpty ? .none : .merge(effects)

            case .addRepo(let path, let name):
                // If the repo is already in the registry, promote it out of
                // auto-discovered status so it survives GC when panes leave
                // it.
                if let existing = state.repoRegistry.first(where: { $0.path == path }) {
                    if existing.isAutoDiscovered {
                        state.repoRegistry[id: existing.id]?.isAutoDiscovered = false
                        return .send(.persistState)
                    }
                    return .none
                }
                let repoID = uuid()
                return .run { send in
                    let remoteURL = try? await gitService.getRemoteURL(path)
                    let repo = Repo(
                        id: repoID,
                        path: path,
                        name: name,
                        remoteURL: remoteURL
                    )
                    await send(.repoAdded(repo))
                }

            case .repoAdded(let repo):
                state.repoRegistry.append(repo)
                return .send(.persistState)

            case .removeRepo(let id):
                state.repoRegistry.remove(id: id)
                // Cascade-remove associations from all workspaces
                for wsIndex in state.workspaces.indices {
                    state.workspaces[wsIndex].repoAssociations.removeAll(where: { $0.repoID == id })
                }
                return .send(.persistState)

            case .renameRepo(let id, let name):
                state.repoRegistry[id: id]?.name = name
                return .send(.persistState)

            // MARK: - Worktree Operations

            case .createWorktree(let workspaceID, let repoID, let worktreeName, let branchName):
                guard let repo = state.repoRegistry[id: repoID],
                      state.workspaces[id: workspaceID] != nil else { return .none }
                let basePath = state.settings.resolvedWorktreeBasePath(forRepoPath: repo.path)
                let worktreePath = "\(basePath)/\(worktreeName)"
                return .run { send in
                    do {
                        try await gitService.createWorktree(repo.path, worktreePath, branchName)
                        await send(.worktreeCreated(
                            workspaceID: workspaceID,
                            repoID: repoID,
                            worktreePath: worktreePath,
                            branchName: branchName
                        ))
                    } catch {
                        await send(.worktreeCreationFailed(
                            workspaceID: workspaceID,
                            error: error.localizedDescription
                        ))
                    }
                }

            case .worktreeCreated(let workspaceID, let repoID, let worktreePath, let branchName):
                let assoc = RepoAssociation(
                    id: uuid(),
                    repoID: repoID,
                    worktreePath: worktreePath,
                    branchName: branchName
                )
                state.workspaces[id: workspaceID]?.repoAssociations.append(assoc)
                // A manual worktree flow promotes the repo out of
                // auto-discovered status.
                state.repoRegistry[id: repoID]?.isAutoDiscovered = false
                return .merge(
                    .send(.persistState),
                    .send(.refreshGitStatus)
                )

            case .worktreeCreationFailed:
                // UI can observe this for error display
                return .none

            case .removeWorktreeAssociation(let workspaceID, let associationID, let deleteWorktree):
                guard let workspace = state.workspaces[id: workspaceID],
                      let assoc = workspace.repoAssociations[id: associationID],
                      let repo = state.repoRegistry[id: assoc.repoID] else { return .none }

                state.workspaces[id: workspaceID]?.repoAssociations.remove(id: associationID)
                state.gitStatuses.removeValue(forKey: associationID)

                if deleteWorktree {
                    return .merge(
                        .run { _ in
                            try? await gitService.removeWorktree(repo.path, assoc.worktreePath)
                        },
                        .send(.persistState)
                    )
                }
                return .send(.persistState)

            // MARK: - Auto-Detected Repo Associations

            case .autoLinkRepoForPane(let workspaceID, let paneID, let directory):
                // Re-check the setting and workspace at dispatch time. The
                // scheduling side also guards, but the user may have toggled
                // the setting off during the 500ms debounce.
                guard state.settings.autoDetectRepos,
                      let workspace = state.workspaces[id: workspaceID],
                      workspace.panes[id: paneID]?.workingDirectory == directory
                else { return .none }
                return .run { send in
                    if let info = await gitService.resolveRepoRoot(directory) {
                        await send(.autoLinkResolved(
                            workspaceID: workspaceID,
                            paneID: paneID,
                            info: info
                        ))
                    }
                }
                .cancellable(id: AutoLinkResolveID.pane(paneID), cancelInFlight: true)

            case .autoLinkResolved(let workspaceID, let paneID, let info):
                // The async git resolution may have raced with: setting
                // toggled off, workspace deleted, pane closed, or pane `cd`-ed
                // out of the resolved worktree. Skip in all those cases so we
                // don't silently create a stale association.
                guard state.settings.autoDetectRepos,
                      let workspace = state.workspaces[id: workspaceID],
                      let pane = workspace.panes[id: paneID]
                else { return .none }

                let pwd = (pane.workingDirectory as NSString).standardizingPath
                let worktreeRoot = (info.worktreeRoot as NSString).standardizingPath
                let stillInside = pwd == worktreeRoot || pwd.hasPrefix(worktreeRoot + "/")
                guard stillInside else { return .none }

                // Find or create the parent Repo entry.
                let repoID: UUID
                var addedRepo = false
                if let existing = state.repoRegistry.first(where: { $0.path == info.parentRepoRoot }) {
                    repoID = existing.id
                } else {
                    let newID = uuid()
                    let repo = Repo(
                        id: newID,
                        path: info.parentRepoRoot,
                        name: (info.parentRepoRoot as NSString).lastPathComponent,
                        isAutoDiscovered: true
                    )
                    state.repoRegistry.append(repo)
                    repoID = newID
                    addedRepo = true
                }

                // Skip if an association for this worktree already exists.
                let alreadyLinked = workspace.repoAssociations
                    .contains(where: { $0.worktreePath == info.worktreeRoot })

                var effects: [Effect<Action>] = []

                if !alreadyLinked {
                    let assoc = RepoAssociation(
                        id: uuid(),
                        repoID: repoID,
                        worktreePath: info.worktreeRoot,
                        branchName: nil,
                        isAutoDetected: true
                    )
                    state.workspaces[id: workspaceID]?.repoAssociations.append(assoc)

                    let assocID = assoc.id
                    let resolvedWorktree = info.worktreeRoot
                    effects.append(
                        .run { [gitService] send in
                            let branch = try? await gitService.getCurrentBranch(resolvedWorktree)
                            let status = await (try? gitService.getStatus(resolvedWorktree)) ?? .unknown
                            await send(.gitStatusUpdated(associationID: assocID, status: status))
                            await send(.repoAssociationBranchResolved(
                                workspaceID: workspaceID,
                                associationID: assocID,
                                branch: branch
                            ))
                        }
                    )
                }

                if addedRepo {
                    let parentRepoPath = info.parentRepoRoot
                    effects.append(
                        .run { [gitService] send in
                            let url = try? await gitService.getRemoteURL(parentRepoPath)
                            await send(.repoRemoteURLResolved(repoID: repoID, remoteURL: url))
                        }
                    )
                }

                // One persistState coalesces all the above via the persistence
                // debounce — the branch/url follow-ups reuse it.
                if !alreadyLinked || addedRepo {
                    effects.append(.send(.persistState))
                }
                return effects.isEmpty ? .none : .merge(effects)

            case .autoUnlinkUnusedRepos(let workspaceID):
                guard let workspace = state.workspaces[id: workspaceID] else { return .none }

                let candidateIDs: [UUID] = workspace.repoAssociations
                    .filter(\.isAutoDetected)
                    .map(\.id)

                guard !candidateIDs.isEmpty else { return .none }

                let panePaths = workspace.panes.map(\.workingDirectory)

                func isPathInside(_ path: String, _ root: String) -> Bool {
                    let p = (path as NSString).standardizingPath
                    let r = (root as NSString).standardizingPath
                    if p == r { return true }
                    return p.hasPrefix(r + "/")
                }

                var removedRepoIDs: Set<UUID> = []
                for assocID in candidateIDs {
                    guard let assoc = state.workspaces[id: workspaceID]?
                        .repoAssociations[id: assocID] else { continue }
                    let stillInUse = panePaths.contains { isPathInside($0, assoc.worktreePath) }
                    if !stillInUse {
                        state.workspaces[id: workspaceID]?.repoAssociations.remove(id: assocID)
                        state.gitStatuses.removeValue(forKey: assocID)
                        removedRepoIDs.insert(assoc.repoID)
                    }
                }

                // GC auto-discovered repos with no remaining associations
                // across any workspace. Manually-added repos (isAutoDiscovered
                // == false) are never removed here.
                for repoID in removedRepoIDs {
                    guard let repo = state.repoRegistry[id: repoID],
                          repo.isAutoDiscovered else { continue }
                    let stillReferenced = state.workspaces.contains { ws in
                        ws.repoAssociations.contains(where: { $0.repoID == repoID })
                    }
                    if !stillReferenced {
                        state.repoRegistry.remove(id: repoID)
                    }
                }

                return removedRepoIDs.isEmpty ? .none : .send(.persistState)

            case .repoRemoteURLResolved(let repoID, let url):
                state.repoRegistry[id: repoID]?.remoteURL = url
                return .send(.persistState)

            case .repoAssociationBranchResolved(let workspaceID, let associationID, let branch):
                state.workspaces[id: workspaceID]?
                    .repoAssociations[id: associationID]?
                    .branchName = branch
                return .send(.persistState)

            // MARK: - Inspector + Git Status

            case .toggleInspector:
                state.isInspectorVisible.toggle()
                if state.isInspectorVisible {
                    return .send(.refreshGitStatus)
                }
                return .none

            case .refreshGitStatus:
                guard let activeID = state.activeWorkspaceID,
                      let workspace = state.workspaces[id: activeID] else { return .none }

                let associations = workspace.repoAssociations
                guard !associations.isEmpty else { return .none }

                return .run { send in
                    for assoc in associations {
                        let status = await (try? gitService.getStatus(assoc.worktreePath)) ?? .unknown
                        await send(.gitStatusUpdated(associationID: assoc.id, status: status))
                    }
                }

            case .gitStatusUpdated(let associationID, let status):
                state.gitStatuses[associationID] = status
                return .none

            case .startGitStatusTimer:
                return .run { send in
                    for await _ in clock.timer(interval: .seconds(30)) {
                        await send(.refreshGitStatus)
                    }
                }
                .cancellable(id: GitStatusTimerID.timer, cancelInFlight: true)

            // MARK: - Search

            case .ghosttySearchStarted(let paneID, let needle):
                guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .ghosttySearchStarted(paneID: paneID, needle: needle)
                )))

            case .ghosttySearchEnded(let paneID):
                guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .ghosttySearchEnded(paneID: paneID)
                )))

            case .searchTotalUpdated(let paneID, let total):
                guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .searchTotalUpdated(paneID: paneID, total: total)
                )))

            case .searchSelectedUpdated(let paneID, let selected):
                guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .searchSelectedUpdated(paneID: paneID, selected: selected)
                )))

            // MARK: - External Indicators

            case .updateExternalIndicators:
                var totalWaiting = 0
                var totalRunning = 0
                var statusItems: [StatusBarItem] = []

                for workspace in state.workspaces {
                    for pane in workspace.panes {
                        switch pane.status {
                        case .waitingForInput:
                            totalWaiting += 1
                            statusItems.append(StatusBarItem(
                                workspaceName: workspace.name,
                                workspaceColor: workspace.color,
                                paneTitle: pane.title ?? "Shell",
                                paneID: pane.id,
                                workspaceID: workspace.id,
                                status: pane.status
                            ))
                        case .running:
                            totalRunning += 1
                            statusItems.append(StatusBarItem(
                                workspaceName: workspace.name,
                                workspaceColor: workspace.color,
                                paneTitle: pane.title ?? "Shell",
                                paneID: pane.id,
                                workspaceID: workspace.id,
                                status: pane.status
                            ))
                        case .idle:
                            break
                        }
                    }
                }

                let controller = statusBarController
                let finalWaiting = totalWaiting
                let finalRunning = totalRunning
                let finalItems = statusItems
                return .run { _ in
                    await MainActor.run {
                        controller.update(
                            waitingCount: finalWaiting,
                            runningCount: finalRunning,
                            items: finalItems
                        )
                        if finalWaiting > 0 {
                            NSApp.dockTile.badgeLabel = "\(finalWaiting)"
                        } else {
                            NSApp.dockTile.badgeLabel = nil
                        }
                    }
                }
            }
        }
        .forEach(\.workspaces, action: \.workspaces) {
            WorkspaceFeature()
        }

        Scope(state: \.settings, action: \.settings) {
            SettingsFeature()
        }
    }

    /// Resolve a workspace target string (UUID, name, or slug) to a workspace UUID.
    private static func resolveWorkspace(
        _ target: String,
        state: State
    ) -> UUID? {
        if let uuid = UUID(uuidString: target), state.workspaces[id: uuid] != nil {
            return uuid
        }
        if let ws = state.workspaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(target) == .orderedSame
        }) {
            return ws.id
        }
        if let ws = state.workspaces.first(where: { $0.slug == target }) {
            return ws.id
        }
        return nil
    }

    /// Resolve a target string (UUID or pane label) to a pane UUID.
    /// Searches by UUID first, then label in the originating pane's workspace,
    /// then label across all workspaces. `originPaneID` is optional so
    /// commands invoked from outside a Nex pane (e.g. `nex pane close
    /// --target <label>`) can still resolve by label.
    ///
    /// The global fallback requires exactly one match — if a label
    /// collides across workspaces the caller would otherwise mutate
    /// an arbitrary pane (state-order dependent). Returning nil lets
    /// the caller decide how to handle it: `paneClose` / `paneSend`
    /// no-op, `paneSplit` / `paneCreate` fall back to the caller's
    /// own pane via `?? paneID`.
    private static func resolveTarget(
        _ target: String?,
        from originPaneID: UUID?,
        state: State
    ) -> UUID? {
        guard let target, !target.isEmpty else { return nil }
        if let uuid = UUID(uuidString: target) { return uuid }
        if let originPaneID,
           let originWorkspace = state.workspaces.first(where: { $0.panes[id: originPaneID] != nil }),
           let match = originWorkspace.panes.first(where: { $0.label == target }) {
            return match.id
        }
        let globalMatches = state.workspaces.flatMap(\.panes).filter { $0.label == target }
        return globalMatches.count == 1 ? globalMatches[0].id : nil
    }
}
