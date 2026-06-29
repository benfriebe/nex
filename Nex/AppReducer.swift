import AppKit
import ComposableArchitecture
import Foundation
import SwiftUI
import WebKit

/// A finished agent run, captured when its waiting-for-input state is cleared.
/// Backs the footer's "done" hover detail. Session-scoped; not persisted.
struct CompletedAgent: Equatable {
    let workspaceName: String
    let workspaceColor: WorkspaceColor
    let paneTitle: String
    let completedAt: Date
}

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
        var workspaceCustomEmojiPrompt: WorkspaceCustomEmojiPrompt?
        var selectedWorkspaceIDs: Set<UUID> = []
        var lastSelectionAnchor: UUID?
        var bulkDeleteConfirmationIDs: [UUID]?
        var settings = SettingsFeature.State()
        var graft = GraftFeature.State()
        var repoRegistry: IdentifiedArrayOf<Repo> = []
        var gitStatuses: [UUID: RepoGitStatus] = [:]
        var isInspectorVisible: Bool = false
        /// Running tally of agent runs whose waiting-for-input state was
        /// cleared this session (an acknowledged finished turn). Drives the
        /// status bar's "N done". Session-scoped, intentionally not persisted.
        var completedAgentCount: Int = 0
        /// Recent finished agents (newest first, capped), captured at the same
        /// moment `completedAgentCount` increments — backs the "done" hover
        /// detail. Session-scoped, not persisted.
        var completedAgents: [CompletedAgent] = []
        var keybindings: KeyBindingMap = .defaults
        var focusFollowsMouse: Bool = false
        var focusFollowsMouseDelay: Int = 100
        var tcpPort: Int = 0
        var tcpPortError: String?
        var globalHotkey: KeyTrigger?
        var globalHotkeyHideOnRepress: Bool = true
        var globalHotkeyRegistrationError: String?

        /// Per-web-pane monotonic counter used as the URL bar focus
        /// token. The priority key layer bumps this when ⌘L fires on
        /// a focused web pane; `WebPaneView` picks up the change and
        /// promotes its URL bar to first responder.
        var webPaneURLFocusTokens: [UUID: UInt64] = [:]
        /// Phase 3: per-pane "submit after paste" flag set at arm
        /// time by `nex web inspect --submit`. Kept on AppReducer
        /// (rather than WebPaneState) because it's purely a hint to
        /// the in-flight `paneSendText` call after the next click —
        /// not state worth surfacing to the view layer or persisting.
        var webInspectArmedSubmit: [UUID: Bool] = [:]

        var favourites: [Favourite] = []

        /// User-defined workspace label presets (name + color). A flat
        /// global list, persisted in UserDefaults like `favourites`. Used
        /// to offer canned labels in the inspector and to tint chips whose
        /// text matches a preset name.
        var labelPresets: [LabelPreset] = []

        /// One-time label→preset migration runs once both the workspaces and
        /// the (UserDefaults) presets have loaded — they load concurrently, so
        /// each completion sets its flag and triggers the migration when both
        /// are ready.
        var didRestoreWorkspaces = false
        var didLoadLabelPresets = false

        /// Color for a workspace label string, or nil when no preset
        /// matches (chip renders in the neutral free-form style). Match is
        /// exact and case-sensitive, mirroring how `addLabel` stores
        /// labels (trim/clamp only, no lowercasing).
        func colorForLabel(_ label: String) -> LabelColor? {
            labelPresets.color(for: label)
        }

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

        /// Summary of in-progress agents across all workspaces, used by
        /// the quit-confirmation dialog (issue #129). An "active agent"
        /// is any pane whose status is `.running` or `.waitingForInput`.
        /// Idle panes, markdown previews, scratchpads, and diff panes
        /// always have `.idle` status and so are never counted.
        ///
        /// Parked panes (source shells hidden by `nex open --here`) are
        /// included: their PTYs and agents are still alive and would be
        /// terminated alongside the visible panes.
        var activeAgentSummary: ActivitySummary {
            var agentCount = 0
            var workspaceCount = 0
            for workspace in workspaces {
                let visible = workspace.panes.reduce(into: 0) { acc, pane in
                    if pane.status != .idle { acc += 1 }
                }
                let parked = workspace.parkedPanes.reduce(into: 0) { acc, pane in
                    if pane.status != .idle { acc += 1 }
                }
                let count = visible + parked
                if count > 0 {
                    agentCount += count
                    workspaceCount += 1
                }
            }
            return ActivitySummary(agentCount: agentCount, workspaceCount: workspaceCount)
        }

        /// Cross-workspace agent counts for the bottom status bar. Reading
        /// this inside a tracked view registers a dependency on `workspaces`
        /// + `completedAgentCount`, so the footer re-bodies on any status
        /// change (Release-safe when read from a distinct child view).
        var chromeStatusSummary: ChromeStatusSummary {
            var summary = ChromeStatusSummary()
            for workspace in workspaces {
                for pane in workspace.panes {
                    switch pane.status {
                    case .running: summary.running += 1
                    case .waitingForInput: summary.waiting += 1
                    case .idle: break
                    }
                }
            }
            summary.done = completedAgentCount
            return summary
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
                    case .diff: "plusminus"
                    case .web: "globe"
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
            var query = Substring(commandPaletteQuery.lowercased()).drop(while: \.isWhitespace)
            let scopedItems: [CommandPaletteItem]
            if query.hasPrefix("w:") {
                query = query.dropFirst(2)
                scopedItems = items.filter { $0.paneID == nil }
            } else if query.hasPrefix("p:") {
                query = query.dropFirst(2)
                scopedItems = items.filter { $0.paneID != nil }
            } else {
                scopedItems = items
            }
            let terms = query.split(separator: " ").filter { !$0.isEmpty }
            guard !terms.isEmpty else { return scopedItems }
            return scopedItems.filter { item in
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

        /// Locate the workspace owning a pane, checking both the
        /// visible layout and the parked lane. Used by surface/agent
        /// lifecycle routing so events on shells parked by
        /// `nex open --here` aren't dropped. User-command routing
        /// (pane send, split, close, etc.) intentionally searches
        /// only `panes` — parked panes are not user-addressable.
        func workspaceContainingPane(_ paneID: UUID) -> WorkspaceFeature.State? {
            workspaces.first(where: {
                $0.panes[id: paneID] != nil || $0.parkedPanes[id: paneID] != nil
            })
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
        case setWorkspaceIcon(id: UUID, icon: GroupIcon?)
        case requestWorkspaceCustomEmoji(UUID)
        case cancelWorkspaceCustomEmoji
        case confirmWorkspaceCustomEmoji(String)
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
        case graft(GraftFeature.Action)

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
        case openDiffPath(repoPath: String, targetPath: String?, fromPaneID: UUID?)
        /// Open a web pane in the active workspace.
        case openWebPanePath(url: String, fromPaneID: UUID?)
        /// Bump the URL bar focus token for a web pane (⌘L).
        case webPaneFocusURLBar(paneID: UUID)
        /// Open a new tab in an existing web pane. `url == nil` →
        /// blank tab. Allocates the tab id here so the priority key
        /// path (⌘T) and CLI (`nex web tab-new`) share one entry point.
        case webPaneOpenNewTab(paneID: UUID, url: String?)
        /// Cycle tabs in the focused web pane. `+1` = next, `-1` = prev.
        case webPaneTabCycleFocused(offset: Int)
        /// Close the active tab in the focused web pane. Falls
        /// through to the workspace's closePane when only one tab
        /// remains.
        case webPaneTabCloseActiveFocused
        /// Sanitised inspect payload from the picker. Dispatched by
        /// `ContentView` (after running the raw dictionary through
        /// `InspectPayloadSanitiser.decode`). The reducer queues the
        /// result on the pane and, if a pending `--send-to` is set,
        /// pastes the formatted text into the destination pane via
        /// `paneSendText`.
        case webInspectPayloadReceived(paneID: UUID, result: InspectResult)
        /// Stash whether the current inspect arm should submit (press
        /// Enter) after the delivered paste. Cleared after every
        /// delivery. Phase 3 ships paste-only by default.
        case setWebInspectArmedSubmit(paneID: UUID, submit: Bool)
        /// Begin a batch-annotate session for `paneID`. Arms the
        /// picker in sticky mode so each click adds another item;
        /// the user finalises via `webBatchInspectSend` or aborts
        /// via `webBatchInspectCancel`. Destination is picked at
        /// send time via the panel's footer dropdown.
        case webBatchInspectStart(paneID: UUID)
        /// Hide the batch panel without discarding items. Disarms
        /// the page picker but leaves `batchInspect` in state so the
        /// next scope-toggle re-opens with the same queue + markers.
        case webBatchInspectHide(paneID: UUID)
        /// Re-show a hidden batch panel. Re-arms the picker and
        /// re-paints the on-page markers from the current items.
        case webBatchInspectShow(paneID: UUID)
        /// Toggle from the chrome scope button — routes to start /
        /// hide / show based on current state.
        case webBatchInspectToggle(paneID: UUID)
        /// Format collected items and paste them into `sendTo` (or
        /// queue locally for `nex web inspect-result` when nil), then
        /// disarm and clear batch state.
        case webBatchInspectSend(paneID: UUID, sendTo: UUID?)
        case webBatchInspectCancel(paneID: UUID)
        /// Set the per-pane private flag. `enabled: nil` flips the
        /// current value (UI toggle); a concrete value matches the CLI
        /// `nex web private on|off` path. The reducer destroys the
        /// pane's coordinator so the next SwiftUI pass rebuilds tabs
        /// against the new data store. Live JS state is lost; the
        /// chrome warns the user before sending this.
        case webPaneSetPrivate(paneID: UUID, enabled: Bool?)
        /// Focus a batch item from either side of the list↔page sync.
        /// `origin == .panel` came from a panel-row tap → highlight
        /// the badge on the page. `origin == .page` came from a
        /// page-marker click → highlight the row in the panel only
        /// (no need to scroll the page again).
        case webBatchFocusItem(paneID: UUID, itemID: UUID, origin: BatchFocusOrigin)
        /// Push the current batch's marker list to the page after a
        /// state change. Internal — fired from reducers that mutate
        /// the items / batch state.
        case syncBatchMarkers(paneID: UUID)
        /// Push a single comment edit from the panel side into the
        /// page popover. The JS skips the update if its textarea is
        /// currently focused so the user's caret stays put.
        case pushBatchCommentToPage(paneID: UUID, itemID: UUID, comment: String)
        /// User clicked Done (or pressed Esc) in the page popover.
        /// Clears the focused-item highlight (panel side) and hides
        /// the popover + focus ring (page side).
        case webBatchDismissPopover(paneID: UUID)

        // MARK: - Web favourites

        case favouritesLoaded([Favourite])
        case removeFavourite(id: UUID)
        case renameFavourite(id: UUID, title: String)
        case moveFavourite(fromIndex: Int, toIndex: Int)
        /// Star toggle: add when missing, remove when present.
        /// URL match is case-insensitive with trailing-slash stripped.
        case toggleFavourite(url: String, title: String)

        // MARK: - Label presets

        case labelPresetsLoaded([LabelPreset])
        /// Back-fill a preset (default colour) for every existing workspace
        /// label that predates the presets feature, so they survive being
        /// unapplied. Runs once both workspaces + presets have loaded.
        case migrateLabelsToPresets
        /// Add a preset. Name is normalized (trim/clamp); empty or a
        /// case-sensitive duplicate name is ignored.
        case addLabelPreset(name: String, color: LabelColor)
        /// Edit a preset addressed by its current name. Renaming to
        /// collide with another preset's name is ignored.
        case updateLabelPreset(id: String, name: String, color: LabelColor)
        /// Set (or clear, with nil = auto black/white) a preset's text colour.
        case setLabelPresetTextColor(id: String, textColor: LabelColor?)
        case removeLabelPreset(id: String)
        case moveLabelPreset(fromIndex: Int, toIndex: Int)

        // Inspector + Git Status
        case toggleInspector
        case refreshGitStatus
        case gitStatusUpdated(associationID: UUID, status: RepoGitStatus)
        case startGitStatusTimer
        case startHeadWatcher(workspaceID: UUID, associationID: UUID, worktreePath: String)
        case stopHeadWatcher(associationID: UUID)
        case headChanged(workspaceID: UUID, associationID: UUID)

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
        case restartSocketServer

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
    @Dependency(\.gitHeadWatcher) var gitHeadWatcher
    @Dependency(\.socketServer) var socketServer
    @Dependency(\.notificationService) var notificationService
    @Dependency(\.statusBarController) var statusBarController
    @Dependency(\.ghosttyConfig) var ghosttyConfig
    @Dependency(\.globalHotkeyService) var globalHotkeyService
    @Dependency(\.graftService) var graftService
    @Dependency(\.webPaneStore) var webPaneStore
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock
    @Dependency(\.userDefaults) var userDefaults

    private enum GitStatusTimerID: Hashable { case timer }
    private enum AutoLinkResolveID: Hashable { case pane(UUID) }
    private enum AutoLinkDebounceID: Hashable { case pane(UUID) }
    private enum AutoUnlinkDebounceID: Hashable { case workspace(UUID) }
    private enum PaletteFocusID: Hashable { case pending }
    private enum HeadWatcherID: Hashable { case association(UUID) }
    private enum HeadChangedDebounceID: Hashable { case association(UUID) }

    /// Debounce for `headChanged` effects. `git checkout` typically writes
    /// HEAD via temp file + atomic rename, which can fire two events back
    /// to back. Coalesce them so we only run `git status` + branch resolve
    /// once per logical checkout.
    static let headChangedDebounce: Duration = .milliseconds(150)

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

    private func persistFavourites(_ favourites: [Favourite]) -> Effect<Action> {
        let json = FavouritesStorage.encode(favourites)
        return .run { [userDefaults] _ in
            userDefaults.setString(json, FavouritesStorage.defaultsKey)
        }
    }

    private func persistLabelPresets(_ presets: [LabelPreset]) -> Effect<Action> {
        // Write immediately (like favourites) rather than debouncing: a
        // debounce would drop a preset add/remove/rename made within the
        // window of a Cmd-Q (the effect is cancelled on terminate). The
        // colour-picker drag that motivated a debounce only produces cheap,
        // off-main, cfprefsd-coalesced UserDefaults writes anyway.
        let json = LabelPresetsStorage.encode(presets)
        return .run { [userDefaults] _ in
            userDefaults.setString(json, LabelPresetsStorage.defaultsKey)
        }
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
                if let sessionID = pane.agentSessionID { entry["agent_session_id"] = sessionID }
                if let filePath = pane.filePath { entry["file_path"] = filePath }
                panes.append(entry)
            }
        }

        reply.send(["ok": true, "panes": panes])
        reply.close()
    }

    /// Result of `resolvePaneTarget`. The error case carries a
    /// human-readable string safe to surface in a `{ok:false,error:...}` reply.
    enum PaneTargetResolution {
        case found(paneID: UUID, workspace: WorkspaceFeature.State)
        case error(String)
    }

    /// Resolve a pane-targeting request (paneID + target + workspace
    /// filter) to a concrete pane and its containing workspace.
    ///
    /// Precedence: when both `paneID` and `target` are supplied, `target`
    /// wins (documented contract). Label lookups prefer the origin
    /// workspace (the caller's own) before falling back to a
    /// globally-unique match.
    func resolvePaneTarget(
        state: State,
        paneID: UUID?,
        target: String?,
        workspaceFilter: String?
    ) -> PaneTargetResolution {
        // If `--workspace` was supplied, resolve it up front so an
        // unknown workspace returns a specific error rather than
        // cascading into "unresolved target".
        let scopedWorkspace: WorkspaceFeature.State?
        if let filter = workspaceFilter {
            guard let ws = state.resolveWorkspace(filter) else {
                return .error("workspace not found: \(filter)")
            }
            scopedWorkspace = ws
        } else {
            scopedWorkspace = nil
        }

        let resolvedID: UUID
        if let target {
            if let uuid = UUID(uuidString: target) {
                if let scopedWorkspace {
                    guard scopedWorkspace.panes[id: uuid] != nil else {
                        return .error("no pane with UUID '\(target)' in workspace '\(scopedWorkspace.name)'")
                    }
                } else {
                    guard state.workspaces.contains(where: { $0.panes[id: uuid] != nil }) else {
                        return .error("no pane with UUID '\(target)'")
                    }
                }
                resolvedID = uuid
            } else {
                // Label lookup. We require an explicit workspace
                // scope: either `--workspace <name-or-id>` (highest
                // precedence) or an origin pane via `NEX_PANE_ID`
                // (implicit — the caller's own workspace). A bare
                // label with neither would have to fall back to a
                // global match, which is the silent-routing class of
                // bug tracked in #92 — refuse rather than guess.
                // UUID targets are unaffected since UUIDs are unique
                // and always resolve globally.
                let candidates: [Pane]
                let originWorkspaceName: String?
                if let scopedWorkspace {
                    candidates = Array(scopedWorkspace.panes.filter { $0.label == target })
                    originWorkspaceName = nil
                } else if let paneID,
                          let origin = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
                    candidates = Array(origin.panes.filter { $0.label == target })
                    originWorkspaceName = origin.name
                } else if let paneID {
                    // `paneID` came from the wire but no workspace
                    // contains it — the sender's NEX_PANE_ID is stale
                    // (origin pane was closed but the env var lives
                    // on). Treat the caller as if they had no implicit
                    // workspace context.
                    return .error(
                        "origin pane '\(paneID.uuidString)' no longer exists; " +
                            "pass --workspace <name-or-id> to address a pane in another workspace"
                    )
                } else {
                    return .error(
                        "label '\(target)' requires --workspace <name-or-id> when called from outside a Nex pane"
                    )
                }

                switch candidates.count {
                case 0:
                    let scopeSuffix = if let scopedWorkspace {
                        " in workspace '\(scopedWorkspace.name)'"
                    } else if let originWorkspaceName {
                        " in workspace '\(originWorkspaceName)' " +
                            "(use --workspace <name-or-id> to address another workspace)"
                    } else {
                        ""
                    }
                    return .error("no pane with label '\(target)'\(scopeSuffix)")
                case 1:
                    resolvedID = candidates[0].id
                default:
                    return .error(
                        "label '\(target)' is ambiguous (\(candidates.count) matches); " +
                            "pass --workspace <name-or-id> to disambiguate"
                    )
                }
            }
        } else if let paneID {
            guard state.workspaces.contains(where: { $0.panes[id: paneID] != nil }) else {
                return .error("no pane with UUID '\(paneID.uuidString)'")
            }
            resolvedID = paneID
        } else {
            // The wire decoder rejects this case, so this is defensive.
            return .error("missing pane_id and target")
        }

        guard let workspace = state.workspaces.first(where: { $0.panes[id: resolvedID] != nil }) else {
            return .error("pane not found: \(resolvedID.uuidString)")
        }

        if let scopedWorkspace, scopedWorkspace.id != workspace.id {
            return .error("pane '\(resolvedID.uuidString)' is not in workspace '\(scopedWorkspace.name)'")
        }

        return .found(paneID: resolvedID, workspace: workspace)
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
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
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

    /// Resolve + dispatch a `pane-capture` request. Reads the terminal
    /// contents of the resolved pane and replies with a `{ok,text,...}`
    /// payload. Rejects non-terminal panes (markdown / scratchpad / diff)
    /// upfront with a typed error.
    func handlePaneCapture(
        state: State,
        paneID: UUID?,
        target: String?,
        workspaceFilter: String?,
        lines: Int?,
        includeScrollback: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        func fail(_ error: String) -> Effect<Action> {
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        // The CLI rejects `--lines 0` upfront, but raw socket/TCP
        // clients can send any int — guard here so invalid input
        // gets a structured error rather than a silent empty success.
        if let lines, lines <= 0 {
            return fail("lines must be a positive integer (got \(lines))")
        }

        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            return fail(error)
        }

        guard let pane = workspace.panes[id: resolvedID] else {
            return fail("pane not found: \(resolvedID.uuidString)")
        }
        guard pane.type == .shell else {
            return fail("pane is not a terminal (type: \(pane.type.rawValue))")
        }

        let label = pane.label
        let workspaceName = workspace.name
        let workspaceID = workspace.id
        let mgr = surfaceManager
        return .run { _ in
            let text = await mgr.captureContents(paneID: resolvedID, includeScrollback: includeScrollback)
            guard let text else {
                reply?.send(["ok": false, "error": "pane closed during capture"])
                reply?.close()
                return
            }
            let trimmed = lines.map { Self.tailLines(text, $0) } ?? text
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "workspace_name": workspaceName,
                "text": trimmed
            ]
            if let label {
                payload["label"] = label
            }
            reply?.send(payload)
            reply?.close()
        }
    }

    /// Resolve + dispatch a `pane-send` request. Mirrors
    /// `handlePaneClose` / `handlePaneCapture` — uses the shared
    /// `resolvePaneTarget` so label lookup is scoped to the sender's
    /// workspace by default and `--workspace` is the explicit
    /// cross-workspace escape hatch (issue #92). Replies with
    /// `{ok:true,...}` on success, `{ok:false,error:...}` on failure.
    /// `reply == nil` is the legacy fire-and-forget path: dispatch on
    /// success and silently drop on error so older CLIs keep working.
    func handlePaneSend(
        state: State,
        paneID: UUID?,
        target: String,
        text: String,
        workspaceFilter: String?,
        bare: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        var payload: [String: Any] = [
            "ok": true,
            "pane_id": resolvedID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name,
            "bare": bare
        ]
        if let label = workspace.panes[id: resolvedID]?.label {
            payload["label"] = label
        }
        reply?.send(payload)
        reply?.close()

        return paneSendText(paneID: resolvedID, text: text, bare: bare)
    }

    /// Write `text` to a pane's PTY. `bare: true` writes the bytes
    /// verbatim; `bare: false` follows up with an Enter keystroke so
    /// the receiver runs it as a command. Factored out of
    /// `handlePaneSend` so the Phase 3 element picker can reuse the
    /// same PTY-write path without going through `sendCommand`
    /// directly. The picker defaults to `bare: true` (paste-only,
    /// the safe default) and only flips to `bare: false` when the
    /// arming call passed `--submit`.
    func paneSendText(paneID: UUID, text: String, bare: Bool) -> Effect<Action> {
        let mgr = surfaceManager
        return .run { _ in
            if bare {
                await mgr.sendText(to: paneID, text: text)
            } else {
                await mgr.sendCommand(to: paneID, command: text)
            }
        }
    }

    /// Resolve + dispatch a `pane-send-key` request. Mirrors
    /// `handlePaneSend` — same target resolution, same reply
    /// contract, same fire-and-forget back-compat. Adds a key-name
    /// validation step that rejects unknown names with a structured
    /// error before touching the surface (issue #98). The reducer
    /// only knows the allowlist; the actual keystroke is synthesized
    /// inside `SurfaceManager.sendKey` via `GhosttySurface.sendNamedKey`.
    func handlePaneSendKey(
        state: State,
        paneID: UUID?,
        target: String,
        key: String,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        // Validate the key name first so an unknown key never silently
        // resolves a target. The supported set lives on
        // GhosttySurface so the CLI, reducer, and surface layer share
        // one source of truth.
        let normalizedKey = key.lowercased()
        guard GhosttySurface.namedKeyAliases.contains(normalizedKey) else {
            let valid = GhosttySurface.namedKeyAliases.joined(separator: ", ")
            reply?.send(["ok": false, "error": "unknown key '\(key)' (valid: \(valid))"])
            reply?.close()
            return .none
        }

        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        var payload: [String: Any] = [
            "ok": true,
            "pane_id": resolvedID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name,
            "key": normalizedKey
        ]
        if let label = workspace.panes[id: resolvedID]?.label {
            payload["label"] = label
        }
        reply?.send(payload)
        reply?.close()

        let mgr = surfaceManager
        return .run { _ in
            await mgr.sendKey(to: resolvedID, keyName: normalizedKey)
        }
    }

    /// Shared success reply for `pane-split` / `pane-create`: the new
    /// pane's UUID is minted by the caller and threaded into the
    /// workspace action so the reply can return it before the pane is
    /// actually built. `reply == nil` is the legacy fire-and-forget path.
    /// Success ack for `pane-split` / `pane-create`. The new pane's UUID
    /// is minted inside the WorkspaceFeature effect (not here), so the
    /// reply intentionally omits `pane_id` and reports the resolved
    /// workspace + the requested label instead. Callers that need the id
    /// can read it back via `nex pane list --json` (matching on the
    /// label). `reply == nil` is the legacy fire-and-forget path.
    /// Success ack for `pane-split` / `pane-create`. The new pane's UUID
    /// is minted up front by the handler and threaded into the
    /// WorkspaceFeature action (issue #117) so the reply can return it
    /// before the pane is actually built. `reply == nil` is the legacy
    /// fire-and-forget path.
    private func replyPaneCreated(
        _ reply: SocketServer.ReplyHandle?,
        newPaneID: UUID,
        workspace: WorkspaceFeature.State,
        label: String?
    ) {
        guard let reply else { return }
        var payload: [String: Any] = [
            "ok": true,
            "pane_id": newPaneID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name
        ]
        if let label, !label.isEmpty { payload["label"] = label }
        reply.sendAndClose(payload)
    }

    /// Resolve + dispatch a `pane-split` request (issue #117). Works from
    /// outside a Nex pane: `--target` (UUID = global, label = needs
    /// scope) names the pane to split; `--workspace` scopes label lookup
    /// or, on its own, splits the workspace's focused pane. Every exit
    /// acks or errors through `reply` (a no-op when `reply == nil`, so
    /// pre-#117 fire-and-forget clients keep working). Reuses the existing
    /// `splitPane` / `splitPaneAtPath` actions (no new enum case) so the
    /// type-check-sensitive ContentView body is unaffected.
    func handlePaneSplit(
        state: inout State,
        paneID: UUID?,
        direction: PaneLayout.SplitDirection?,
        path: String?,
        name: String?,
        target: String?,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let workspaceID: UUID
        let sourcePaneID: UUID

        // `--workspace` *without* `--target` selects the destination
        // workspace outright — even when the caller forwarded its own
        // NEX_PANE_ID — so a pane in workspace alpha can run
        // `nex pane split --workspace beta` (issue #117). `--target` keeps
        // precedence so `--target X --workspace Y` still scopes the label
        // lookup of X to Y; the caller's pane is only the source when
        // neither `--target` nor `--workspace` is given.
        if target == nil, let workspaceFilter {
            guard let ws = state.resolveWorkspace(workspaceFilter) else {
                reply?.error("workspace not found: \(workspaceFilter)")
                return .none
            }
            guard let source = ws.focusedPaneID ?? ws.panes.first?.id else {
                reply?.error("workspace '\(ws.name)' has no pane to split — use `nex pane create --workspace \(workspaceFilter)`")
                return .none
            }
            workspaceID = ws.id
            sourcePaneID = source
        } else if target != nil || paneID != nil {
            switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
            case .found(let resolved, let ws):
                workspaceID = ws.id
                sourcePaneID = resolved
            case .error(let error):
                reply?.error(error)
                return .none
            }
        } else {
            reply?.error("pane split requires --target or --workspace when called from outside a Nex pane")
            return .none
        }

        guard let workspace = state.workspaces[id: workspaceID] else {
            reply?.error("workspace not found")
            return .none
        }

        // Mint the new pane's id up front so the reply can return it
        // (issue #117); thread it into the action via the defaulted
        // `newPaneID` parameter. `splitPaneAtPath` splits the *focused*
        // pane, so focus the resolved source first; `splitPane` takes the
        // source explicitly.
        let newID = uuid()
        state.workspaces[id: workspaceID]?.setFocus(sourcePaneID)
        replyPaneCreated(reply, newPaneID: newID, workspace: workspace, label: name)

        if let path {
            return .send(.workspaces(.element(
                id: workspaceID,
                action: .splitPaneAtPath(path, label: name, direction: direction ?? .horizontal, newPaneID: newID)
            )))
        }
        return .send(.workspaces(.element(
            id: workspaceID,
            action: .splitPane(direction: direction ?? .horizontal, sourcePaneID: sourcePaneID, label: name, newPaneID: newID)
        )))
    }

    /// Resolve + dispatch a `pane-create` request (issue #117). Resolves
    /// a target *workspace* (via `--target`'s pane, `--workspace`, or the
    /// caller pane) and adds a pane: split off the focused pane when the
    /// workspace already has panes, or create the first pane when it is
    /// empty (the path the old split-only handler had no route for). New
    /// pane UUID minted up front and returned in the reply.
    func handlePaneCreate(
        state: inout State,
        paneID: UUID?,
        path: String?,
        name: String?,
        target: String?,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let workspaceID: UUID
        var sourcePaneID: UUID?

        // `--workspace` *without* `--target` selects the destination
        // workspace outright — even when the caller forwarded its own
        // NEX_PANE_ID — so a pane in workspace alpha can run
        // `nex pane create --workspace beta` (finding 1). `--target` keeps
        // precedence; the caller's pane is only the anchor when neither
        // `--target` nor `--workspace` is given.
        if target == nil, let workspaceFilter {
            guard let ws = state.resolveWorkspace(workspaceFilter) else {
                reply?.error("workspace not found: \(workspaceFilter)")
                return .none
            }
            workspaceID = ws.id
            sourcePaneID = ws.focusedPaneID ?? ws.panes.first?.id
        } else if target != nil || paneID != nil {
            switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
            case .found(let resolved, let ws):
                workspaceID = ws.id
                sourcePaneID = resolved
            case .error(let error):
                reply?.error(error)
                return .none
            }
        } else {
            reply?.error("pane create requires --target or --workspace when called from outside a Nex pane")
            return .none
        }

        guard let workspace = state.workspaces[id: workspaceID] else {
            reply?.error("workspace not found")
            return .none
        }

        // Mint the new pane's id up front so the reply returns it (issue
        // #117), then thread it into whichever action builds the pane so
        // the acked id actually matches the created pane.
        let newID = uuid()
        replyPaneCreated(reply, newPaneID: newID, workspace: workspace, label: name)

        let source = sourcePaneID ?? workspace.focusedPaneID ?? workspace.panes.first?.id

        // Empty workspace: no pane to split off, so lay out the first pane
        // via `createPane`, carrying `--name` (label) and `--path`
        // (workingDirectory) so the pane the reply acked actually has them
        // (finding 2). This is the route the old split-only handler lacked.
        guard let source else {
            return .send(.workspaces(.element(
                id: workspaceID,
                action: .createPane(newPaneID: newID, label: name, workingDirectory: path)
            )))
        }

        // Populated workspace: split the resolved/focused pane, threading
        // `newID` so the new pane gets the acked id. `splitPaneAtPath`
        // splits the focused pane, so focus first.
        state.workspaces[id: workspaceID]?.setFocus(source)
        if let path {
            return .send(.workspaces(.element(
                id: workspaceID,
                action: .splitPaneAtPath(path, label: name, newPaneID: newID)
            )))
        }
        return .send(.workspaces(.element(
            id: workspaceID,
            action: .splitPane(direction: .horizontal, sourcePaneID: source, label: name, newPaneID: newID)
        )))
    }

    /// Resolve + dispatch a `pane-name` request (issue #117). Without
    /// `--target` it renames the caller pane (`NEX_PANE_ID`); with
    /// `--target` it renames any pane (UUID global, label scoped). Replies
    /// `{ok,pane_id,label,workspace_name}`.
    func handlePaneName(
        state: inout State,
        paneID: UUID?,
        target: String?,
        workspaceFilter: String?,
        name: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.error(error)
            return .none
        }

        let newLabel = name.isEmpty ? nil : name
        state.workspaces[id: workspace.id]?.panes[id: resolvedID]?.label = newLabel

        if let reply {
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "workspace_name": workspace.name
            ]
            if let newLabel { payload["label"] = newLabel }
            reply.sendAndClose(payload)
        }

        return .send(.persistState)
    }

    // MARK: - Sync-input helpers (issue #121)

    /// Push the workspace's current sync group to `SurfaceManager`.
    /// Mirrors `WorkspaceFeature.refreshSyncGroup` but callable from
    /// the AppReducer layer — used by `paneMoveToWorkspace` which
    /// mutates `state.workspaces` directly and so bypasses the
    /// per-workspace bookkeeping reducer. Returns `.none` when the
    /// workspace has gone missing (race / typo) so we don't crash.
    private func refreshSyncGroupForWorkspace(
        workspaceID: UUID, state: State
    ) -> Effect<Action> {
        guard let workspace = state.workspaces[id: workspaceID] else { return .none }
        let paneIDs = workspace.syncedPaneIDs
        let mgr = surfaceManager
        return .run { _ in
            mgr.setSyncGroup(workspaceID: workspaceID, paneIDs: paneIDs)
        }
    }

    // MARK: - Sync-input socket handlers (issue #121)

    /// Dispatch `pane-sync (on|off|toggle|status)`. Resolves the
    /// workspace from `workspaceFilter` first, then `NEX_PANE_ID`.
    /// Replies with `{ok:true,active:Bool,excluded:[...]}` on success;
    /// `status` is read-only and never mutates state.
    func handlePaneSync(
        state: State,
        paneID: UUID?,
        workspaceFilter: String?,
        action: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        func fail(_ error: String) -> Effect<Action> {
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        let workspace: WorkspaceFeature.State
        if let workspaceFilter {
            guard let ws = state.resolveWorkspace(workspaceFilter) else {
                return fail("workspace not found: \(workspaceFilter)")
            }
            workspace = ws
        } else if let paneID, let ws = state.workspaceContainingPane(paneID) {
            workspace = ws
        } else {
            return fail("pane sync requires --workspace or NEX_PANE_ID")
        }

        let normalized = action.lowercased()
        let nextActive: Bool
        switch normalized {
        case "on":
            nextActive = true
        case "off":
            nextActive = false
        case "toggle":
            nextActive = !workspace.isSyncInputActive
        case "status":
            // Read-only — reply with current snapshot and bail.
            replySyncStatus(reply: reply, workspace: workspace)
            return .none
        default:
            return fail("unknown sync action '\(action)' (valid: on, off, toggle, status)")
        }

        // Reply with the post-change snapshot. Mirrors the read-only
        // status payload so a CLI caller can rely on the same fields
        // regardless of which subcommand they invoked.
        var snapshot = workspace
        snapshot.isSyncInputActive = nextActive
        if !nextActive { snapshot.syncInputExcluded.removeAll() }
        replySyncStatus(reply: reply, workspace: snapshot)

        return .send(.workspaces(.element(
            id: workspace.id,
            action: .setSyncInputActive(nextActive)
        )))
    }

    /// Dispatch `pane-sync exclude|include`. Reuses `resolvePaneTarget`
    /// so target / workspace resolution matches `pane send` etc.
    func handlePaneSyncExclude(
        state: State,
        paneID: UUID?,
        target: String,
        workspaceFilter: String?,
        excluded: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        var snapshot = workspace
        if excluded {
            snapshot.syncInputExcluded.insert(resolvedID)
        } else {
            snapshot.syncInputExcluded.remove(resolvedID)
        }
        replySyncStatus(reply: reply, workspace: snapshot)

        return .send(.workspaces(.element(
            id: workspace.id,
            action: .setSyncInputExcluded(paneID: resolvedID, excluded: excluded)
        )))
    }

    /// Build and send the standard sync-status reply payload.
    /// Mirrors the structure `pane sync status` returns so every
    /// sync subcommand surfaces consistent fields.
    private func replySyncStatus(
        reply: SocketServer.ReplyHandle?,
        workspace: WorkspaceFeature.State
    ) {
        var excluded: [[String: Any]] = []
        // Sort by uuidString so the JSON reply has a stable order across
        // calls — otherwise Set<UUID> iteration order would make scripts
        // diffing `pane sync status --json` output flake intermittently.
        for paneID in workspace.syncInputExcluded.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let pane = workspace.panes[id: paneID] else { continue }
            var entry: [String: Any] = ["id": paneID.uuidString]
            if let label = pane.label { entry["label"] = label }
            excluded.append(entry)
        }
        let synced = workspace.syncedPaneIDs.map(\.uuidString).sorted()
        reply?.send([
            "ok": true,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name,
            "active": workspace.isSyncInputActive,
            "synced_pane_ids": synced,
            "excluded": excluded
        ])
        reply?.close()
    }

    // MARK: - Graft socket handlers

    /// Outcome of `resolveGraftAssociations`. Carries either the
    /// resolved set or a user-facing error message — callers send the
    /// error string in the reply payload.
    enum GraftScopeResolution {
        case resolved([RepoAssociation])
        case failure(String)
    }

    /// Resolve the set of associations in scope for a `graft-*` command.
    /// `workspaceFilter` (name-or-UUID) limits to one workspace;
    /// `repoFilter` (name or worktree-path) further filters by repo.
    /// `paneID` (from `NEX_PANE_ID`) is used as the workspace scope
    /// when neither filter is supplied — that's the "in-pane bare
    /// command" path that should target the caller's workspace.
    private func resolveGraftAssociations(
        state: State,
        workspaceFilter: String?,
        repoFilter: String?,
        paneID: UUID?
    ) -> GraftScopeResolution {
        let workspaces: [WorkspaceFeature.State]
        if let workspaceFilter {
            guard let wsID = Self.resolveWorkspace(workspaceFilter, state: state),
                  let ws = state.workspaces[id: wsID] else {
                return .failure("workspace not found: \(workspaceFilter)")
            }
            workspaces = [ws]
        } else if let paneID {
            guard let ws = state.workspaceContainingPane(paneID) else {
                return .failure("no workspace contains the requesting pane")
            }
            workspaces = [ws]
        } else if repoFilter != nil {
            // Repo-only filter: search every workspace.
            workspaces = Array(state.workspaces)
        } else {
            return .failure("graft requires --workspace, --repo, or NEX_PANE_ID")
        }

        var results: [RepoAssociation] = []
        for ws in workspaces {
            for assoc in ws.repoAssociations {
                if let repoFilter {
                    let matchesPath = assoc.worktreePath == repoFilter
                        || (assoc.worktreePath as NSString).lastPathComponent == repoFilter
                    let matchesName = state.repoRegistry[id: assoc.repoID]?.name == repoFilter
                    guard matchesPath || matchesName else { continue }
                }
                results.append(assoc)
            }
        }
        if results.isEmpty {
            return .failure("no repo associations matched the requested scope")
        }
        return .resolved(results)
    }

    private func sessionJSON(_ session: GraftSession) -> [String: Any] {
        let statusString = switch session.status {
        case .starting: "starting"
        case .watching: "watching"
        case .syncing: "syncing"
        case .error: "error"
        }
        var payload: [String: Any] = [
            "association_id": session.id.uuidString,
            "worktree_path": session.worktreePath,
            "parent_repo_root": session.parentRepoRoot,
            "branch": session.branch,
            "status": statusString
        ]
        if case .error(let msg) = session.status {
            payload["error"] = msg
        }
        if let stashRef = session.stashRef {
            payload["stash_ref"] = stashRef
        }
        if let lastSync = session.lastSync {
            payload["last_sync"] = ISO8601DateFormatter().string(from: lastSync)
        }
        return payload
    }

    func handleGraftStart(
        state: State,
        workspaceFilter: String?,
        repoFilter: String?,
        paneID: UUID?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let assocs: [RepoAssociation]
        switch resolveGraftAssociations(
            state: state,
            workspaceFilter: workspaceFilter,
            repoFilter: repoFilter,
            paneID: paneID
        ) {
        case .resolved(let resolved):
            assocs = resolved
        case .failure(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        return .run { [graftService] _ in
            var started: [[String: Any]] = []
            var failedAny = false
            var lastError: String?
            for assoc in assocs {
                do {
                    let session = try await graftService.start(assoc)
                    started.append([
                        "association_id": session.id.uuidString,
                        "worktree_path": session.worktreePath,
                        "branch": session.branch,
                        "parent_repo_root": session.parentRepoRoot
                    ])
                } catch {
                    failedAny = true
                    lastError = String(describing: error)
                }
            }
            if started.isEmpty {
                reply?.send(["ok": false, "error": lastError ?? "graft start failed"])
            } else if failedAny, let lastError {
                var payload: [String: Any] = ["ok": true, "started": started]
                payload["partial_error"] = lastError
                reply?.send(payload)
            } else {
                reply?.send(["ok": true, "started": started])
            }
            reply?.close()
        }
    }

    func handleGraftStop(
        state: State,
        workspaceFilter: String?,
        repoFilter: String?,
        paneID: UUID?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let assocs: [RepoAssociation]
        switch resolveGraftAssociations(
            state: state,
            workspaceFilter: workspaceFilter,
            repoFilter: repoFilter,
            paneID: paneID
        ) {
        case .resolved(let resolved):
            assocs = resolved
        case .failure(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        // Only stop associations that actually have a live session.
        let activeIDs = Set(state.graft.sessions.ids)
        let targets = assocs.filter { activeIDs.contains($0.id) }
        if targets.isEmpty {
            reply?.send(["ok": true, "stopped": []])
            reply?.close()
            return .none
        }

        return .run { [graftService] _ in
            var stopped: [String] = []
            var failures: [[String: Any]] = []
            for assoc in targets {
                do {
                    try await graftService.stop(assoc.id)
                    stopped.append(assoc.id.uuidString)
                } catch {
                    failures.append([
                        "association_id": assoc.id.uuidString,
                        "error": String(describing: error)
                    ])
                }
            }
            var payload: [String: Any] = ["ok": failures.isEmpty, "stopped": stopped]
            if !failures.isEmpty {
                payload["failed"] = failures
            }
            reply?.send(payload)
            reply?.close()
        }
    }

    func handleGraftStatus(
        state: State,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let payload: [String: Any] = [
            "ok": true,
            "sessions": state.graft.sessions.map(sessionJSON)
        ]
        reply?.send(payload)
        reply?.close()
        return .none
    }

    /// `nex ping` — cheap IPC round-trip used by `nex doctor` and as
    /// a version probe. Reads the version + build out of the main
    /// bundle's Info.plist; `pid` is the running app's process id so
    /// callers can confirm which Nex instance owns the socket
    /// (e.g. helpful when triaging stale `/tmp/nex.sock` files).
    func handlePing(reply: SocketServer.ReplyHandle?) -> Effect<Action> {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info?["CFBundleVersion"] as? String) ?? "unknown"
        let payload: [String: Any] = [
            "ok": true,
            "version": version,
            "build": build,
            "pid": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        reply?.send(payload)
        reply?.close()
        return .none
    }

    // MARK: - Web pane handlers (Phase 1)

    enum WebNavAction { case back, forward, reload, reloadHard }

    /// Open a new `.web` pane in the active workspace. Mirrors the
    /// shape of `handlePaneList` — single JSON reply, then close.
    /// Allocates the new pane (and active-tab) UUIDs up front so the
    /// reply payload can echo a concrete `pane_id` *before* the
    /// workspace effect runs and the CLI can print/script against it.
    func handleWebOpen(
        state: State,
        paneID _: UUID?,
        url: String,
        isPrivate: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let activeID = state.activeWorkspaceID else {
            reply?.send(["ok": false, "error": "no active workspace"])
            reply?.close()
            return .none
        }
        let normalized = WebPaneCoordinator.normalizeURLInput(url)
        let newPaneID = uuid()
        let newTabID = uuid()
        reply?.send([
            "ok": true,
            "pane_id": newPaneID.uuidString,
            "tab_id": newTabID.uuidString,
            "url": normalized,
            "private": isPrivate,
            "workspace_id": activeID.uuidString
        ])
        reply?.close()
        return .send(.workspaces(.element(
            id: activeID,
            action: .openWebPane(
                paneID: newPaneID,
                tabID: newTabID,
                url: url,
                reusePaneID: nil,
                isPrivate: isPrivate
            )
        )))
    }

    /// Wire-level addressing for any `nex web ...` command. All three
    /// fields come from the same CLI payload (`pane_id`, `target`,
    /// `workspace`); bundling them keeps the per-handler signatures
    /// from leaking that detail.
    struct WebPaneScope: Equatable {
        let paneID: UUID?
        let target: String?
        let workspaceFilter: String?
    }

    /// Resolve a pane-target reference to a `.web` pane. Replies with
    /// the structured error on a miss and returns nil so the caller
    /// can short-circuit cleanly.
    private func resolveWebPane(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> (paneID: UUID, workspace: WorkspaceFeature.State, webState: WebPaneState)? {
        switch resolvePaneTarget(
            state: state, paneID: scope.paneID,
            target: scope.target, workspaceFilter: scope.workspaceFilter
        ) {
        case .found(let resolvedID, let ws):
            guard let pane = ws.panes[id: resolvedID] else {
                reply?.error("pane not found: \(resolvedID.uuidString)")
                return nil
            }
            guard pane.type == .web else {
                reply?.error("pane is not a web pane (type: \(pane.type.rawValue))")
                return nil
            }
            guard let webState = ws.webPanes[resolvedID] else {
                reply?.error("web pane state missing for \(resolvedID.uuidString)")
                return nil
            }
            return (resolvedID, ws, webState)
        case .error(let message):
            reply?.error(message)
            return nil
        }
    }

    func handleWebNavigate(
        state: State,
        scope: WebPaneScope,
        url: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        guard resolved.webState.activeTab != nil else {
            reply?.error("web pane has no active tab")
            return .none
        }
        let normalized = WebPaneCoordinator.normalizeURLInput(url)
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "url": normalized
        ])
        return .send(.workspaces(.element(
            id: resolved.workspace.id,
            action: .webPaneNavigate(paneID: resolved.paneID, url: url)
        )))
    }

    func handleWebURL(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }

        // Destructure into Sendable locals — Swift 6 strict
        // concurrency rejects capturing the resolved tuple
        // (which carries WorkspaceFeature.State) in a @Sendable
        // closure.
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let tabID = resolved.webState.activeTab?.id
        let fallbackURL = resolved.webState.activeTab?.url ?? ""
        let fallbackTitle = resolved.webState.activeTab?.title ?? ""

        return .run { _ in
            let snapshot: (url: String, title: String)? = await MainActor.run {
                guard let tabID else { return nil }
                return store.coordinatorIfExists(for: resolvedPaneID)?
                    .currentURLAndTitle(tabID: tabID)
            }
            let url = snapshot?.url.isEmpty == false ? snapshot!.url : fallbackURL
            let title = snapshot?.title.isEmpty == false ? snapshot!.title : fallbackTitle
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "url": url,
                "title": title
            ])
        }
    }

    func handleWebNav(
        state: State,
        scope: WebPaneScope,
        action: WebNavAction,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }

        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString
        ])

        let wsID = resolved.workspace.id
        let paneID = resolved.paneID
        switch action {
        case .back:
            return .send(.workspaces(.element(id: wsID, action: .webPaneBack(paneID: paneID))))
        case .forward:
            return .send(.workspaces(.element(id: wsID, action: .webPaneForward(paneID: paneID))))
        case .reload:
            return .send(.workspaces(.element(id: wsID, action: .webPaneReload(paneID: paneID, hard: false))))
        case .reloadHard:
            return .send(.workspaces(.element(id: wsID, action: .webPaneReload(paneID: paneID, hard: true))))
        }
    }

    func handleWebCapture(
        state: State,
        scope: WebPaneScope,
        mode: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        guard let tab = resolved.webState.activeTab else {
            reply?.error("web pane has no active tab")
            return .none
        }

        guard let captureMode = WebCaptureMode(rawValue: mode) else {
            reply?.error("unknown capture mode '\(mode)' (allowed: meta, text, screenshot)")
            return .none
        }

        // Destructure into Sendable locals for the .run closure
        // (Swift 6 strict concurrency disallows capturing the
        // resolved tuple, which carries WorkspaceFeature.State).
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let tabID = tab.id
        let tabURL = tab.url
        let tabTitle = tab.title
        let isPrivate = resolved.webState.isPrivate

        return .run { _ in
            let snapshot: (url: String, title: String) = await MainActor.run {
                store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).currentURLAndTitle(tabID: tabID)
                    ?? (tabURL, tabTitle)
            }
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "url": snapshot.url,
                "title": snapshot.title,
                "mode": captureMode.rawValue
            ]
            switch captureMode {
            case .meta:
                break
            case .text:
                let text = await store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).captureText(tabID: tabID)
                payload["text"] = text
                payload["byte_count"] = text.utf8.count
            case .screenshot:
                let pngData = await store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).captureScreenshot(tabID: tabID)
                if let pngData {
                    let inlineThreshold = 1_000_000 // 1 MB
                    if pngData.count <= inlineThreshold {
                        payload["png_base64"] = pngData.base64EncodedString()
                        payload["byte_count"] = pngData.count
                    } else {
                        // Per-app temporary directory — OS prunes it
                        // automatically (vs. `/tmp` where files lingered
                        // until reboot).
                        let ts = Int(Date().timeIntervalSince1970)
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("nex-web-capture-\(resolvedPaneID.uuidString)-\(ts).png")
                        if (try? pngData.write(to: url)) != nil {
                            payload["path"] = url.path
                            payload["byte_count"] = pngData.count
                        } else {
                            payload["ok"] = false
                            payload["error"] = "failed to write screenshot to \(url.path)"
                        }
                    }
                } else {
                    payload["ok"] = false
                    payload["error"] = "screenshot capture failed"
                }
            }
            reply?.sendAndClose(payload)
        }
    }

    // MARK: - Web pane actuator handlers

    /// Dispatch a `__nexAct.<method>(<args>)` call against the resolved
    /// web pane's active tab and translate the parsed envelope into a
    /// `ReplyHandle` reply. Shared body for every actuator-backed
    /// verb (click / type / q* / wait / select / scroll / hover / key /
    /// exec).
    private func runWebPaneActuator(
        state: State,
        scope: WebPaneScope,
        errorLabel: String,
        reply: SocketServer.ReplyHandle?,
        body: @escaping @Sendable (WebPaneCoordinator, UUID) async -> WebPaneActuator.Result
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        guard let tab = resolved.webState.activeTab else {
            reply?.error("web pane has no active tab")
            return .none
        }

        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let tabID = tab.id
        let isPrivate = resolved.webState.isPrivate

        return .run { _ in
            let coordinator = await MainActor.run {
                store.coordinator(for: resolvedPaneID, isPrivate: isPrivate)
            }
            let outcome = await body(coordinator, tabID)
            switch outcome {
            case .unknownTab:
                reply?.error("web pane has no live tab \(tabID.uuidString)")
            case .evaluationFailed(let message):
                reply?.error("\(errorLabel) evaluation failed: \(message)")
            case .success(let envelope):
                var payload = (try? JSONSerialization.jsonObject(
                    with: envelope.raw
                ) as? [String: Any]) ?? [:]
                payload["pane_id"] = resolvedPaneID.uuidString
                payload["workspace_id"] = workspaceID.uuidString
                payload["tab_id"] = tabID.uuidString
                reply?.sendAndClose(payload)
            }
        }
    }

    private func handleWebActuatorCall(
        state: State,
        scope: WebPaneScope,
        method: String,
        args: [JSValue],
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        runWebPaneActuator(
            state: state, scope: scope, errorLabel: "actuator", reply: reply
        ) { coordinator, tabID in
            await WebPaneActuator.invoke(
                coordinator: coordinator, tabID: tabID, method: method, args: args
            )
        }
    }

    func handleWebClick(
        state: State,
        scope: WebPaneScope,
        selector: String,
        double: Bool,
        right: Bool,
        atX: Double?,
        atY: Double?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if double { opts.append(JSPair(key: "double", value: .bool(true))) }
        if right { opts.append(JSPair(key: "right", value: .bool(true))) }
        if let x = atX, let y = atY {
            opts.append(JSPair(key: "at", value: .object([
                JSPair(key: "x", value: .double(x)),
                JSPair(key: "y", value: .double(y))
            ])))
        }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "click",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebType(
        state: State,
        scope: WebPaneScope,
        selector: String,
        text: String,
        submit: Bool,
        replace: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if submit { opts.append(JSPair(key: "submit", value: .bool(true))) }
        // `replace` defaults true in the JS side; only ship the flag
        // when the caller overrode it so the wire payload stays small.
        if !replace { opts.append(JSPair(key: "replace", value: .bool(false))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "type",
            args: [.string(selector), .string(text), .object(opts)],
            reply: reply
        )
    }

    func handleWebQText(
        state: State,
        scope: WebPaneScope,
        selector: String,
        maxBytes: Int?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let maxBytes { opts.append(JSPair(key: "maxBytes", value: .int(maxBytes))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "text",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebQAttr(
        state: State,
        scope: WebPaneScope,
        selector: String,
        attribute: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "attr",
            args: [.string(selector), .string(attribute)],
            reply: reply
        )
    }

    func handleWebQCount(
        state: State,
        scope: WebPaneScope,
        selector: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "count",
            args: [.string(selector)],
            reply: reply
        )
    }

    func handleWebQExists(
        state: State,
        scope: WebPaneScope,
        selector: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "exists",
            args: [.string(selector)],
            reply: reply
        )
    }

    func handleWebQDom(
        state: State,
        scope: WebPaneScope,
        selector: String,
        maxBytes: Int?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let maxBytes { opts.append(JSPair(key: "maxBytes", value: .int(maxBytes))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "dom",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebWait(
        state: State,
        scope: WebPaneScope,
        selector: String?,
        urlMatch: String?,
        forCondition: String?,
        timeoutMs: Int,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let selector { opts.append(JSPair(key: "selector", value: .string(selector))) }
        if let urlMatch { opts.append(JSPair(key: "urlMatch", value: .string(urlMatch))) }
        if let forCondition { opts.append(JSPair(key: "for", value: .string(forCondition))) }
        opts.append(JSPair(key: "timeout", value: .int(timeoutMs)))
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "wait",
            args: [.object(opts)],
            reply: reply
        )
    }

    func handleWebSelect(
        state: State,
        scope: WebPaneScope,
        selector: String,
        valueOrLabel: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "select",
            args: [.string(selector), .string(valueOrLabel)],
            reply: reply
        )
    }

    func handleWebScroll(
        state: State,
        scope: WebPaneScope,
        selector: String,
        block: String,
        behavior: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let opts: [JSPair] = [
            JSPair(key: "block", value: .string(block)),
            JSPair(key: "behavior", value: .string(behavior))
        ]
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "scroll",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebHover(
        state: State,
        scope: WebPaneScope,
        selector: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "hover",
            args: [.string(selector)],
            reply: reply
        )
    }

    func handleWebKey(
        state: State,
        scope: WebPaneScope,
        keyName: String,
        selector: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let selector { opts.append(JSPair(key: "selector", value: .string(selector))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "key",
            args: [.string(keyName), .object(opts)],
            reply: reply
        )
    }

    func handleWebExec(
        state: State,
        scope: WebPaneScope,
        script: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let wrappedSource = WebPaneExecWrapper.wrap(script)
        return runWebPaneActuator(
            state: state, scope: scope, errorLabel: "exec", reply: reply
        ) { coordinator, tabID in
            await WebPaneActuator.evaluate(
                coordinator: coordinator, tabID: tabID, source: wrappedSource
            )
        }
    }

    // MARK: - Web pane tab handlers

    enum TabRefResolution {
        case found(UUID)
        case error(String)
    }

    /// Resolve a `tab` ref (UUID string or numeric index) against a
    /// web pane's tab list. Returns the concrete tab UUID or an
    /// error message safe to surface in a reply.
    private func resolveTabRef(
        _ ref: String,
        in webState: WebPaneState
    ) -> TabRefResolution {
        if let uuid = UUID(uuidString: ref) {
            guard webState.contains(tabID: uuid) else {
                return .error("no tab with UUID '\(ref)' in this web pane")
            }
            return .found(uuid)
        }
        if let idx = Int(ref) {
            guard webState.tabs.indices.contains(idx) else {
                return .error("tab index \(idx) out of range (0..<\(webState.tabs.count))")
            }
            return .found(webState.tabs[idx].id)
        }
        return .error("tab ref must be a UUID or numeric index, got '\(ref)'")
    }

    private func tabJSON(_ tab: WebTab, isActive: Bool, index: Int) -> [String: Any] {
        [
            "id": tab.id.uuidString,
            "url": tab.url,
            "title": tab.title,
            "index": index,
            "active": isActive
        ]
    }

    func handleWebTabs(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let activeID = resolved.webState.activeTab?.id
        let entries = resolved.webState.tabs.enumerated().map { idx, tab in
            tabJSON(tab, isActive: tab.id == activeID, index: idx)
        }
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "tabs": entries
        ])
        return .none
    }

    func handleWebTabNew(
        state: State,
        scope: WebPaneScope,
        url: String,
        makeActive: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let newTabID = uuid()
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "tab_id": newTabID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "url": WebPaneCoordinator.normalizeURLInput(url),
            "active": makeActive
        ])
        return .send(.workspaces(.element(
            id: resolved.workspace.id,
            action: .webPaneTabOpen(
                paneID: resolved.paneID,
                tabID: newTabID,
                url: url,
                makeActive: makeActive
            )
        )))
    }

    func handleWebTabClose(
        state: State,
        scope: WebPaneScope,
        tabRef: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        switch resolveTabRef(tabRef, in: resolved.webState) {
        case .error(let message):
            reply?.error(message)
            return .none
        case .found(let tabID):
            if resolved.webState.tabs.count == 1 {
                reply?.error("cannot close the only tab in a web pane, use `nex pane close` to close the pane itself")
                return .none
            }
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolved.paneID.uuidString,
                "workspace_id": resolved.workspace.id.uuidString,
                "tab_id": tabID.uuidString
            ])
            return .send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webPaneTabClose(paneID: resolved.paneID, tabID: tabID)
            )))
        }
    }

    func handleWebTabSelect(
        state: State,
        scope: WebPaneScope,
        tabRef: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        switch resolveTabRef(tabRef, in: resolved.webState) {
        case .error(let message):
            reply?.error(message)
            return .none
        case .found(let tabID):
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolved.paneID.uuidString,
                "workspace_id": resolved.workspace.id.uuidString,
                "tab_id": tabID.uuidString
            ])
            return .send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webPaneTabSelect(paneID: resolved.paneID, tabID: tabID)
            )))
        }
    }

    // MARK: - Web pane console + inspector handlers (Phase 3)

    private func consoleLineJSON(_ entry: RingBuffer<ConsoleLine>.Entry) -> [String: Any] {
        let line = entry.value
        var dict: [String: Any] = [
            "seq": entry.seq,
            "tab_id": line.tabID.uuidString,
            "level": line.level.rawValue,
            "message": line.message,
            "url": line.url,
            "captured_at": InspectPayloadSanitiser.isoFormatter.string(from: line.capturedAt)
        ]
        if let n = line.lineNumber { dict["line"] = n }
        if let n = line.columnNumber { dict["column"] = n }
        return dict
    }

    private func inspectResultJSON(_ result: InspectResult) -> [String: Any] {
        var dict: [String: Any] = [
            "tab_id": result.tabID.uuidString,
            "selector": result.selector,
            "xpath": result.xpath,
            "tag": result.tag,
            "id": result.elementID,
            "url": result.url,
            "text": result.text,
            "attributes": result.attributes,
            "rect": [
                "x": result.rect.origin.x,
                "y": result.rect.origin.y,
                "w": result.rect.size.width,
                "h": result.rect.size.height
            ],
            "captured_at": InspectPayloadSanitiser.isoFormatter.string(from: result.capturedAt)
        ]
        if !result.outerHTML.isEmpty { dict["outer_html"] = result.outerHTML }
        if !result.contextHTML.isEmpty { dict["context_html"] = result.contextHTML }
        if !result.comment.isEmpty { dict["comment"] = result.comment }
        return dict
    }

    func handleWebConsole(
        state: State,
        scope: WebPaneScope,
        since: UInt64,
        level: String?,
        clear: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let entries = resolved.webState.consoleBuffer.entries(since: since)
        let filtered: [RingBuffer<ConsoleLine>.Entry] = if let level {
            entries.filter { $0.value.level.rawValue == level }
        } else {
            entries
        }
        let nextSeq = resolved.webState.consoleBuffer.nextSeq
        let dropped = resolved.webState.consoleBuffer.droppedSinceLastDrain
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "lines": filtered.map(consoleLineJSON),
            "next_since": nextSeq,
            "dropped": dropped
        ])
        // Acknowledge the reported drops so the next call only
        // surfaces drops that accumulated after this drain. Always
        // dispatched, even when `dropped == 0`, so the reducer
        // doesn't have to branch on it.
        var effects: [Effect<Action>] = [
            .send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webConsoleAcknowledgeDrops(paneID: resolved.paneID)
            )))
        ]
        if clear {
            effects.append(.send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webConsoleClear(paneID: resolved.paneID)
            ))))
        }
        return .merge(effects)
    }

    func handleWebInspect(
        state: State,
        scope: WebPaneScope,
        sendTo: String?,
        submit: Bool,
        disarm: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }

        // Explicit disarm path: no arming, just clear server-side
        // state and the in-page picker.
        if disarm {
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolved.paneID.uuidString,
                "armed": false
            ])
            let resolvedPaneID = resolved.paneID
            let store = webPaneStore
            return .merge(
                .send(.workspaces(.element(
                    id: resolved.workspace.id,
                    action: .webInspectDisarm(paneID: resolvedPaneID)
                ))),
                .run { _ in
                    await MainActor.run {
                        store.coordinatorIfExists(for: resolvedPaneID)?.disarmInspector()
                    }
                }
            )
        }

        guard let tab = resolved.webState.activeTab else {
            reply?.error("web pane has no active tab")
            return .none
        }

        // Resolve `--send-to` to a concrete pane UUID up front so we
        // can report a clear error before arming. Only `.shell` panes
        // have a terminal surface that `paneSendText` can write to —
        // markdown / scratchpad / diff / web destinations would
        // silently no-op inside `SurfaceManager.sendText`, so reject
        // them here with a typed error instead.
        let sendToPaneID: UUID?
        if let sendTo {
            switch resolvePaneTarget(
                state: state, paneID: scope.paneID, target: sendTo,
                workspaceFilter: scope.workspaceFilter
            ) {
            case .found(let resolvedID, let workspace):
                guard let destPane = workspace.panes[id: resolvedID] else {
                    reply?.error("--send-to: pane not found: \(resolvedID.uuidString)")
                    return .none
                }
                guard destPane.type == .shell else {
                    reply?.error(
                        "--send-to: destination must be a shell pane (got: \(destPane.type.rawValue))"
                    )
                    return .none
                }
                sendToPaneID = resolvedID
            case .error(let message):
                reply?.error("--send-to: \(message)")
                return .none
            }
        } else {
            sendToPaneID = nil
        }

        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let store = webPaneStore
        let tabID = tab.id
        let isPrivate = resolved.webState.isPrivate

        return .run { send in
            // Arm the in-page picker on the main actor and read back
            // the nonce. Hop to MainActor.run synchronously so we
            // can return the nonce before the reply lands.
            let nonce: String? = await MainActor.run {
                store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).armInspector(tabID: tabID)
            }
            guard let nonce else {
                reply?.error("failed to arm inspector for active tab")
                return
            }
            await send(.workspaces(.element(
                id: workspaceID,
                action: .webInspectArmedFor(
                    paneID: resolvedPaneID,
                    sendTo: sendToPaneID,
                    nonce: nonce
                )
            )))
            if submit {
                await send(.setWebInspectArmedSubmit(paneID: resolvedPaneID, submit: true))
            }
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "tab_id": tabID.uuidString,
                "armed": true,
                "send_to": sendToPaneID?.uuidString ?? "",
                "submit": submit
            ])
        }
    }

    func handleWebInspectResult(
        state: State,
        scope: WebPaneScope,
        clear: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        // Drain *both* sources: the legacy single-shot queue
        // (`inspectResultQueue`, written by `nex web inspect`
        // without `--send-to`) and the batch panel items (the
        // unified UI queue — items collected via the scope button
        // that haven't been sent to a target yet). Items annotate
        // with their per-batch comment before serialising.
        var results: [InspectResult] = []
        results.append(contentsOf: resolved.webState.inspectResultQueue)
        if let batch = resolved.webState.batchInspect {
            for item in batch.items {
                var annotated = item.result
                annotated.comment = item.comment
                results.append(annotated)
            }
        }
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "results": results.map(inspectResultJSON)
        ])
        if clear {
            var effects: [Effect<Action>] = [
                .send(.workspaces(.element(
                    id: resolved.workspace.id,
                    action: .webInspectResultClear(paneID: resolved.paneID)
                )))
            ]
            // Only tear down the batch when one exists — `Cancel`
            // disarms the page picker, and a single-shot inspect may
            // be armed on this pane independently of any batch.
            if resolved.webState.batchInspect != nil {
                effects.append(.send(.webBatchInspectCancel(paneID: resolved.paneID)))
            }
            return .merge(effects)
        }
        return .none
    }

    // MARK: - Web pane storage / cookies handlers (Phase 5)

    func handleWebPrivate(
        state: State,
        scope: WebPaneScope,
        enabled: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let already = resolved.webState.isPrivate == enabled
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "private": enabled,
            "changed": !already
        ])
        if already { return .none }
        return .send(.webPaneSetPrivate(paneID: resolved.paneID, enabled: enabled))
    }

    func handleWebCookiesList(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let isPrivate = resolved.webState.isPrivate
        return .run { _ in
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let coord = store.coordinatorIfExists(for: resolvedPaneID) else {
                        continuation.resume(returning: [])
                        return
                    }
                    coord.dataStore.httpCookieStore.getAllCookies { result in
                        continuation.resume(returning: result)
                    }
                }
            }
            let payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "private": isPrivate,
                "cookies": cookies.map(Self.cookieJSON)
            ]
            reply?.sendAndClose(payload)
        }
    }

    func handleWebCookiesClear(
        state: State,
        scope: WebPaneScope,
        domain: String?,
        all: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        if all, domain != nil {
            reply?.error("--all and --domain are mutually exclusive")
            return .none
        }
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        return .run { _ in
            let removed: Int = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let coord = store.coordinatorIfExists(for: resolvedPaneID) else {
                        continuation.resume(returning: 0)
                        return
                    }
                    let dataStore = coord.dataStore
                    if all {
                        let types = WKWebsiteDataStore.allWebsiteDataTypes()
                        dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
                            // Count is unknown for the omnibus
                            // removeData path; report -1 so callers
                            // can distinguish from "0 cookies matched".
                            continuation.resume(returning: -1)
                        }
                        return
                    }
                    let needle = domain.map(HTTPCookie.canonicalDomain)
                    dataStore.httpCookieStore.deleteAll(
                        matching: { cookie in
                            guard let needle else { return true }
                            return HTTPCookie.canonicalDomain(cookie.domain) == needle
                        },
                        completion: { count in continuation.resume(returning: count) }
                    )
                }
            }
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString
            ]
            if all {
                payload["cleared_site_data"] = true
            } else {
                payload["deleted"] = removed
                if let domain {
                    payload["domain"] = domain
                }
            }
            reply?.sendAndClose(payload)
        }
    }

    func handleWebCookiesDelete(
        state: State,
        scope: WebPaneScope,
        name: String,
        domain: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        return .run { _ in
            let removed: Int = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let coord = store.coordinatorIfExists(for: resolvedPaneID) else {
                        continuation.resume(returning: 0)
                        return
                    }
                    let needle = domain.map(HTTPCookie.canonicalDomain)
                    coord.dataStore.httpCookieStore.deleteAll(
                        matching: { cookie in
                            guard cookie.name == name else { return false }
                            guard let needle else { return true }
                            return HTTPCookie.canonicalDomain(cookie.domain) == needle
                        },
                        completion: { count in continuation.resume(returning: count) }
                    )
                }
            }
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "deleted": removed,
                "name": name
            ]
            if let domain {
                payload["domain"] = domain
            }
            reply?.sendAndClose(payload)
        }
    }

    private static func cookieJSON(_ cookie: HTTPCookie) -> [String: Any] {
        var dict: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "is_secure": cookie.isSecure,
            "is_http_only": cookie.isHTTPOnly
        ]
        if let expires = cookie.expiresDate {
            dict["expires"] = expires.timeIntervalSince1970
        }
        if cookie.isSessionOnly {
            dict["session_only"] = true
        }
        return dict
    }

    /// Returns the last `n` lines of `text`, joined by `\n`. Preserves
    /// a real trailing newline if present (terminal viewport reads
    /// typically end with `\n`); detected via `hasSuffix` so empty
    /// input collapses to `""` rather than `"\n"`.
    static func tailLines(_ text: String, _ n: Int) -> String {
        guard n > 0, !text.isEmpty else { return "" }
        let hasTrailingNewline = text.hasSuffix("\n")
        let body = hasTrailingNewline ? String(text.dropLast()) : text
        let parts = body.split(separator: "\n", omittingEmptySubsequences: false)
        let tailed = parts.suffix(n).joined(separator: "\n")
        return hasTrailingNewline ? tailed + "\n" : tailed
    }

    var body: some ReducerOf<Self> {
        // Declared BEFORE the main reducer's `.forEach` so it runs while the
        // pane is still `.waitingForInput` — the child `clearPaneStatus`
        // handler (which flips it to `.idle`) runs first within the
        // `.forEach`, so reading the status from the parent interception
        // below would always see `.idle`. A leading reducer sidesteps that.
        Reduce { state, action in
            if case let .workspaces(.element(id: wsID, action: .clearPaneStatus(paneID))) = action,
               state.workspaces[id: wsID]?.panes[id: paneID]?.status == .waitingForInput {
                state.completedAgentCount += 1
                if let workspace = state.workspaces[id: wsID], let pane = workspace.panes[id: paneID] {
                    state.completedAgents.insert(CompletedAgent(
                        workspaceName: workspace.name,
                        workspaceColor: workspace.color,
                        paneTitle: pane.title ?? pane.label ?? "Shell",
                        completedAt: Date()
                    ), at: 0)
                    if state.completedAgents.count > 30 {
                        state.completedAgents.removeLast(state.completedAgents.count - 30)
                    }
                }
            }
            return .none
        }
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
                    },
                    .run { [userDefaults] send in
                        let json = userDefaults.stringForKey(FavouritesStorage.defaultsKey)
                        await send(.favouritesLoaded(FavouritesStorage.decode(json)))
                    },
                    .run { [userDefaults] send in
                        let json = userDefaults.stringForKey(LabelPresetsStorage.defaultsKey)
                        await send(.labelPresetsLoaded(LabelPresetsStorage.decode(json)))
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
                let workspaceID = workspace.id
                let watcherSeeds: [Effect<Action>] = workspace.repoAssociations.map { assoc in
                    Effect.send(.startHeadWatcher(
                        workspaceID: workspaceID,
                        associationID: assoc.id,
                        worktreePath: assoc.worktreePath
                    ))
                }
                return .merge(
                    [
                        .run { _ in
                            await surfaceManager.createSurface(paneID: paneID, workingDirectory: cwd, backgroundOpacity: opacity)
                        },
                        .send(.persistState)
                    ] + watcherSeeds
                )

            case .deleteWorkspace(let id):
                guard let workspace = state.workspaces[id: id] else { return .none }
                let paneIDs = workspace.layout.allPaneIDs
                    + workspace.parkedPanes.map(\.id)
                let assocIDs = workspace.repoAssociations.map(\.id)
                // Capture associations with live graft sessions BEFORE
                // removal so we can issue `forceStop` for each — head
                // watcher cancellation alone leaves the graft mirroring
                // a worktree whose association is gone.
                let liveGraftAssocIDs = assocIDs.filter { state.graft.sessions[id: $0] != nil }
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

                let stopEffects = assocIDs.map { Effect.send(Action.stopHeadWatcher(associationID: $0)) }
                let graftStopEffects = liveGraftAssocIDs.map { Effect.send(Action.graft(.forceStop($0))) }
                let mgr = surfaceManager
                return .merge(
                    [
                        .run { _ in
                            for paneID in paneIDs {
                                await mgr.destroySurface(paneID: paneID)
                            }
                            // Drop the sync-input group for the deleted
                            // workspace so SurfaceManager.syncGroups
                            // doesn't leak the entry indefinitely.
                            mgr.setSyncGroup(workspaceID: id, paneIDs: [])
                        },
                        .send(.persistState)
                    ] + stopEffects + graftStopEffects
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
                // Capture associations with live graft sessions BEFORE
                // removal — otherwise the graft keeps mirroring a
                // worktree whose association is gone with no UI/CLI
                // path to stop it.
                var liveGraftAssocIDs: [UUID] = []
                for id in ids {
                    guard let workspace = state.workspaces[id: id] else { continue }
                    panesToDestroy.append(contentsOf: workspace.layout.allPaneIDs)
                    panesToDestroy.append(contentsOf: workspace.parkedPanes.map(\.id))
                    liveGraftAssocIDs.append(contentsOf: workspace.repoAssociations
                        .map(\.id)
                        .filter { state.graft.sessions[id: $0] != nil })
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
                let deletedWorkspaceIDs = ids
                let graftStopEffects = liveGraftAssocIDs.map { Effect.send(Action.graft(.forceStop($0))) }
                let mgr = surfaceManager
                return .merge(
                    [
                        .run { _ in
                            for paneID in paneIDs {
                                await mgr.destroySurface(paneID: paneID)
                            }
                            // Drop sync-input groups for the deleted
                            // workspaces (mirrors `deleteWorkspace`).
                            for wsID in deletedWorkspaceIDs {
                                mgr.setSyncGroup(workspaceID: wsID, paneIDs: [])
                            }
                        },
                        .send(.persistState)
                    ] + graftStopEffects
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

            case .setWorkspaceIcon(let id, let icon):
                guard state.workspaces[id: id] != nil else { return .none }
                state.workspaces[id: id]?.icon = icon
                return .send(.persistState)

            case .requestWorkspaceCustomEmoji(let id):
                guard let workspace = state.workspaces[id: id] else { return .none }
                state.workspaceCustomEmojiPrompt = WorkspaceCustomEmojiPrompt(
                    workspaceID: id,
                    workspaceName: workspace.name
                )
                return .none

            case .cancelWorkspaceCustomEmoji:
                state.workspaceCustomEmojiPrompt = nil
                return .none

            case .confirmWorkspaceCustomEmoji(let emoji):
                // Same server-side "1 emoji grapheme" guard as the group path.
                let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let prompt = state.workspaceCustomEmojiPrompt,
                      let firstGrapheme = trimmed.first,
                      firstGrapheme.isGraphemeEmoji
                else {
                    state.workspaceCustomEmojiPrompt = nil
                    return .none
                }
                state.workspaceCustomEmojiPrompt = nil
                guard state.workspaces[id: prompt.workspaceID] != nil else { return .none }
                state.workspaces[id: prompt.workspaceID]?.icon = .emoji(String(firstGrapheme))
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
                    // Capture associations with live graft sessions
                    // BEFORE removal so we can issue `forceStop` for
                    // each — otherwise grafts on child workspaces
                    // keep running with no way to stop them.
                    var liveGraftAssocIDs: [UUID] = []
                    for wsID in childIDs {
                        guard let workspace = state.workspaces[id: wsID] else { continue }
                        paneIDs.append(contentsOf: workspace.layout.allPaneIDs)
                        paneIDs.append(contentsOf: workspace.parkedPanes.map(\.id))
                        liveGraftAssocIDs.append(contentsOf: workspace.repoAssociations
                            .map(\.id)
                            .filter { state.graft.sessions[id: $0] != nil })
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
                    let cascadedWorkspaceIDs = childIDs
                    let graftStopEffects = liveGraftAssocIDs.map { Effect.send(Action.graft(.forceStop($0))) }
                    let mgr = surfaceManager
                    return .merge(
                        [
                            .run { _ in
                                for paneID in captured {
                                    await mgr.destroySurface(paneID: paneID)
                                }
                                // Drop sync-input groups for the cascaded
                                // workspaces (mirrors `deleteWorkspace`).
                                for wsID in cascadedWorkspaceIDs {
                                    mgr.setSyncGroup(workspaceID: wsID, paneIDs: [])
                                }
                            },
                            .send(.persistState)
                        ] + graftStopEffects
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
                    // First launch — create a default workspace and
                    // still hand off to GraftFeature so its updates
                    // subscription installs. Without this, a CLI-
                    // started graft on first run would be invisible
                    // to status / stop / quit-flush.
                    return .merge(
                        .send(.createWorkspace(name: "Default")),
                        .send(.graft(.onAppLaunched(parentRepoRoots: [])))
                    )
                }
                state.workspaces = workspaces
                state.groups = groups
                state.activeWorkspaceID = activeID ?? workspaces.first?.id
                state.repoRegistry = repoRegistry
                state.didRestoreWorkspaces = true

                // Use persisted topLevelOrder if present; otherwise synthesize
                // from the flat workspaces list (legacy DBs predate groups).
                if topLevelOrder.isEmpty {
                    state.syncTopLevelOrderToFlatList()
                } else {
                    state.topLevelOrder = topLevelOrder
                }

                // Collect panes eligible for auto-resume before clearing.
                // Any pane with a agentSessionID is resumable — the session
                // remains valid regardless of the pane's current status.
                var resumablePanes: [(paneID: UUID, sessionID: String)] = []
                for workspace in workspaces {
                    for pane in workspace.panes {
                        if let sessionID = pane.agentSessionID {
                            resumablePanes.append((paneID: pane.id, sessionID: sessionID))
                        }
                    }
                }

                // Clear session IDs and reset status to prevent stale
                // resumes on next restart. Status is tied to a live PTY,
                // which never survives a restart, so reset all non-idle
                // panes regardless of session — otherwise a persisted
                // `.running` falsely triggers the quit dialog at the
                // next Cmd+Q with no real agents in flight (issue #129).
                for workspace in state.workspaces {
                    for pane in workspace.panes {
                        if pane.agentSessionID != nil {
                            state.workspaces[id: workspace.id]?.panes[id: pane.id]?.agentSessionID = nil
                        }
                        if pane.status != .idle {
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
                // Seed HEAD watchers for every persisted RepoAssociation so
                // sidebar branch/status updates land within ~200ms of any
                // `git checkout` after restart.
                let watcherSeeds: [Effect<Action>] = state.workspaces.flatMap { ws in
                    ws.repoAssociations.map { assoc in
                        Effect.send(.startHeadWatcher(
                            workspaceID: ws.id,
                            associationID: assoc.id,
                            worktreePath: assoc.worktreePath
                        ))
                    }
                }

                let parentRepoRoots = Array(Set(state.repoRegistry.map(\.path)))
                return .merge(
                    [
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
                        .send(.startGitStatusTimer),
                        .send(.migrateLabelsToPresets),
                        .send(.graft(.onAppLaunched(parentRepoRoots: parentRepoRoots)))
                    ] + watcherSeeds
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

            case .workspaces(.element(id: let wsID, action: .addRepoAssociation(let assoc))):
                return .merge(
                    .send(.persistState),
                    .send(.startHeadWatcher(
                        workspaceID: wsID,
                        associationID: assoc.id,
                        worktreePath: assoc.worktreePath
                    ))
                )

            case .workspaces(.element(_, action: .removeRepoAssociation(let associationID))):
                state.gitStatuses.removeValue(forKey: associationID)
                return .merge(
                    .send(.stopHeadWatcher(associationID: associationID)),
                    .send(.persistState)
                )

            case .workspaces(.element(id: let wsID, action: .paneDirectoryChanged(let paneID, let directory))):
                return .merge(
                    .send(.persistState),
                    scheduleAutoLink(workspaceID: wsID, paneID: paneID, directory: directory, in: state),
                    scheduleAutoUnlink(workspaceID: wsID, in: state)
                )

            case .workspaces(.element(id: let wsID, action: .closePane(let paneID))):
                if let renamingPaneID = state.renamingPaneID,
                   !state.workspaces.contains(where: { $0.panes[id: renamingPaneID] != nil }) {
                    state.renamingPaneID = nil
                }
                state.webInspectArmedSubmit.removeValue(forKey: paneID)
                return .merge(
                    .send(.persistState),
                    scheduleAutoUnlink(workspaceID: wsID, in: state)
                )

            case .workspaces(.element(_, action: .openMarkdownFile(_, .some(let reusePaneID)))):
                // `--here` reuse parks (doesn't remove) the source
                // pane. Only clear renamingPaneID if it targeted the
                // source — the overlay can't continue into a parked
                // pane that's no longer visible. No auto-unlink pass
                // is needed because the source still owns its working
                // directory, just off-layout.
                if state.renamingPaneID == reusePaneID {
                    state.renamingPaneID = nil
                }
                return .send(.persistState)

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

            case .graft:
                // Handled by the GraftFeature Scope below.
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

            // MARK: - Web favourites

            case .favouritesLoaded(let list):
                state.favourites = list
                return .none

            case .removeFavourite(let id):
                guard let idx = state.favourites.firstIndex(where: { $0.id == id })
                else { return .none }
                state.favourites.remove(at: idx)
                return persistFavourites(state.favourites)

            case .renameFavourite(let id, let title):
                guard let idx = state.favourites.firstIndex(where: { $0.id == id })
                else { return .none }
                state.favourites[idx].title = title
                return persistFavourites(state.favourites)

            case .moveFavourite(let from, let to):
                guard from >= 0, from < state.favourites.count,
                      to >= 0, to <= state.favourites.count, from != to
                else { return .none }
                state.favourites.move(fromOffsets: IndexSet(integer: from), toOffset: to)
                return persistFavourites(state.favourites)

            case .toggleFavourite(let url, let title):
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }
                if let existing = state.favourites.firstMatching(url: trimmed) {
                    state.favourites.removeAll { $0.id == existing.id }
                } else {
                    state.favourites.append(Favourite(id: uuid(), url: trimmed, title: title))
                }
                return persistFavourites(state.favourites)

            // MARK: - Label presets

            case .labelPresetsLoaded(let list):
                state.labelPresets = list
                state.didLoadLabelPresets = true
                return .send(.migrateLabelsToPresets)

            case .migrateLabelsToPresets:
                // Only once both halves have loaded (they load concurrently).
                guard state.didRestoreWorkspaces, state.didLoadLabelPresets else { return .none }
                // One-shot: a back-fill that ran every launch would resurrect a
                // preset the user later deletes (its label can still be applied
                // to a workspace), reverting their delete + custom colour.
                guard !userDefaults.boolForKey(LabelPresetsStorage.migratedKey) else { return .none }
                let markMigrated = Effect<Action>.run { _ in
                    userDefaults.setBool(true, LabelPresetsStorage.migratedKey)
                }
                var seen = Set(state.labelPresets.map(\.name))
                var added: [LabelPreset] = []
                for workspace in state.workspaces {
                    for label in workspace.labels where !seen.contains(label) {
                        seen.insert(label)
                        // Default colour; the user can recolour it in Settings.
                        added.append(LabelPreset(name: label, color: .named(.gray)))
                    }
                }
                guard !added.isEmpty else { return markMigrated }
                state.labelPresets.append(contentsOf: added)
                return .merge(persistLabelPresets(state.labelPresets), markMigrated)

            case .addLabelPreset(let name, let color):
                let normalized = WorkspaceFeature.normalizeLabel(name)
                guard !normalized.isEmpty,
                      !state.labelPresets.contains(where: { $0.name == normalized })
                else { return .none }
                state.labelPresets.append(LabelPreset(name: normalized, color: color))
                return persistLabelPresets(state.labelPresets)

            case .updateLabelPreset(let id, let name, let color):
                guard let idx = state.labelPresets.firstIndex(where: { $0.id == id })
                else { return .none }
                let normalized = WorkspaceFeature.normalizeLabel(name)
                guard !normalized.isEmpty else { return .none }
                // Reject a rename that collides with a *different* preset.
                // Excluding the edited row by id means a recolor or a
                // whitespace-only edit of the same row is never a
                // self-collision.
                if state.labelPresets.contains(where: { $0.id != id && $0.name == normalized }) {
                    return .none
                }
                state.labelPresets[idx].name = normalized
                state.labelPresets[idx].color = color
                return persistLabelPresets(state.labelPresets)

            case .setLabelPresetTextColor(let id, let textColor):
                guard let idx = state.labelPresets.firstIndex(where: { $0.id == id })
                else { return .none }
                state.labelPresets[idx].textColor = textColor
                return persistLabelPresets(state.labelPresets)

            case .removeLabelPreset(let id):
                guard let idx = state.labelPresets.firstIndex(where: { $0.id == id })
                else { return .none }
                state.labelPresets.remove(at: idx)
                return persistLabelPresets(state.labelPresets)

            case .moveLabelPreset(let from, let to):
                guard from >= 0, from < state.labelPresets.count,
                      to >= 0, to <= state.labelPresets.count, from != to
                else { return .none }
                state.labelPresets.move(fromOffsets: IndexSet(integer: from), toOffset: to)
                return persistLabelPresets(state.labelPresets)

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

            case .restartSocketServer:
                // Tear down and rebind the Unix socket (clears /tmp/nex.sock
                // and any wedged client FDs); bring TCP back if configured.
                // onMessage is a singleton property, so it survives the cycle.
                return .run { [tcpPort = state.tcpPort] _ in
                    socketServer.stop()
                    socketServer.start()
                    if tcpPort > 0 {
                        _ = socketServer.startTCP(port: tcpPort)
                    }
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

            case .openWebPanePath(let url, _):
                guard let activeID = state.activeWorkspaceID else { return .none }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .openWebPane(
                        paneID: uuid(),
                        tabID: uuid(),
                        url: url,
                        reusePaneID: nil,
                        isPrivate: false
                    )
                )))

            case .webPaneFocusURLBar(let paneID):
                state.webPaneURLFocusTokens[paneID, default: 0] &+= 1
                return .none

            case .webPaneOpenNewTab(let paneID, let url):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let newTabID = uuid()
                // Blank new tab → auto-focus the URL bar so the user can
                // type a URL immediately. A tab opened with a preset URL
                // is loading content, so leave focus to the WKWebView.
                if url?.isEmpty ?? true {
                    state.webPaneURLFocusTokens[paneID, default: 0] &+= 1
                }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .webPaneTabOpen(
                        paneID: paneID,
                        tabID: newTabID,
                        url: url ?? "",
                        makeActive: true
                    )
                )))

            case .webPaneTabCycleFocused(let offset):
                guard let activeID = state.activeWorkspaceID,
                      let workspace = state.workspaces[id: activeID],
                      let focusedID = workspace.focusedPaneID,
                      workspace.panes[id: focusedID]?.type == .web else { return .none }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .webPaneTabCycle(paneID: focusedID, offset: offset)
                )))

            case .webPaneTabCloseActiveFocused:
                guard let activeID = state.activeWorkspaceID,
                      let workspace = state.workspaces[id: activeID],
                      let focusedID = workspace.focusedPaneID,
                      workspace.panes[id: focusedID]?.type == .web,
                      let webState = workspace.webPanes[focusedID],
                      let activeTabID = webState.activeTab?.id else { return .none }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .webPaneTabClose(paneID: focusedID, tabID: activeTabID)
                )))

            case .setWebInspectArmedSubmit(let paneID, let submit):
                if submit {
                    state.webInspectArmedSubmit[paneID] = true
                } else {
                    state.webInspectArmedSubmit.removeValue(forKey: paneID)
                }
                return .none

            case .webBatchInspectStart(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let webState = workspace.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                let tabID = tab.id
                let isPrivate = webState.isPrivate
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchInspectBegin(paneID: paneID)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .run { send in
                        let nonce: String? = await MainActor.run {
                            store.coordinator(for: paneID, isPrivate: isPrivate).armInspector(tabID: tabID, sticky: true)
                        }
                        guard let nonce else { return }
                        await send(.workspaces(.element(
                            id: workspaceID,
                            action: .webInspectArmedFor(
                                paneID: paneID, sendTo: nil, nonce: nonce
                            )
                        )))
                    }
                )

            case .webBatchInspectToggle(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let batch = workspace.webPanes[paneID]?.batchInspect
                if batch == nil {
                    return .send(.webBatchInspectStart(paneID: paneID))
                } else if batch?.panelVisible == true {
                    return .send(.webBatchInspectHide(paneID: paneID))
                } else {
                    return .send(.webBatchInspectShow(paneID: paneID))
                }

            case .webBatchInspectHide(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchPanelVisible(paneID: paneID, visible: false)
                    ))),
                    // Disarm the page picker and clear the on-page
                    // markers; the SwiftUI panel + items in state
                    // remain so the next show restores everything.
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webInspectDisarm(paneID: paneID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?.disarmInspector()
                        }
                    }
                )

            case .webBatchInspectShow(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let webState = workspace.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                let tabID = tab.id
                let isPrivate = webState.isPrivate
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchPanelVisible(paneID: paneID, visible: true)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .run { send in
                        let nonce: String? = await MainActor.run {
                            store.coordinator(for: paneID, isPrivate: isPrivate).armInspector(tabID: tabID, sticky: true)
                        }
                        guard let nonce else { return }
                        await send(.workspaces(.element(
                            id: workspaceID,
                            action: .webInspectArmedFor(
                                paneID: paneID, sendTo: nil, nonce: nonce
                            )
                        )))
                    }
                )

            case .webPaneSetPrivate(let paneID, let enabledOpt):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let current = workspace.webPanes[paneID]?.isPrivate ?? false
                let enabled = enabledOpt ?? !current
                guard current != enabled else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webPaneSetIsPrivate(paneID: paneID, enabled: enabled)
                    ))),
                    // Destroy the coordinator so the host's next pass
                    // builds a fresh one against the new data store.
                    // The host's mismatch check would catch this too,
                    // but doing it here keeps the teardown ordered
                    // with the state flip.
                    .run { _ in
                        await MainActor.run {
                            store.destroyCoordinator(paneID: paneID)
                        }
                    }
                )

            case .webBatchInspectCancel(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                state.webInspectArmedSubmit.removeValue(forKey: paneID)
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchInspectCleared(paneID: paneID)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webInspectDisarm(paneID: paneID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?.disarmInspector()
                        }
                    }
                )

            case .webBatchInspectSend(let paneID, let sendTo):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let batch = workspace.webPanes[paneID]?.batchInspect else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                let submit = state.webInspectArmedSubmit[paneID] ?? false
                state.webInspectArmedSubmit.removeValue(forKey: paneID)
                // Seed `lastBatchTarget` so the next batch on this
                // pane defaults to the same destination. In-memory
                // only — fresh launch always starts unselected.
                if !batch.items.isEmpty {
                    let memory: BatchTargetMemory = sendTo.map { .pane($0) } ?? .local
                    state.workspaces[id: workspaceID]?.webPanes[paneID]?.lastBatchTarget = memory
                }

                var effects: [Effect<Action>] = [
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchInspectCleared(paneID: paneID)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webInspectDisarm(paneID: paneID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?.disarmInspector()
                        }
                    }
                ]
                // Empty batch — nothing to send, just tear down.
                if batch.items.isEmpty {
                    return .merge(effects)
                }
                if let sendTo {
                    let formatted = InspectPayloadSanitiser.formatBatchForPaste(batch.items)
                    effects.append(paneSendText(paneID: sendTo, text: formatted, bare: !submit))
                } else {
                    // No destination — queue each item locally for
                    // `nex web inspect-result` to drain. Stamp the
                    // per-item comment onto the result before
                    // enqueueing so `inspectResultJSON` surfaces it
                    // (the single-shot picker path always leaves
                    // `comment` empty).
                    for item in batch.items {
                        var annotated = item.result
                        annotated.comment = item.comment
                        effects.append(.send(.workspaces(.element(
                            id: workspaceID,
                            action: .webInspectResultReceived(
                                paneID: paneID, result: annotated
                            )
                        ))))
                    }
                }
                return .merge(effects)

            case .webBatchFocusItem(let paneID, let itemID, let origin):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let webState = workspace.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let tabID = tab.id
                // Push the focus ring + badge pulse onto the page
                // regardless of origin — the persistent ring is the
                // primary visual feedback, and re-pulsing the badge
                // is cheap. `.panel` also scrolls the page; `.page`
                // skips the scroll since the element is already under
                // the cursor.
                let scrollIntoView = origin == .panel
                return .merge(
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webBatchItemFocused(paneID: paneID, itemID: itemID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?
                                .highlightBatchMarker(
                                    tabID: tabID,
                                    itemID: itemID,
                                    scrollIntoView: scrollIntoView
                                )
                        }
                    }
                )

            case .syncBatchMarkers(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let webState = workspace.webPanes[paneID]
                let tabID = webState?.activeTab?.id
                // Hidden panel = no on-page markers either. Items
                // still live in state for when the user re-opens.
                let panelVisible = webState?.batchInspect?.panelVisible ?? false
                let items: [BatchMarkerInput] = panelVisible
                    ? (webState?.batchInspect?.items ?? [])
                    .enumerated()
                    .map { idx, item in
                        BatchMarkerInput(
                            id: item.id,
                            selector: item.result.selector,
                            label: String(idx + 1),
                            comment: item.comment
                        )
                    }
                    : []
                let store = webPaneStore
                return .run { _ in
                    await MainActor.run {
                        guard let coordinator = store.coordinatorIfExists(for: paneID),
                              let tabID else { return }
                        if items.isEmpty {
                            coordinator.clearBatchMarkers(tabID: tabID)
                        } else {
                            coordinator.syncBatchMarkers(tabID: tabID, items: items)
                        }
                    }
                }

            case .pushBatchCommentToPage(let paneID, let itemID, let comment):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let tabID = workspace.webPanes[paneID]?.activeTab?.id else { return .none }
                let store = webPaneStore
                return .run { _ in
                    await MainActor.run {
                        store.coordinatorIfExists(for: paneID)?
                            .pushBatchComment(tabID: tabID, itemID: itemID, comment: comment)
                    }
                }

            case .webBatchDismissPopover(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let tabID = workspace.webPanes[paneID]?.activeTab?.id
                let store = webPaneStore
                return .merge(
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webBatchItemFocused(paneID: paneID, itemID: nil)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            guard let tabID else { return }
                            store.coordinatorIfExists(for: paneID)?.unfocusBatch(tabID: tabID)
                        }
                    }
                )

            case .webInspectPayloadReceived(let paneID, let result):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let webState = workspace.webPanes[paneID]

                // Batch mode: append to the in-progress batch and
                // leave the picker armed (sticky) for the next pick.
                // No paste happens until the user hits Send. Also
                // refresh the on-page numbered markers so the new
                // pick gets a badge, then focus the new item so the
                // page draws its ring and the panel auto-focuses the
                // comment field. A hidden batch (panelVisible == false)
                // is paused — `nex web inspect --send-to` can arm a
                // single-shot inspect on top, so route the result down
                // the single-shot path instead of hijacking it.
                if webState?.batchInspect?.panelVisible == true {
                    let item = BatchInspectItem(result: result)
                    return .merge(
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .webBatchItemAdded(paneID: paneID, item: item)
                        ))),
                        .send(.syncBatchMarkers(paneID: paneID)),
                        // Origin .page — the click was on the page,
                        // so we don't re-scroll the element into view
                        // (it's already where the user clicked).
                        .send(.webBatchFocusItem(
                            paneID: paneID, itemID: item.id, origin: .page
                        ))
                    )
                }

                // Single-shot mode: queue on source pane (so
                // `nex web inspect-result` can drain it later), and
                // if this arm was set up with `--send-to`, paste the
                // formatted block into the destination via the
                // factored paneSendText helper. Submit-after-paste
                // is recorded out-of-band in `webInspectArmedSubmit`
                // (Phase 3 ships paste-only as the safe default).
                let sendTo = webState?.pendingInspectSendTo
                let submit = state.webInspectArmedSubmit[paneID] ?? false
                var effects: [Effect<Action>] = [
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webInspectResultReceived(paneID: paneID, result: result)
                    ))),
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webInspectDisarm(paneID: paneID)
                    )))
                ]
                state.webInspectArmedSubmit.removeValue(forKey: paneID)
                if let sendTo {
                    let formatted = InspectPayloadSanitiser.formatForPaste(result)
                    effects.append(paneSendText(paneID: sendTo, text: formatted, bare: !submit))
                }
                return .merge(effects)

            case .openDiffPath(let repoPath, let targetPath, let fromPaneID):
                guard let activeID = state.activeWorkspaceID else { return .none }
                let workspace = state.workspaces[id: activeID]
                let resolvedTarget: String? = {
                    guard let targetPath, !targetPath.isEmpty else { return nil }
                    if targetPath.hasPrefix("/") { return targetPath }
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
                        return (cwd as NSString).appendingPathComponent(targetPath)
                    }
                    return targetPath
                }()
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .openDiffPane(
                        repoPath: repoPath,
                        targetPath: resolvedTarget,
                        reusePaneID: nil
                    )
                )))

            // MARK: - Socket Messages

            case .socketMessage(let message, let reply):
                switch message {
                // MARK: Agent lifecycle

                case .agentStarted(let paneID):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    // If we get a "start" while already running, the previous "stop"
                    // was missed (e.g. user interrupted Claude). Reset to idle first
                    // so the status lifecycle stays clean.
                    if workspace.pane(id: paneID)?.status == .running {
                        state.workspaces[id: workspace.id]?.mutatePane(id: paneID) {
                            $0.status = .idle
                        }
                    }

                    return .merge(
                        .send(.workspaces(.element(id: workspace.id, action: .agentStarted(paneID: paneID)))),
                        .send(.updateExternalIndicators)
                    )

                case .agentStopped(let paneID):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    let isFocused = state.activeWorkspaceID == workspace.id && workspace.focusedPaneID == paneID
                    let notifService = notificationService
                    let wsID = workspace.id
                    let isAppActive = MainActor.assumeIsolated { NSApp.isActive }
                    let shouldNotify = !isFocused || !isAppActive
                    let shouldBounce = !isAppActive
                    let title = workspace.pane(id: paneID)?.title ?? workspace.name

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
                    guard let workspace = state.workspaceContainingPane(paneID)
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
                    guard let workspace = state.workspaceContainingPane(paneID)
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
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    return .merge(
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .sessionStarted(paneID: paneID, sessionID: sessionID)
                        ))),
                        .send(.updateExternalIndicators)
                    )

                case .sessionEnded(let paneID, let sessionID):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    // Persist so the cleared session id survives the next
                    // launch — otherwise the resume loop on restart would
                    // still see the stale id and reattach a dead session.
                    return .merge(
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .sessionEnded(paneID: paneID, sessionID: sessionID)
                        ))),
                        .send(.persistState)
                    )

                // MARK: Pane commands

                case let .paneSplit(paneID, direction, path, name, target, workspaceFilter):
                    return handlePaneSplit(
                        state: &state,
                        paneID: paneID,
                        direction: direction,
                        path: path,
                        name: name,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case let .paneCreate(paneID, path, name, target, workspaceFilter):
                    return handlePaneCreate(
                        state: &state,
                        paneID: paneID,
                        path: path,
                        name: name,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case .paneClose(let paneID, let target, let workspaceFilter):
                    return handlePaneClose(
                        state: state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case let .paneName(paneID, target, workspace, name):
                    return handlePaneName(
                        state: &state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspace,
                        name: name,
                        reply: reply
                    )

                case .paneSend(let paneID, let target, let text, let workspaceFilter, let bare):
                    return handlePaneSend(
                        state: state,
                        paneID: paneID,
                        target: target,
                        text: text,
                        workspaceFilter: workspaceFilter,
                        bare: bare,
                        reply: reply
                    )

                case .paneSendKey(let paneID, let target, let key, let workspaceFilter):
                    return handlePaneSendKey(
                        state: state,
                        paneID: paneID,
                        target: target,
                        key: key,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case .paneSync(let paneID, let workspaceFilter, let action):
                    return handlePaneSync(
                        state: state,
                        paneID: paneID,
                        workspaceFilter: workspaceFilter,
                        action: action,
                        reply: reply
                    )

                case .paneSyncExclude(let paneID, let target, let workspaceFilter, let excluded):
                    return handlePaneSyncExclude(
                        state: state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        excluded: excluded,
                        reply: reply
                    )

                case .paneMove(let paneID, let direction):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    state.workspaces[id: workspace.id]?.setFocus(paneID)
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

                    // Capture web sidecar before removal so it can
                    // ride along to the target workspace below. The
                    // Pane struct doesn't carry tab/URL state for
                    // `.web` panes — it lives in `webPanes[paneID]`
                    // on the workspace, and the move must transfer
                    // it explicitly or the target ends up with a
                    // blank pane and `nex web url` fails with
                    // "web pane state missing".
                    let webStateToTransfer: WebPaneState? = pane.type == .web
                        ? sourceWS.webPanes[paneID]
                        : nil

                    // Remove from source
                    state.workspaces[id: sourceWSID]?.panes.remove(id: paneID)
                    if webStateToTransfer != nil {
                        state.workspaces[id: sourceWSID]?.webPanes.removeValue(forKey: paneID)
                    }
                    // Drop any source-side sync exclusion for this pane.
                    // Otherwise a later move-back would silently re-apply
                    // the orphan opt-out with no UI hint to explain why.
                    state.workspaces[id: sourceWSID]?.syncInputExcluded.remove(paneID)
                    let newSourceLayout = state.workspaces[id: sourceWSID]!.layout.removing(paneID: paneID)
                    state.workspaces[id: sourceWSID]?.layout = newSourceLayout
                    state.workspaces[id: sourceWSID]?.currentLayoutIndex = nil

                    // Source-side close-like refocus: walk the per-session
                    // focus stack first so the user lands on whatever they
                    // had focused before the moved pane, not the layout's
                    // first leaf. Mirrors the WorkspaceFeature.closePane
                    // contract.
                    state.workspaces[id: sourceWSID]?.focusHistory.removeAll { $0 == paneID }
                    if state.workspaces[id: sourceWSID]?.focusedPaneID == paneID {
                        let popped = state.workspaces[id: sourceWSID]?.popFocusFromHistory(excluding: paneID) ?? nil
                        state.workspaces[id: sourceWSID]?.focusedPaneID = popped ?? newSourceLayout.allPaneIDs.first
                    }
                    var dropMarkdownFind = false
                    if state.workspaces[id: sourceWSID]?.searchingPaneID == paneID {
                        state.workspaces[id: sourceWSID]?.searchingPaneID = nil
                        state.workspaces[id: sourceWSID]?.searchNeedle = ""
                        state.workspaces[id: sourceWSID]?.searchTotal = nil
                        state.workspaces[id: sourceWSID]?.searchSelected = nil
                        // Drop any in-DOM find marks on a markdown pane being
                        // moved across workspaces (the WKWebView/coordinator
                        // travels with the pane, but its workspace-level
                        // search context does not).
                        dropMarkdownFind = pane.type == .markdown
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
                    if let webStateToTransfer {
                        state.workspaces[id: targetWSID]?.webPanes[paneID] = webStateToTransfer
                    }

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

                    state.workspaces[id: targetWSID]?.setFocus(paneID)
                    state.workspaces[id: targetWSID]?.currentLayoutIndex = nil
                    state.activeWorkspaceID = targetWSID

                    // Issue #121 — cross-workspace move bypasses the
                    // WorkspaceFeature bookkeeping reducer, so we have
                    // to push fresh sync-group snapshots for both
                    // source and target explicitly. Without these, the
                    // source workspace's `SurfaceManager.syncGroups`
                    // entry would still reference the moved pane and
                    // the target would never broadcast to it.
                    let sourceSyncEffect = refreshSyncGroupForWorkspace(
                        workspaceID: sourceWSID, state: state
                    )
                    let targetSyncEffect = refreshSyncGroupForWorkspace(
                        workspaceID: targetWSID, state: state
                    )

                    if dropMarkdownFind {
                        return .merge(
                            .run { _ in
                                await MainActor.run {
                                    MarkdownFindController.shared.close(paneID: paneID)
                                }
                            },
                            sourceSyncEffect,
                            targetSyncEffect,
                            .send(.persistState)
                        )
                    }
                    return .merge(sourceSyncEffect, targetSyncEffect, .send(.persistState))

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

                case .openFile(let path, let paneID, let reuse):
                    if let paneID,
                       let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
                        state.workspaces[id: workspace.id]?.setFocus(paneID)
                        return .send(.workspaces(.element(
                            id: workspace.id,
                            action: .openMarkdownFile(filePath: path, reusePaneID: reuse ? paneID : nil)
                        )))
                    }
                    guard let activeID = state.activeWorkspaceID else { return .none }
                    return .send(.workspaces(.element(
                        id: activeID,
                        action: .openMarkdownFile(filePath: path, reusePaneID: nil)
                    )))

                case .openDiff(let repoPath, let targetPath, let paneID):
                    if let paneID,
                       let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
                        state.workspaces[id: workspace.id]?.setFocus(paneID)
                        return .send(.workspaces(.element(
                            id: workspace.id,
                            action: .openDiffPane(
                                repoPath: repoPath,
                                targetPath: targetPath,
                                reusePaneID: nil
                            )
                        )))
                    }
                    guard let activeID = state.activeWorkspaceID else { return .none }
                    return .send(.workspaces(.element(
                        id: activeID,
                        action: .openDiffPane(
                            repoPath: repoPath,
                            targetPath: targetPath,
                            reusePaneID: nil
                        )
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

                case .paneCapture(let paneID, let target, let workspaceFilter, let lines, let includeScrollback):
                    return handlePaneCapture(
                        state: state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        lines: lines,
                        includeScrollback: includeScrollback,
                        reply: reply
                    )

                case .graftStart(let workspaceFilter, let repoFilter, let paneID):
                    return handleGraftStart(
                        state: state,
                        workspaceFilter: workspaceFilter,
                        repoFilter: repoFilter,
                        paneID: paneID,
                        reply: reply
                    )

                case .graftStop(let workspaceFilter, let repoFilter, let paneID):
                    return handleGraftStop(
                        state: state,
                        workspaceFilter: workspaceFilter,
                        repoFilter: repoFilter,
                        paneID: paneID,
                        reply: reply
                    )

                case .graftStatus:
                    return handleGraftStatus(state: state, reply: reply)

                case .ping:
                    return handlePing(reply: reply)

                case .webOpen(let paneID, let url, let isPrivate):
                    return handleWebOpen(
                        state: state,
                        paneID: paneID,
                        url: url,
                        isPrivate: isPrivate,
                        reply: reply
                    )

                case .webNavigate(let paneID, let target, let workspaceFilter, let url):
                    return handleWebNavigate(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        url: url,
                        reply: reply
                    )

                case .webURL(let paneID, let target, let workspaceFilter):
                    return handleWebURL(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        reply: reply
                    )

                case .webBack(let paneID, let target, let workspaceFilter):
                    return handleWebNav(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        action: .back,
                        reply: reply
                    )

                case .webForward(let paneID, let target, let workspaceFilter):
                    return handleWebNav(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        action: .forward,
                        reply: reply
                    )

                case .webReload(let paneID, let target, let workspaceFilter, let hard):
                    return handleWebNav(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        action: hard ? .reloadHard : .reload,
                        reply: reply
                    )

                case .webCapture(let paneID, let target, let workspaceFilter, let mode):
                    return handleWebCapture(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        mode: mode,
                        reply: reply
                    )

                case .webTabs(let paneID, let target, let workspaceFilter):
                    return handleWebTabs(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        reply: reply
                    )

                case .webTabNew(let paneID, let target, let workspaceFilter, let url, let makeActive):
                    return handleWebTabNew(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        url: url,
                        makeActive: makeActive,
                        reply: reply
                    )

                case .webTabClose(let paneID, let target, let workspaceFilter, let tabRef):
                    return handleWebTabClose(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        tabRef: tabRef,
                        reply: reply
                    )

                case .webTabSelect(let paneID, let target, let workspaceFilter, let tabRef):
                    return handleWebTabSelect(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        tabRef: tabRef,
                        reply: reply
                    )

                case .webConsole(let paneID, let target, let workspaceFilter, let since, let level, let clear):
                    return handleWebConsole(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        since: since,
                        level: level,
                        clear: clear,
                        reply: reply
                    )

                case .webInspect(let paneID, let target, let workspaceFilter, let sendTo, let submit, let disarm):
                    return handleWebInspect(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        sendTo: sendTo,
                        submit: submit,
                        disarm: disarm,
                        reply: reply
                    )

                case .webInspectResult(let paneID, let target, let workspaceFilter, let clear):
                    return handleWebInspectResult(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        clear: clear,
                        reply: reply
                    )

                case .webPrivate(let paneID, let target, let workspaceFilter, let enabled):
                    return handleWebPrivate(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        enabled: enabled,
                        reply: reply
                    )

                case .webCookiesList(let paneID, let target, let workspaceFilter):
                    return handleWebCookiesList(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        reply: reply
                    )

                case .webCookiesClear(let paneID, let target, let workspaceFilter, let domain, let all):
                    return handleWebCookiesClear(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        domain: domain,
                        all: all,
                        reply: reply
                    )

                case .webCookiesDelete(let paneID, let target, let workspaceFilter, let name, let domain):
                    return handleWebCookiesDelete(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        name: name,
                        domain: domain,
                        reply: reply
                    )

                case .webClick(let paneID, let target, let workspaceFilter, let selector, let double, let right, let atX, let atY):
                    return handleWebClick(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        double: double,
                        right: right,
                        atX: atX,
                        atY: atY,
                        reply: reply
                    )

                case .webType(let paneID, let target, let workspaceFilter, let selector, let text, let submit, let replace):
                    return handleWebType(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        text: text,
                        submit: submit,
                        replace: replace,
                        reply: reply
                    )

                case .webQText(let paneID, let target, let workspaceFilter, let selector, let maxBytes):
                    return handleWebQText(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        maxBytes: maxBytes,
                        reply: reply
                    )

                case .webQAttr(let paneID, let target, let workspaceFilter, let selector, let attribute):
                    return handleWebQAttr(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        attribute: attribute,
                        reply: reply
                    )

                case .webQCount(let paneID, let target, let workspaceFilter, let selector):
                    return handleWebQCount(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        reply: reply
                    )

                case .webQExists(let paneID, let target, let workspaceFilter, let selector):
                    return handleWebQExists(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        reply: reply
                    )

                case .webQDom(let paneID, let target, let workspaceFilter, let selector, let maxBytes):
                    return handleWebQDom(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        maxBytes: maxBytes,
                        reply: reply
                    )

                case .webWait(let paneID, let target, let workspaceFilter, let selector, let urlMatch, let forCondition, let timeoutMs):
                    return handleWebWait(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        urlMatch: urlMatch,
                        forCondition: forCondition,
                        timeoutMs: timeoutMs,
                        reply: reply
                    )

                case .webSelect(let paneID, let target, let workspaceFilter, let selector, let valueOrLabel):
                    return handleWebSelect(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        valueOrLabel: valueOrLabel,
                        reply: reply
                    )

                case .webScroll(let paneID, let target, let workspaceFilter, let selector, let block, let behavior):
                    return handleWebScroll(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        block: block,
                        behavior: behavior,
                        reply: reply
                    )

                case .webHover(let paneID, let target, let workspaceFilter, let selector):
                    return handleWebHover(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        reply: reply
                    )

                case .webKey(let paneID, let target, let workspaceFilter, let keyName, let selector):
                    return handleWebKey(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        keyName: keyName,
                        selector: selector,
                        reply: reply
                    )

                case .webExec(let paneID, let target, let workspaceFilter, let script):
                    return handleWebExec(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        script: script,
                        reply: reply
                    )
                }

            // MARK: - Cross-Workspace Surface Notifications

            case .surfaceTitleChanged(let paneID, let title):
                guard let workspace = state.workspaceContainingPane(paneID)
                else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .paneTitleChanged(paneID: paneID, title: title)
                )))

            case .surfaceDirectoryChanged(let paneID, let directory):
                guard let workspace = state.workspaceContainingPane(paneID)
                else { return .none }
                // Refresh any RepoAssociation whose worktree contains the new
                // pwd. Catches `cd ../other-worktree` instantly, before the
                // 30s timer or an unrelated HEAD change would otherwise pick
                // it up.
                let standardizedPwd = (directory as NSString).standardizingPath
                let touched = workspace.repoAssociations.filter { assoc in
                    let root = (assoc.worktreePath as NSString).standardizingPath
                    return standardizedPwd == root || standardizedPwd.hasPrefix(root + "/")
                }
                let workspaceID = workspace.id
                let pwdRefreshes: [Effect<Action>] = touched.map { assoc in
                    Effect.send(.headChanged(workspaceID: workspaceID, associationID: assoc.id))
                }
                return .merge(
                    [
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .paneDirectoryChanged(paneID: paneID, directory: directory)
                        )))
                    ] + pwdRefreshes
                )

            case .surfaceProcessExited(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID)
                else { return .none }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .paneProcessTerminated(paneID: paneID)
                )))

            // MARK: - Desktop Notifications (OSC)

            case .desktopNotification(let paneID, let title, let body):
                // Suppress if this pane is focused and app is active
                if let workspace = state.workspaceContainingPane(paneID),
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
                var removedAssociationIDs: [UUID] = []
                for wsIndex in state.workspaces.indices {
                    removedAssociationIDs.append(contentsOf: state.workspaces[wsIndex].repoAssociations
                        .filter { $0.repoID == id }
                        .map(\.id))
                    state.workspaces[wsIndex].repoAssociations.removeAll(where: { $0.repoID == id })
                }
                for associationID in removedAssociationIDs {
                    state.gitStatuses.removeValue(forKey: associationID)
                }
                let stopEffects = removedAssociationIDs.map {
                    Effect.send(Action.stopHeadWatcher(associationID: $0))
                }
                // Stop any live graft sessions on removed associations.
                // Without this, removing the repo leaves grafts mirroring
                // a worktree whose association is gone.
                let graftStopEffects = removedAssociationIDs
                    .filter { state.graft.sessions[id: $0] != nil }
                    .map { Effect.send(Action.graft(.forceStop($0))) }
                return .merge(stopEffects + graftStopEffects + [.send(.persistState)])

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
                    .send(.refreshGitStatus),
                    .send(.startHeadWatcher(
                        workspaceID: workspaceID,
                        associationID: assoc.id,
                        worktreePath: worktreePath
                    ))
                )

            case .worktreeCreationFailed:
                // UI can observe this for error display
                return .none

            case .removeWorktreeAssociation(let workspaceID, let associationID, let deleteWorktree):
                guard let workspace = state.workspaces[id: workspaceID],
                      let assoc = workspace.repoAssociations[id: associationID],
                      let repo = state.repoRegistry[id: assoc.repoID] else { return .none }

                // Stop any active graft session FIRST. Otherwise the
                // session keeps trying to mirror a worktree that no
                // longer has an association (and, in the
                // `deleteWorktree: true` case, is about to disappear
                // entirely), leaving the parent root mid-mirror and
                // the breadcrumb stranded.
                let needsGraftStop = state.graft.sessions[id: associationID] != nil

                state.workspaces[id: workspaceID]?.repoAssociations.remove(id: associationID)
                state.gitStatuses.removeValue(forKey: associationID)

                // `forceStop` (not `toggleGraft`) because the
                // association is being deleted entirely. `toggleGraft`
                // would retry-start a graft when the existing session
                // is in `.error` state, which is wrong here — the
                // worktree is going away.
                let graftStop: Effect<Action> = needsGraftStop
                    ? .send(.graft(.forceStop(associationID)))
                    : .none

                if deleteWorktree {
                    // graftStop and removeWorktree run in parallel —
                    // safe because graft's stop awaits any in-flight
                    // sync (so no read-tree fires on a half-deleted
                    // worktree) and operates on the PARENT root, not
                    // the worktree dir we're about to remove.
                    return .merge(
                        graftStop,
                        .send(.stopHeadWatcher(associationID: associationID)),
                        .run { _ in
                            try? await gitService.removeWorktree(repo.path, assoc.worktreePath)
                        },
                        .send(.persistState)
                    )
                }
                return .merge(
                    graftStop,
                    .send(.stopHeadWatcher(associationID: associationID)),
                    .send(.persistState)
                )

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
                    effects.append(.send(.startHeadWatcher(
                        workspaceID: workspaceID,
                        associationID: assocID,
                        worktreePath: resolvedWorktree
                    )))
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
                    + workspace.parkedPanes.map(\.workingDirectory)

                func isPathInside(_ path: String, _ root: String) -> Bool {
                    let p = (path as NSString).standardizingPath
                    let r = (root as NSString).standardizingPath
                    if p == r { return true }
                    return p.hasPrefix(r + "/")
                }

                var removedRepoIDs: Set<UUID> = []
                var stoppedAssocIDs: [UUID] = []
                for assocID in candidateIDs {
                    guard let assoc = state.workspaces[id: workspaceID]?
                        .repoAssociations[id: assocID] else { continue }
                    let stillInUse = panePaths.contains { isPathInside($0, assoc.worktreePath) }
                    if !stillInUse {
                        state.workspaces[id: workspaceID]?.repoAssociations.remove(id: assocID)
                        state.gitStatuses.removeValue(forKey: assocID)
                        removedRepoIDs.insert(assoc.repoID)
                        stoppedAssocIDs.append(assocID)
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

                if removedRepoIDs.isEmpty { return .none }
                let stopEffects = stoppedAssocIDs.map { Effect.send(Action.stopHeadWatcher(associationID: $0)) }
                // Stop any live graft sessions for auto-unlinked
                // associations. Otherwise a graft set up against an
                // auto-linked worktree keeps mirroring after the pane
                // moves out of that worktree.
                let graftStopEffects = stoppedAssocIDs
                    .filter { state.graft.sessions[id: $0] != nil }
                    .map { Effect.send(Action.graft(.forceStop($0))) }
                return .merge(stopEffects + graftStopEffects + [.send(.persistState)])

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
                        let branch = try? await gitService.getCurrentBranch(assoc.worktreePath)
                        await send(.repoAssociationBranchResolved(
                            workspaceID: activeID,
                            associationID: assoc.id,
                            branch: branch
                        ))
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

            case .startHeadWatcher(let workspaceID, let associationID, let worktreePath):
                return .run { [gitService, gitHeadWatcher] send in
                    // Resolve the real HEAD path. For a linked worktree this
                    // is `<repo>/.git/worktrees/<name>/HEAD`, not the
                    // worktree's own `.git/HEAD`.
                    guard let headPath = try? await gitService.resolveHeadPath(worktreePath) else {
                        return
                    }
                    let stream = gitHeadWatcher.start(
                        associationID: associationID,
                        headPath: headPath
                    )
                    for await _ in stream {
                        await send(.headChanged(
                            workspaceID: workspaceID,
                            associationID: associationID
                        ))
                    }
                }
                .cancellable(id: HeadWatcherID.association(associationID), cancelInFlight: true)

            case .stopHeadWatcher(let associationID):
                gitHeadWatcher.stop(associationID: associationID)
                return .merge(
                    .cancel(id: HeadWatcherID.association(associationID)),
                    .cancel(id: HeadChangedDebounceID.association(associationID))
                )

            case .headChanged(let workspaceID, let associationID):
                guard let assoc = state.workspaces[id: workspaceID]?
                    .repoAssociations[id: associationID]
                else { return .none }
                let path = assoc.worktreePath
                return .run { [gitService, clock] send in
                    // Coalesce the double-write of `git checkout` (HEAD is
                    // typically rewritten via temp file + atomic rename, so
                    // we see two events back to back). `cancelInFlight: true`
                    // means a second event within the debounce window starts
                    // a fresh sleep.
                    try? await clock.sleep(for: Self.headChangedDebounce)
                    let status = await (try? gitService.getStatus(path)) ?? .unknown
                    let branch = try? await gitService.getCurrentBranch(path)
                    await send(.gitStatusUpdated(associationID: associationID, status: status))
                    await send(.repoAssociationBranchResolved(
                        workspaceID: workspaceID,
                        associationID: associationID,
                        branch: branch
                    ))
                }
                .cancellable(
                    id: HeadChangedDebounceID.association(associationID),
                    cancelInFlight: true
                )

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

            // The in-app SwiftUI surfaces re-read the status colours from the
            // chrome environment automatically, but the AppKit menu-bar icon +
            // popover are pushed their colours imperatively in
            // `updateExternalIndicators` — so re-push when the chrome theme
            // changes, otherwise the menu-bar dot keeps a stale colour until the
            // next agent-status change.
            case .settings(.setChromeAppearance), .settings(.setChromeColor), .settings(.resetChromeColors):
                return .send(.updateExternalIndicators)

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
                let appearance = state.settings.chromeAppearance
                let colorOverrides = state.settings.chromeColorOverrides
                return .run { _ in
                    await MainActor.run {
                        // Resolve the chrome status colours so the menu-bar icon
                        // + popover match the in-app status colours. The menu bar
                        // sits in the OS appearance, so resolve against it.
                        let scheme: ColorScheme = NSApp.effectiveAppearance
                            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
                        let theme = ChromeTheme.resolve(
                            appearance: appearance,
                            system: scheme,
                            overrides: colorOverrides
                        )
                        controller.update(
                            waitingCount: finalWaiting,
                            runningCount: finalRunning,
                            items: finalItems,
                            waitingColor: theme.statusWaiting,
                            runningColor: theme.statusRunning
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

        Scope(state: \.graft, action: \.graft) {
            GraftFeature()
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
