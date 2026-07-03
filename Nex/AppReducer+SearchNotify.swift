import AppKit
import ComposableArchitecture
import Foundation

// MARK: - SearchNotify reduce-block

extension AppReducer {
    /// First extracted per-domain reduce-block. Owns libghostty find
    /// (`ghosttySearch*` / `search*Updated`), the cross-workspace surface
    /// notifications (`surface*`), desktop notifications (`desktopNotification`),
    /// and the two markdown file-open entry points (`openFile` /
    /// `openFileAtPath`). The web-pane file-open verbs stay in `core`.
    ///
    /// The guard short-circuits every non-SearchNotify action via
    /// `Self.domain(of:)` (the exhaustive partition), so this block only
    /// ever runs the cases below. Case bodies are moved here verbatim from
    /// the original `AppReducer.body` switch; dependency access
    /// (`notificationService`) goes through `self` exactly as `body` does.
    var searchNotifyReducer: some ReducerOf<Self> {
        Reduce { state, action in
            guard Self.domain(of: action) == .searchNotify else { return .none }
            switch action {
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

            // MARK: - File Opening (markdown entry points)

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
                // No workspace yet — a Finder "Open With" during cold launch
                // beat the async persistence load. Park the path; `.stateLoaded`
                // drains it via `.flushPendingFileOpens` once a workspace is
                // live, rather than dropping the open (issue #197).
                guard let activeID = state.activeWorkspaceID else {
                    state.pendingFileOpens.append(path)
                    return .none
                }
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

            case .flushPendingFileOpens:
                guard !state.pendingFileOpens.isEmpty else { return .none }
                // Snapshot and clear before re-dispatching. `openMarkdownFile`
                // has no dedup, so leaving the queue populated would let a
                // later `createWorkspace` replay stale paths as phantom panes.
                let queued = state.pendingFileOpens
                state.pendingFileOpens = []
                return .merge(queued.map { .send(.openFileAtPath($0, fromPaneID: nil)) })

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

            default:
                return .none
            }
        }
    }
}
