import AppKit
import ComposableArchitecture
import Foundation

@Reducer
struct AppReducer {
    @ObservableState
    struct State: Equatable {
        var workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = []
        var activeWorkspaceID: UUID?
        var isSidebarVisible: Bool = true
        var isNewWorkspaceSheetPresented: Bool = false
        var settings = SettingsFeature.State()
        var repoRegistry: IdentifiedArrayOf<Repo> = []
        var gitStatuses: [UUID: RepoGitStatus] = [:]
        var isInspectorVisible: Bool = false

        var activeWorkspace: WorkspaceFeature.State? {
            guard let id = activeWorkspaceID else { return nil }
            return workspaces[id: id]
        }
    }

    enum Action: Equatable {
        case appLaunched
        case createWorkspace(name: String, color: WorkspaceColor, repos: [Repo] = [])
        case deleteWorkspace(UUID)
        case setActiveWorkspace(UUID)
        case switchToWorkspaceByIndex(Int)
        case switchToNextWorkspace
        case switchToPreviousWorkspace
        case toggleSidebar
        case showNewWorkspaceSheet
        case dismissNewWorkspaceSheet
        case persistState
        case stateLoaded(
            IdentifiedArrayOf<WorkspaceFeature.State>,
            activeWorkspaceID: UUID?,
            repoRegistry: IdentifiedArrayOf<Repo>
        )
        case workspaces(IdentifiedActionOf<WorkspaceFeature>)
        case settings(SettingsFeature.Action)

        /// Agent Lifecycle (socket events)
        case socketEvent(paneID: UUID, event: AgentEvent)

        // Cross-workspace surface notifications
        case surfaceTitleChanged(paneID: UUID, title: String)
        case surfaceDirectoryChanged(paneID: UUID, directory: String)

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

        // File Opening
        case openFile
        case openFileAtPath(String)

        // Inspector + Git Status
        case toggleInspector
        case refreshGitStatus
        case gitStatusUpdated(associationID: UUID, status: RepoGitStatus)
        case startGitStatusTimer

        /// External indicators (menu bar, dock badge)
        case updateExternalIndicators
    }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.persistenceService) var persistenceService
    @Dependency(\.gitService) var gitService
    @Dependency(\.socketServer) var socketServer
    @Dependency(\.notificationService) var notificationService
    @Dependency(\.statusBarController) var statusBarController
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock

    private enum GitStatusTimerID: Hashable { case timer }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appLaunched:
                return .merge(
                    .run { send in
                        let result = await persistenceService.load()
                        await send(.stateLoaded(
                            result.workspaces,
                            activeWorkspaceID: result.activeWorkspaceID,
                            repoRegistry: result.repoRegistry
                        ))
                    },
                    .send(.settings(.loadSettings))
                )

            case .createWorkspace(let name, let color, let repos):
                var workspace = WorkspaceFeature.State(
                    id: uuid(),
                    name: name,
                    color: color
                )

                // If exactly one repo, start the first pane in that repo's directory
                if repos.count == 1 {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = repos[0].path
                }

                // Add repo associations
                for repo in repos {
                    let assoc = RepoAssociation(
                        id: uuid(),
                        repoID: repo.id,
                        worktreePath: repo.path
                    )
                    workspace.repoAssociations.append(assoc)
                }

                state.workspaces.append(workspace)
                state.activeWorkspaceID = workspace.id
                state.isNewWorkspaceSheetPresented = false

                // Create the initial surface for the default pane
                let paneID = workspace.panes.first!.id
                let cwd = workspace.panes.first!.workingDirectory
                return .merge(
                    .run { _ in
                        await surfaceManager.createSurface(paneID: paneID, workingDirectory: cwd)
                    },
                    .send(.persistState)
                )

            case .deleteWorkspace(let id):
                guard let workspace = state.workspaces[id: id] else { return .none }
                let paneIDs = workspace.layout.allPaneIDs
                state.workspaces.remove(id: id)

                if state.activeWorkspaceID == id {
                    state.activeWorkspaceID = state.workspaces.first?.id
                }

                return .merge(
                    .run { _ in
                        for paneID in paneIDs {
                            await surfaceManager.destroySurface(paneID: paneID)
                        }
                    },
                    .send(.persistState)
                )

            case .setActiveWorkspace(let id):
                state.activeWorkspaceID = id
                state.workspaces[id: id]?.lastAccessedAt = Date()
                return .merge(
                    .send(.persistState),
                    .send(.refreshGitStatus)
                )

            case .switchToWorkspaceByIndex(let index):
                guard index >= 0, index < state.workspaces.count else { return .none }
                let workspace = state.workspaces[state.workspaces.index(state.workspaces.startIndex, offsetBy: index)]
                return .send(.setActiveWorkspace(workspace.id))

            case .switchToNextWorkspace:
                guard let current = state.activeWorkspaceID,
                      let currentIndex = state.workspaces.index(id: current) else { return .none }
                let nextIndex = (currentIndex + 1) % state.workspaces.count
                let next = state.workspaces[state.workspaces.index(state.workspaces.startIndex, offsetBy: nextIndex)]
                return .send(.setActiveWorkspace(next.id))

            case .switchToPreviousWorkspace:
                guard let current = state.activeWorkspaceID,
                      let currentIndex = state.workspaces.index(id: current) else { return .none }
                let prevIndex = (currentIndex - 1 + state.workspaces.count) % state.workspaces.count
                let prev = state.workspaces[state.workspaces.index(state.workspaces.startIndex, offsetBy: prevIndex)]
                return .send(.setActiveWorkspace(prev.id))

            case .toggleSidebar:
                state.isSidebarVisible.toggle()
                return .none

            case .showNewWorkspaceSheet:
                state.isNewWorkspaceSheetPresented = true
                return .none

            case .dismissNewWorkspaceSheet:
                state.isNewWorkspaceSheetPresented = false
                return .none

            case .persistState:
                let workspaces = state.workspaces
                let activeID = state.activeWorkspaceID
                let repos = state.repoRegistry
                return .run { _ in
                    await persistenceService.save(
                        workspaces: workspaces,
                        activeWorkspaceID: activeID,
                        repoRegistry: repos
                    )
                }

            case .stateLoaded(let workspaces, let activeID, let repoRegistry):
                if workspaces.isEmpty {
                    // First launch — create a default workspace
                    return .send(.createWorkspace(name: "Default", color: .blue))
                }
                state.workspaces = workspaces
                state.activeWorkspaceID = activeID ?? workspaces.first?.id
                state.repoRegistry = repoRegistry

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
                return .merge(
                    .run { send in
                        for workspace in workspaces {
                            for pane in workspace.panes where pane.type == .shell {
                                await surfaceManager.createSurface(
                                    paneID: pane.id,
                                    workingDirectory: pane.workingDirectory
                                )
                            }
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

            case .workspaces(.element(_, action: .agentStatusChanged)):
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

            case .workspaces:
                // Child workspace actions — persist after mutations
                return .send(.persistState)

            case .settings:
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
                        await send(.openFileAtPath(path))
                    }
                }

            case .openFileAtPath(let path):
                guard let activeID = state.activeWorkspaceID else { return .none }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .openMarkdownFile(filePath: path)
                )))

            // MARK: - Agent Lifecycle

            case .socketEvent(let paneID, let event):
                // Route to the workspace that owns this pane
                guard let workspace = state.workspaces.first(where: { ws in
                    ws.panes[id: paneID] != nil
                }) else { return .none }

                // If we get a "start" while already running, the previous "stop"
                // was missed (e.g. user interrupted Claude). Reset to idle first
                // so the status lifecycle stays clean.
                if case .started = event,
                   workspace.panes[id: paneID]?.status == .running {
                    state.workspaces[id: workspace.id]?.panes[id: paneID]?.status = .idle
                }

                // Fire desktop notification for agent events (unless pane is focused)
                let isFocused = state.activeWorkspaceID == workspace.id
                    && workspace.focusedPaneID == paneID
                let notifService = notificationService
                let wsID = workspace.id
                var effects: [Effect<Action>] = [
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .agentStatusChanged(paneID: paneID, event: event)
                    ))),
                    .send(.updateExternalIndicators)
                ]
                let isAppActive = MainActor.assumeIsolated { NSApp.isActive }
                switch event {
                case .stopped:
                    let shouldNotify = !isFocused || !isAppActive
                    let shouldBounce = !isAppActive
                    let title = workspace.panes[id: paneID]?.title ?? workspace.name
                    effects.append(.run { _ in
                        if shouldNotify {
                            notifService.post(
                                title: title,
                                body: "Agent is waiting for input",
                                paneID: paneID,
                                workspaceID: wsID
                            )
                        }
                        if shouldBounce {
                            await MainActor.run {
                                NSApp.requestUserAttention(.informationalRequest)
                            }
                        }
                    })
                case .error(let message):
                    effects.append(.run { _ in
                        notifService.post(
                            title: "Agent Error",
                            body: message,
                            paneID: paneID,
                            workspaceID: wsID
                        )
                    })
                case .notification(let title, let body):
                    if !isFocused || !MainActor.assumeIsolated({ NSApp.isActive }) {
                        effects.append(.run { _ in
                            notifService.post(title: title, body: body, paneID: paneID, workspaceID: wsID)
                        })
                    }
                case .started:
                    break
                case .sessionStarted:
                    break
                }
                return .merge(effects)

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
                // Deduplicate by path
                guard !state.repoRegistry.contains(where: { $0.path == path }) else {
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
                      let workspace = state.workspaces[id: workspaceID] else { return .none }
                let basePath = state.settings.resolvedWorktreeBasePath
                let worktreePath = "\(basePath)/\(workspace.slug)/\(worktreeName)"
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
}
