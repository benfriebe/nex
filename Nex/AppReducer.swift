import AppKit
import ComposableArchitecture
import Foundation
import SwiftUI
import WebKit

/// A resolved worktree the first pane of a new workspace should open in
/// (issue #222). Carries the on-disk worktree path and the branch it was
/// created on, so `.createWorkspace` can point the first pane's working
/// directory there and register a `RepoAssociation` for the worktree
/// (rather than the repo root).
struct WorktreeSeed: Equatable {
    let path: String
    let branchName: String
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
        /// One-shot "scroll this sidebar entry into view" signal, set
        /// whenever an entry is created or a workspace is navigated to
        /// (so it can't be stranded below the fold): every
        /// workspace/group creation path (GUI + socket), plus activation
        /// via `setActiveWorkspace` (⌘1-9, ⌘⇧]/[, sidebar/filter clicks,
        /// the menu-bar popover, notification "Open") and the command
        /// palette. `WorkspaceListView` observes it, scrolls the entry
        /// into the viewport (a no-op when it is already fully visible),
        /// and immediately dispatches `clearSidebarScrollTarget` to
        /// consume it. Transient UI state — never persisted. Not set by
        /// state restore on launch or by delete/move reflow, so those
        /// don't yank the list around.
        var sidebarScrollTarget: SidebarID?
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
        /// Transient (never persisted) message for a failed worktree
        /// creation. The inspector binds an alert to it; cleared via
        /// `.dismissWorktreeCreationError`. See issue #218.
        var worktreeCreationError: String?
        var configHotkey = ConfigHotkeyFeature.State()

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

        /// Phase 7: `nex web console --follow` subscribers, keyed by
        /// pane then by `SocketServer.ReplyHandle.id`. Each handle is
        /// a long-lived reply channel (registered by `handleWebConsole`
        /// when `follow` is set, never closed by the reducer) that a
        /// new console line gets pushed to as it lands — see
        /// `fanOutWebConsoleLine`. Entries are released on client
        /// disconnect (`socketSubscriberDisconnected`) or when the
        /// owning pane closes. Not persisted — a fresh launch has no
        /// live CLI connections to resume anyway.
        var webConsoleSubscribers: [UUID: [UInt64: SocketServer.ReplyHandle]] = [:]

        /// Web favourites + workspace label presets. See `PresetsFeature`.
        var presets = PresetsFeature.State()

        /// One half of the one-time label→preset migration gate (the other,
        /// `presets.didLoadLabelPresets`, lives in `PresetsFeature.State`).
        /// They load concurrently; core's `migrateLabelsToPresets` runs the
        /// back-fill once both are ready.
        var didRestoreWorkspaces = false

        /// Markdown files handed to us by Finder's "Open With" during a
        /// cold launch, before the async persistence load has set
        /// `activeWorkspaceID`. `.openFileAtPath` parks paths here when
        /// no workspace exists yet; `.stateLoaded` drains them via
        /// `.flushPendingFileOpens` once a workspace is live (issue #197).
        /// Transient launch state — deliberately excluded from
        /// `PersistenceSnapshot`.
        var pendingFileOpens: [String] = []

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
                let count = workspace.activeAgentCount
                if count > 0 {
                    agentCount += count
                    workspaceCount += 1
                }
            }
            return ActivitySummary(agentCount: agentCount, workspaceCount: workspaceCount)
        }

        /// Cross-workspace agent counts for the bottom status bar. Reading
        /// this inside a tracked view registers a dependency on `workspaces`,
        /// so the footer re-bodies on any status change (Release-safe when
        /// read from a distinct child view).
        var chromeStatusSummary: ChromeStatusSummary {
            var summary = ChromeStatusSummary()
            for workspace in workspaces {
                for pane in workspace.panes {
                    switch pane.status {
                    case .running: summary.running += 1
                    case .waitingForInput: summary.waiting += 1
                    case .idle:
                        // An attached-but-idle agent session is "inactive"
                        // (a resumable agent that isn't running or waiting).
                        if pane.agentSessionID != nil { summary.inactive += 1 }
                    }
                }
            }
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
        case createWorkspace(name: String, color: WorkspaceColor? = nil, repos: [Repo] = [], workingDirectory: String? = nil, groupID: UUID? = nil, profileName: String? = nil, id: UUID? = nil, worktree: WorktreeSeed? = nil)
        /// Create a workspace whose first pane opens in a freshly-created
        /// git worktree (issue #222). Validates + creates the worktree
        /// (optionally updating the default branch first), then dispatches
        /// `.createWorkspace` with the resolved worktree seed. Failures
        /// surface via `worktreeCreationError` (the sheet stays open).
        case createWorkspaceWithWorktree(name: String, color: WorkspaceColor? = nil, repo: Repo, worktreeName: String, branchName: String, updateMain: Bool = false, groupID: UUID? = nil, profileName: String? = nil, id: UUID? = nil)
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
        case clearSidebarScrollTarget
        case beginRenameActiveWorkspace
        case setRenamingWorkspaceID(UUID?)
        case setRenamingPaneID(UUID?)
        case setPaneStatus(paneID: UUID, status: PaneStatus)
        case toggleWorkspaceSelection(UUID)
        case rangeSelectWorkspace(UUID)
        case clearWorkspaceSelection
        case selectAllWorkspaces
        case setBulkColor(WorkspaceColor)
        case setBulkLabel(label: String, apply: Bool)
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
        // `workspaceID` is optional: the inline new-workspace worktree flow
        // (issue #222) fails before any workspace exists, so it passes nil.
        // The handler only reads the error string.
        case worktreeCreationFailed(workspaceID: UUID?, error: String)
        case dismissWorktreeCreationError
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
        /// Replay markdown files parked in `pendingFileOpens` during a
        /// cold launch, once a workspace is live (issue #197).
        case flushPendingFileOpens
        case openDiffPath(repoPath: String, targetPath: String?, fromPaneID: UUID?)
        /// Open a web pane in the active workspace. `fromPaneID` is the
        /// pane to split off (header button / context menu, issue #206);
        /// nil splits the focused pane. `direction` picks right vs down.
        case openWebPanePath(url: String, fromPaneID: UUID?, direction: PaneLayout.SplitDirection = .horizontal)
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

        /// Web favourites + label presets child reducer. See `PresetsFeature`.
        case presets(PresetsFeature.Action)

        // MARK: - Label preset migration (coordinator)

        /// Back-fill a preset (default colour) for every existing workspace
        /// label that predates the presets feature, so they survive being
        /// unapplied. Runs once both workspaces + presets have loaded. Core
        /// owns the gate (it reads `workspaces` + `didRestoreWorkspaces`) and
        /// passes the collected labels into `PresetsFeature` for the actual
        /// back-fill.
        case migrateLabelsToPresets

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

        /// Config + hotkey child reducer (keybindings, focus-follows-mouse,
        /// TCP port, global hotkey). See `ConfigHotkeyFeature`.
        case configHotkey(ConfigHotkeyFeature.Action)

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
        case restartSocketServer
    }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.persistenceService) var persistenceService
    @Dependency(\.gitService) var gitService
    @Dependency(\.gitHeadWatcher) var gitHeadWatcher
    @Dependency(\.socketServer) var socketServer
    @Dependency(\.notificationService) var notificationService
    @Dependency(\.statusBarController) var statusBarController
    @Dependency(\.ghosttyConfig) var ghosttyConfig
    @Dependency(\.workspaceProfiles) var workspaceProfiles
    @Dependency(\.globalHotkeyService) var globalHotkeyService
    @Dependency(\.graftService) var graftService
    @Dependency(\.webPaneStore) var webPaneStore
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock
    @Dependency(\.userDefaults) var userDefaults

    // MARK: - Socket command helpers

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

    private static func sessionJSON(_ session: GraftSession) -> [String: Any] {
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
        into: String?,
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

        // An explicit destination is a single-target operation — with
        // several associations in scope they'd all race to claim the
        // same destination root and every one but the first would
        // fail with `alreadyActive`. Make the ambiguity a hard error.
        if into != nil, assocs.count > 1 {
            reply?.send([
                "ok": false,
                "error": "--into requires a single association in scope; narrow with --repo"
            ])
            reply?.close()
            return .none
        }

        return .run { [graftService] _ in
            var started: [[String: Any]] = []
            var failedAny = false
            var lastError: String?
            for assoc in assocs {
                do {
                    let session = try await graftService.start(assoc, into)
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
        var assocs: [RepoAssociation] = []
        switch resolveGraftAssociations(
            state: state,
            workspaceFilter: workspaceFilter,
            repoFilter: repoFilter,
            paneID: paneID
        ) {
        case .resolved(let resolved):
            assocs = resolved
        case .failure(let error):
            // A bare repo filter that matches no association is NOT
            // fatal: the session's owning association may have been
            // deleted with its workspace (issue #231), in which case
            // only the service still knows it — the fallback below
            // matches it by path. Everything else (no scope at all,
            // unknown workspace) stays an error.
            guard repoFilter != nil, workspaceFilter == nil else {
                reply?.send(["ok": false, "error": error])
                reply?.close()
                return .none
            }
        }

        let assocIDs = Set(assocs.map(\.id))
        return .run { [graftService] _ in
            // Filter against the SERVICE's live sessions, not the
            // reducer mirror — the two can diverge, and a session the
            // mirror lost track of must still be stoppable from the
            // CLI (issue #231). The empty-targets reply lives inside
            // the effect for the same reason: an empty mirror must
            // not short-circuit ahead of the service check.
            let active = await graftService.activeSessions()
            var targetIDs = active.map(\.id).filter { assocIDs.contains($0) }
            if let repoFilter {
                // Orphan fallback: a session whose association is gone
                // can never resolve via workspaces, but `--repo` can
                // still address it by worktree path, parent repo root,
                // or their last path components (mirroring the
                // association matching in `resolveGraftAssociations`).
                for session in active where !targetIDs.contains(session.id) {
                    let candidates = [
                        session.worktreePath,
                        (session.worktreePath as NSString).lastPathComponent,
                        session.parentRepoRoot,
                        (session.parentRepoRoot as NSString).lastPathComponent
                    ]
                    if candidates.contains(repoFilter)
                        || candidates.contains(Self.standardizedPath(repoFilter)) {
                        targetIDs.append(session.id)
                    }
                }
            }
            if targetIDs.isEmpty {
                reply?.send(["ok": true, "stopped": []])
                reply?.close()
                return
            }
            var stopped: [String] = []
            var failures: [[String: Any]] = []
            for targetID in targetIDs {
                do {
                    try await graftService.stop(targetID)
                    stopped.append(targetID.uuidString)
                } catch {
                    failures.append([
                        "association_id": targetID.uuidString,
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

    /// Expand + canonicalize a user-supplied path argument so it can
    /// be compared against the service's canonicalized session paths.
    /// Mirrors `GraftServiceImpl.canonicalize` (standardize, then
    /// resolve symlinks — e.g. /tmp → /private/tmp) plus tilde
    /// expansion for CLI ergonomics.
    private static func standardizedPath(_ raw: String) -> String {
        (((raw as NSString).expandingTildeInPath as NSString)
            .standardizingPath as NSString)
            .resolvingSymlinksInPath
    }

    func handleGraftStatus(
        state _: State,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        // Report the SERVICE's sessions, not the reducer mirror — the
        // service is the source of truth, and a session the mirror
        // lost track of must still show up here so `alreadyActive`
        // rejections are always explainable via `status` (issue #231).
        .run { [graftService] _ in
            let sessions = await graftService.activeSessions()
            let payload: [String: Any] = [
                "ok": true,
                "sessions": sessions.map(Self.sessionJSON)
            ]
            reply?.send(payload)
            reply?.close()
        }
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
                        await send(.configHotkey(.keybindingsLoaded(bindings)))
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
                        await send(.presets(.favouritesLoaded(FavouritesStorage.decode(json))))
                    },
                    .run { [userDefaults] send in
                        let json = userDefaults.stringForKey(LabelPresetsStorage.defaultsKey)
                        await send(.presets(.labelPresetsLoaded(LabelPresetsStorage.decode(json))))
                    }
                )

            case .createWorkspace(let name, let color, let repos, let workingDirectory, let groupID, let newProfileName, let id, let worktree):
                // A worktree was just created for this workspace, so clear
                // any stale error from a prior failed attempt (issue #222).
                if worktree != nil {
                    state.worktreeCreationError = nil
                }
                let previousActiveID = state.activeWorkspaceID
                let resolvedColor = color ?? state.workspaces.nextRandomColor()
                var workspace = WorkspaceFeature.State(
                    // `id` is pre-minted by the socket create path so its
                    // reply can return the new workspace's id; every other
                    // caller passes nil and gets a fresh uuid here.
                    id: id ?? uuid(),
                    name: name,
                    color: resolvedColor
                )
                if let newProfileName {
                    // Same normalization as `.setProfile`: trim; empty or
                    // the built-in "default" baseline → nil.
                    workspace.profileName = WorkspaceProfilesClient.normalizedAssignment(newProfileName)
                }

                // A worktree seed (issue #222) always carries exactly one
                // source repo — open the first pane in the worktree, not the
                // repo root. Otherwise: a single repo opens in that repo's
                // directory; a bare `workingDirectory` wins when given.
                if let worktree {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = worktree.path
                } else if repos.count == 1 {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = repos[0].path
                } else if let workingDirectory {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = workingDirectory
                }

                // Register repos and add associations. When a worktree seed
                // is present, its single repo's association points at the
                // worktree path + branch (mirrors `.worktreeCreated`).
                for repo in repos {
                    if state.repoRegistry[id: repo.id] == nil {
                        state.repoRegistry.append(repo)
                    }
                    let assoc = RepoAssociation(
                        id: uuid(),
                        repoID: repo.id,
                        worktreePath: worktree?.path ?? repo.path,
                        branchName: worktree?.branchName
                    )
                    workspace.repoAssociations.append(assoc)
                    // A worktree flow promotes the repo out of
                    // auto-discovered status (mirrors `.worktreeCreated`).
                    if worktree != nil {
                        state.repoRegistry[id: repo.id]?.isAutoDiscovered = false
                    }
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
                // Ask the sidebar to scroll the new (now-active) workspace
                // into view once it lays out (issue #187).
                state.sidebarScrollTarget = .workspace(workspace.id)

                // Create the initial surface for the default pane
                let paneID = workspace.panes.first!.id
                let cwd = workspace.panes.first!.workingDirectory
                let opacity = ghosttyConfig.backgroundOpacity
                let workspaceID = workspace.id
                let profileName = workspace.profileName
                let watcherSeeds: [Effect<Action>] = workspace.repoAssociations.map { assoc in
                    Effect.send(.startHeadWatcher(
                        workspaceID: workspaceID,
                        associationID: assoc.id,
                        worktreePath: assoc.worktreePath
                    ))
                }
                // A worktree seed create should refresh the new (now-active)
                // workspace's git status immediately, matching `.worktreeCreated`
                // — otherwise the dirty/ahead badge lags until the 30s timer or
                // a HEAD change (review of #222).
                let gitStatusSeed: [Effect<Action>] = worktree != nil ? [.send(.refreshGitStatus)] : []
                return .merge(
                    [
                        .run { _ in
                            let env = workspaceProfiles.resolveEnv(
                                profileName ?? WorkspaceProfilesClient.defaultProfileName
                            )
                            await surfaceManager.createSurface(paneID: paneID, workingDirectory: cwd, backgroundOpacity: opacity, env: env)
                        },
                        .send(.persistState)
                    ] + watcherSeeds + gitStatusSeed
                )

            case .createWorkspaceWithWorktree(let name, let color, let repo, let worktreeName, let branchName, let updateMain, let groupID, let profileName, let id):
                // Reset any error from a prior failed attempt so a retry
                // starts clean (the sheet observes this string).
                state.worktreeCreationError = nil
                // Sanitize before the raw name reaches the filesystem path or
                // git ref — the same single source of truth the inspector
                // flow uses (issue #218). Invalid input surfaces immediately
                // and keeps the sheet open (no async work dispatched).
                guard let folderName = WorkspaceFeature.State.sanitizedGitName(from: worktreeName) else {
                    state.worktreeCreationError = "\"\(worktreeName)\" isn't a usable worktree name. Use letters, numbers, or - _ / . characters."
                    return .none
                }
                guard let safeBranch = WorkspaceFeature.State.sanitizedGitName(from: branchName) else {
                    state.worktreeCreationError = "\"\(branchName)\" isn't a usable branch name. Use letters, numbers, or - _ / . characters."
                    return .none
                }
                let basePath = state.settings.resolvedWorktreeBasePath(forRepoPath: repo.path)
                let worktreePath = "\(basePath)/\(folderName)"
                let repoPath = repo.path
                return .run { [gitService] send in
                    do {
                        try await performWorktreeAdd(
                            gitService: gitService,
                            repoPath: repoPath,
                            worktreePath: worktreePath,
                            branch: safeBranch,
                            updateMain: updateMain
                        )
                        await send(.createWorkspace(
                            name: name,
                            color: color,
                            repos: [repo],
                            groupID: groupID,
                            profileName: profileName,
                            id: id,
                            worktree: WorktreeSeed(path: worktreePath, branchName: safeBranch)
                        ))
                    } catch {
                        await send(.worktreeCreationFailed(
                            workspaceID: nil,
                            error: worktreeErrorMessage(error)
                        ))
                    }
                }

            case .deleteWorkspace(let id):
                guard let workspace = state.workspaces[id: id] else { return .none }
                let paneIDs = workspace.layout.allPaneIDs
                    + workspace.parkedPanes.map(\.id)
                let assocIDs = workspace.repoAssociations.map(\.id)
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
                // `forceStop` every removed association unconditionally
                // — filtering by the reducer's session mirror used to
                // skip cleanup whenever the mirror had lost track of a
                // live service session (issue #231). Stop is a cheap
                // no-op for associations without one.
                let graftStopEffects = assocIDs.map { Effect.send(Action.graft(.forceStop($0))) }
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
                // Bring the activated workspace into view — a keyboard
                // switch (⌘1-9, ⌘⇧]/[), menu-bar/notification jump, or a
                // click on a partially-clipped row can land on an entry
                // below the fold (issue #187). No-op when already visible.
                state.sidebarScrollTarget = .workspace(id)
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

            case .clearSidebarScrollTarget:
                // The sidebar consumed the one-shot scroll signal.
                state.sidebarScrollTarget = nil
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

            case .setPaneStatus(let paneID, let status):
                // Manual status override from the pane context menu. Resolve the
                // owning workspace (the menu only wires this for shell panes;
                // guard here too so a stray dispatch can't flip a non-shell
                // pane). The child `.setPaneStatus` falls through to the
                // `case .workspaces` catch-all, which already persists, so we
                // only additionally refresh the menu-bar / dock badge here
                // (pushed imperatively in updateExternalIndicators, which the
                // catch-all does not emit). Note: a manual override does not
                // survive a relaunch — `stateLoaded` resets every non-idle
                // status to `.idle` (issue #129).
                guard let workspace = state.workspaceContainingPane(paneID),
                      workspace.pane(id: paneID)?.type == .shell
                else {
                    return .none
                }
                return .merge(
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .setPaneStatus(paneID: paneID, status: status)
                    ))),
                    .send(.updateExternalIndicators)
                )

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

            case .setBulkLabel(let label, let apply):
                let normalized = WorkspaceFeature.normalizeLabel(label)
                guard !normalized.isEmpty else { return .none }
                for id in state.selectedWorkspaceIDs {
                    guard state.workspaces[id: id] != nil else { continue }
                    if apply {
                        if !(state.workspaces[id: id]?.labels.contains(normalized) ?? false) {
                            state.workspaces[id: id]?.labels.append(normalized)
                        }
                    } else {
                        state.workspaces[id: id]?.labels.removeAll { $0 == normalized }
                    }
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
                // Capture association ids BEFORE removal so we can
                // `forceStop` each — unconditionally, since filtering
                // by the reducer's session mirror used to skip live
                // service sessions the mirror lost track of (#231).
                var graftAssocIDs: [UUID] = []
                for id in ids {
                    guard let workspace = state.workspaces[id: id] else { continue }
                    panesToDestroy.append(contentsOf: workspace.layout.allPaneIDs)
                    panesToDestroy.append(contentsOf: workspace.parkedPanes.map(\.id))
                    graftAssocIDs.append(contentsOf: workspace.repoAssociations.map(\.id))
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
                let graftStopEffects = graftAssocIDs.map { Effect.send(Action.graft(.forceStop($0))) }
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
                // Scroll the new group header into view (issue #187).
                state.sidebarScrollTarget = .group(newGroup.id)
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
                    // Capture association ids BEFORE removal so we can
                    // `forceStop` each — unconditionally, since
                    // filtering by the reducer's session mirror used
                    // to skip live service sessions the mirror lost
                    // track of (#231).
                    var graftAssocIDs: [UUID] = []
                    for wsID in childIDs {
                        guard let workspace = state.workspaces[id: wsID] else { continue }
                        paneIDs.append(contentsOf: workspace.layout.allPaneIDs)
                        paneIDs.append(contentsOf: workspace.parkedPanes.map(\.id))
                        graftAssocIDs.append(contentsOf: workspace.repoAssociations.map(\.id))
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
                    let graftStopEffects = graftAssocIDs.map { Effect.send(Action.graft(.forceStop($0))) }
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
                        // Drain any Finder "Open With" files parked during cold
                        // launch. `createWorkspace` sets `activeWorkspaceID`
                        // synchronously and TCA reduces merged `.send`s in order,
                        // so the flush sees a live workspace (issue #197).
                        .send(.flushPendingFileOpens),
                        .send(.graft(.onAppLaunched(parentRepoRoots: []))),
                        // A fresh install has no legacy free-form labels to
                        // migrate. Mark the one-shot label→preset migration done
                        // now so a later launch (workspaces no longer empty)
                        // doesn't run it against the user's *new* labels and
                        // resurrect any preset they deleted in the meantime.
                        .run { _ in userDefaults.setBool(true, LabelPresetsStorage.migratedKey) }
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
                // `agentKind` picks the resume command (`claude --resume` vs
                // `codex resume`, issue #101) and is deliberately NOT
                // cleared below: it's a last-known display value, and the
                // resumable tuples must capture it before any clearing.
                var resumablePanes: [(paneID: UUID, sessionID: String, kind: AgentKind)] = []
                for workspace in workspaces {
                    for pane in workspace.panes {
                        if let sessionID = pane.agentSessionID {
                            resumablePanes.append((
                                paneID: pane.id,
                                sessionID: sessionID,
                                kind: pane.agentKind ?? .claude
                            ))
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
                let shellPanes: [(id: UUID, cwd: String, profile: String?)] = workspaces.flatMap { ws in
                    ws.panes.filter { $0.type == .shell }
                        .map { (id: $0.id, cwd: $0.workingDirectory, profile: ws.profileName) }
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

                // Scan registered repo roots AND every association's
                // worktree path for orphaned breadcrumbs — a graft
                // with an explicit `--into <worktree>` destination
                // leaves its breadcrumb in that worktree's git dir,
                // not the main checkout's.
                let parentRepoRoots = Array(Set(
                    state.repoRegistry.map(\.path)
                        + state.workspaces.flatMap { ws in
                            ws.repoAssociations.map(\.worktreePath)
                        }
                ))
                return .merge(
                    [
                        .run { send in
                            // Resolve each workspace profile once, not per
                            // pane — resolveEnv re-reads the config file.
                            // Restored panes carry their workspace's profile
                            // env so the `claude --resume` below lands in a
                            // PTY that's already on the right account.
                            var envCache: [String: [String: String]] = [:]
                            for pane in shellPanes {
                                let profile = pane.profile
                                    ?? WorkspaceProfilesClient.defaultProfileName
                                let env: [String: String]
                                if let cached = envCache[profile] {
                                    env = cached
                                } else {
                                    env = workspaceProfiles.resolveEnv(profile)
                                    envCache[profile] = env
                                }
                                await surfaceManager.createSurface(
                                    paneID: pane.id,
                                    workingDirectory: pane.cwd,
                                    backgroundOpacity: opacity,
                                    env: env
                                )
                            }

                            // Auto-resume agent sessions after surfaces are ready.
                            // Persist AFTER sending resume commands so session IDs survive
                            // if the app crashes before the resume actually executes.
                            if !panesToResume.isEmpty {
                                try? await clock.sleep(for: .seconds(2))
                                for entry in panesToResume {
                                    // nil = session id failed the shell-safety
                                    // allowlist; skip rather than type it.
                                    guard let command = entry.kind.resumeCommand(sessionID: entry.sessionID)
                                    else { continue }
                                    await surfaceManager.sendCommand(
                                        to: entry.paneID,
                                        command: command
                                    )
                                }
                            }

                            // Now that resume commands have been sent, persist the cleared state
                            await send(.persistState)
                        },
                        .send(.refreshGitStatus),
                        .send(.startGitStatusTimer),
                        .send(.migrateLabelsToPresets),
                        // Drain Finder "Open With" files parked during cold
                        // launch; `activeWorkspaceID` was set just above (#197).
                        .send(.flushPendingFileOpens),
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
                // A closed `.web` pane can't be caught up on later —
                // drop and close any live `nex web console --follow`
                // subscribers rather than leaving their FDs open
                // forever. Keyed off subscriber presence rather than
                // `pane.type` so this doesn't depend on whether the
                // pane is still resolvable at this point in the
                // reduce (see the `webConsoleLineAppended` doc for why
                // that ordering can't be assumed).
                if let subscribers = state.webConsoleSubscribers.removeValue(forKey: paneID) {
                    for (_, handle) in subscribers { handle.close() }
                }
                return .merge(
                    .send(.persistState),
                    scheduleAutoUnlink(workspaceID: wsID, in: state)
                )

            case .workspaces(.element(id: let wsID, action: .webConsoleLineAppended(let paneID))):
                return fanOutWebConsoleLine(state: &state, workspaceID: wsID, paneID: paneID)

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

            // Chrome appearance / colour / theme changes recolour the agent
            // status dots. In-app SwiftUI surfaces re-read them from the chrome
            // environment automatically, but the AppKit menu-bar icon + popover
            // are pushed their colours imperatively in `updateExternalIndicators`
            // — so re-push when the chrome theme changes, otherwise the menu-bar
            // dot keeps a stale colour until the next agent-status change. This
            // MUST sit above the catch-all `case .settings:` below, which would
            // otherwise shadow it (first-match-wins) and return `.none`.
            case .settings(.setChromeAppearance), .settings(.setChromeColor),
                 .settings(.resetChromeColors), .settings(.applyStyleTheme):
                return .send(.updateExternalIndicators)

            case .settings:
                return .none

            case .graft:
                // Handled by the GraftFeature Scope below.
                return .none

            // MARK: - Presets child reducer (web favourites + label presets)

            // Field mutations + persistence live in `PresetsFeature` (wired
            // via the `Scope` below). Core keeps only the migration
            // coordinator: once the presets load, the child signals via
            // `.delegate(.didLoadLabelPresets)`, and core runs the one-time
            // gate (`migrateLabelsToPresets`) which reads `workspaces` +
            // `didRestoreWorkspaces` and passes the collected labels back
            // into the child for the actual back-fill.
            //

            // This specific case MUST sit above the catch-all `case .presets:`
            // below, which would otherwise shadow it (first-match-wins) and
            // return `.none`.
            case .presets(.delegate(.didLoadLabelPresets)):
                return .send(.migrateLabelsToPresets)

            case .presets:
                return .none

            case .migrateLabelsToPresets:
                // Only once both halves have loaded (they load concurrently).
                guard state.didRestoreWorkspaces, state.presets.didLoadLabelPresets else { return .none }
                // One-shot: a back-fill that ran every launch would resurrect a
                // preset the user later deletes (its label can still be applied
                // to a workspace), reverting their delete + custom colour.
                guard !userDefaults.boolForKey(LabelPresetsStorage.migratedKey) else { return .none }
                let markMigrated = Effect<Action>.run { _ in
                    userDefaults.setBool(true, LabelPresetsStorage.migratedKey)
                }
                // Collect the workspace labels (deduped, first-seen order). The
                // dedup against the *existing presets* happens in the child,
                // which owns `labelPresets`.
                var seen = Set<String>()
                var labels: [String] = []
                for workspace in state.workspaces {
                    for label in workspace.labels where !seen.contains(label) {
                        seen.insert(label)
                        labels.append(label)
                    }
                }
                return .merge(markMigrated, .send(.presets(.applyMigratedLabels(labels: labels))))

            // MARK: - Config + Hotkey child reducer

            // Field mutations + per-action persistence live in
            // `ConfigHotkeyFeature` (wired via the `Scope` below). Core
            // keeps only the bootstrap coordinator (`configLoaded`) and the
            // socket-server lifecycle (`restartSocketServer`), which read
            // the child's `tcpPort`.
            case .configHotkey:
                return .none

            // MARK: - General Config

            case .configLoaded(
                let focusFollowsMouse,
                let focusFollowsMouseDelay,
                let themeID,
                let tcpPort,
                let globalHotkey,
                let globalHotkeyHideOnRepress
            ):
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
                        await send(.configHotkey(.globalHotkeyRegistrationFailed(reason: "\(error)")))
                    }
                }
                return .merge(
                    .send(.configHotkey(.applyLoadedConfig(
                        focusFollowsMouse: focusFollowsMouse,
                        focusFollowsMouseDelay: focusFollowsMouseDelay,
                        tcpPort: tcpPort,
                        globalHotkey: globalHotkey,
                        globalHotkeyHideOnRepress: globalHotkeyHideOnRepress
                    ))),
                    themeEffect,
                    hotkeyEffect
                )

            case .restartSocketServer:
                // Tear down and rebind the Unix socket (clears /tmp/nex.sock
                // and any wedged client FDs); bring TCP back if configured.
                // onMessage is a singleton property, so it survives the cycle.
                return .run { [tcpPort = state.configHotkey.tcpPort] _ in
                    socketServer.stop()
                    socketServer.start()
                    if tcpPort > 0 {
                        _ = socketServer.startTCP(port: tcpPort)
                    }
                }

            // MARK: - File Opening

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

            // Actions owned by an extracted reduce-block (e.g. SearchNotify)
            // are handled there; `domain(of:)` is the exhaustive completeness
            // guarantee, so core's switch carries a plain `default`.
            default:
                return .none
            }
        }

        searchNotifyReducer

        webPaneReducer

        repoGitReducer

        socketReducer

        commandPaletteReducer
            .forEach(\.workspaces, action: \.workspaces) {
                WorkspaceFeature()
            }

        Scope(state: \.settings, action: \.settings) {
            SettingsFeature()
        }

        Scope(state: \.graft, action: \.graft) {
            GraftFeature()
        }

        Scope(state: \.configHotkey, action: \.configHotkey) {
            ConfigHotkeyFeature()
        }

        Scope(state: \.presets, action: \.presets) {
            PresetsFeature()
        }
    }

    /// Resolve a workspace target string (UUID, name, or slug) to a workspace UUID.
    static func resolveWorkspace(
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
