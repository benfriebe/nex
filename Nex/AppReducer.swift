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
        case createWorkspace(name: String, color: WorkspaceColor, repos: [Repo] = [], workingDirectory: String? = nil)
        case deleteWorkspace(UUID)
        case moveWorkspace(id: UUID, toIndex: Int)
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

        /// Socket messages (agent lifecycle + pane/workspace commands)
        case socketMessage(SocketMessage)

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

        // Search
        case ghosttySearchStarted(paneID: UUID, needle: String)
        case ghosttySearchEnded(paneID: UUID)
        case searchTotalUpdated(paneID: UUID, total: Int)
        case searchSelectedUpdated(paneID: UUID, selected: Int)
    }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.persistenceService) var persistenceService
    @Dependency(\.gitService) var gitService
    @Dependency(\.socketServer) var socketServer
    @Dependency(\.notificationService) var notificationService
    @Dependency(\.statusBarController) var statusBarController
    @Dependency(\.ghosttyConfig) var ghosttyConfig
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

            case .createWorkspace(let name, let color, let repos, let workingDirectory):
                var workspace = WorkspaceFeature.State(
                    id: uuid(),
                    name: name,
                    color: color
                )

                // If exactly one repo, start the first pane in that repo's directory
                if repos.count == 1 {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = repos[0].path
                } else if let workingDirectory {
                    workspace.panes[workspace.panes.startIndex].workingDirectory = workingDirectory
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

            case .moveWorkspace(let id, let toIndex):
                guard let fromIndex = state.workspaces.index(id: id),
                      fromIndex != toIndex,
                      toIndex >= 0,
                      toIndex < state.workspaces.count
                else { return .none }
                let workspace = state.workspaces.remove(at: fromIndex)
                state.workspaces.insert(workspace, at: min(toIndex, state.workspaces.endIndex))
                return .send(.persistState)

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
                let opacity = ghosttyConfig.backgroundOpacity
                return .merge(
                    .run { send in
                        for workspace in workspaces {
                            for pane in workspace.panes where pane.type == .shell {
                                await surfaceManager.createSurface(
                                    paneID: pane.id,
                                    workingDirectory: pane.workingDirectory,
                                    backgroundOpacity: opacity
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

            // MARK: - Socket Messages

            case .socketMessage(let message):
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
                                await MainActor.run {
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
                            id: workspace.id, action: .splitPaneAtPath(path, label: name)
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

                case .paneClose(let paneID):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    return .send(.workspaces(.element(id: workspace.id, action: .closePane(paneID))))

                case .paneName(let paneID, let name):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    state.workspaces[id: workspace.id]?.panes[id: paneID]?.label = name
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

                // MARK: Workspace commands

                case .workspaceCreate(let name, let path, let color):
                    return .send(.createWorkspace(
                        name: name ?? "Workspace",
                        color: color ?? .blue,
                        workingDirectory: path
                    ))

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

    /// Resolve a target string (UUID or pane label) to a pane UUID.
    /// Searches by UUID first, then label in the originating pane's workspace,
    /// then label across all workspaces.
    private static func resolveTarget(
        _ target: String?,
        from originPaneID: UUID,
        state: State
    ) -> UUID? {
        guard let target, !target.isEmpty else { return nil }
        if let uuid = UUID(uuidString: target) { return uuid }
        let originWorkspace = state.workspaces.first { $0.panes[id: originPaneID] != nil }
        if let match = originWorkspace?.panes.first(where: { $0.label == target }) {
            return match.id
        }
        return state.workspaces.flatMap(\.panes).first(where: { $0.label == target })?.id
    }
}
