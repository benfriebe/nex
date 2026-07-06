import ComposableArchitecture
import Foundation

// MARK: - RepoGit reduce-block

extension AppReducer {
    /// Extracted per-domain reduce-block owning the repo-registry
    /// (scan / add / remove / rename), worktree-operation,
    /// auto-detected repo-association, and inspector + git-status
    /// `Action` cases.
    ///
    /// The guard short-circuits every non-RepoGit action via
    /// `Self.domain(of:)` (the exhaustive partition), so this block
    /// only ever runs the cases below. Case bodies, the auto-link
    /// scheduling helpers, and the cancellation-ID enums are moved
    /// here verbatim from the original `AppReducer.body` switch and
    /// the struct body; dependency access (`gitService`,
    /// `gitHeadWatcher`, `uuid`, `clock`) goes through `self` exactly
    /// as before. The two `.workspaces(.element(...RepoAssociation))`
    /// interceptions and the `scheduleAutoLink` / `scheduleAutoUnlink`
    /// call sites stay in core (they are `.workspaces`-family actions
    /// handled in core's routing switch); the `repoRegistry` /
    /// `gitStatuses` / `isInspectorVisible` state fields also stay on
    /// `AppReducer.State` and are read/written here via `state`.
    var repoGitReducer: some ReducerOf<Self> {
        Reduce { state, action in
            guard Self.domain(of: action) == .repoGit else { return .none }
            switch action {
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
                // Sanitize before the raw name reaches the filesystem path or
                // the git ref — verbatim spaces/unsafe chars otherwise make
                // `git worktree add` fail silently (issue #218). This is the
                // single source of truth; the sheet's live preview shows the
                // same sanitized result. A name that sanitizes to nothing
                // usable surfaces the failure rather than shelling out.
                guard let folderName = WorkspaceFeature.State.sanitizedGitName(from: worktreeName) else {
                    return .send(.worktreeCreationFailed(
                        workspaceID: workspaceID,
                        error: "\"\(worktreeName)\" isn't a usable worktree name. Use letters, numbers, or - _ / . characters."
                    ))
                }
                guard let safeBranch = WorkspaceFeature.State.sanitizedGitName(from: branchName) else {
                    return .send(.worktreeCreationFailed(
                        workspaceID: workspaceID,
                        error: "\"\(branchName)\" isn't a usable branch name. Use letters, numbers, or - _ / . characters."
                    ))
                }
                let basePath = state.settings.resolvedWorktreeBasePath(forRepoPath: repo.path)
                let worktreePath = "\(basePath)/\(folderName)"
                return .run { send in
                    do {
                        try await gitService.createWorktree(repo.path, worktreePath, safeBranch)
                        await send(.worktreeCreated(
                            workspaceID: workspaceID,
                            repoID: repoID,
                            worktreePath: worktreePath,
                            branchName: safeBranch
                        ))
                    } catch {
                        await send(.worktreeCreationFailed(
                            workspaceID: workspaceID,
                            error: worktreeErrorMessage(error)
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

            case .worktreeCreationFailed(_, let error):
                // Surface the failure so it isn't swallowed (issue #218). The
                // inspector binds an alert to this transient error string.
                state.worktreeCreationError = error
                return .none

            case .dismissWorktreeCreationError:
                state.worktreeCreationError = nil
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

            default:
                return .none
            }
        }
    }

    // MARK: - Auto-link scheduling + cancellation IDs

    private enum GitStatusTimerID: Hashable { case timer }
    private enum AutoLinkResolveID: Hashable { case pane(UUID) }
    private enum AutoLinkDebounceID: Hashable { case pane(UUID) }
    private enum AutoUnlinkDebounceID: Hashable { case workspace(UUID) }
    private enum HeadWatcherID: Hashable { case association(UUID) }
    private enum HeadChangedDebounceID: Hashable { case association(UUID) }

    /// Debounce for `headChanged` effects. `git checkout` typically writes
    /// HEAD via temp file + atomic rename, which can fire two events back
    /// to back. Coalesce them so we only run `git status` + branch resolve
    /// once per logical checkout.
    static let headChangedDebounce: Duration = .milliseconds(150)

    /// Coalesce rapid `cd`s before scanning the directory for a repo root.
    static let autoLinkDebounce: Duration = .milliseconds(500)
    /// Wait before tearing down an auto-detected association, in case a pane
    /// briefly leaves a directory and returns.
    static let autoUnlinkDebounce: Duration = .seconds(5)

    func scheduleAutoLink(
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

    func scheduleAutoUnlink(workspaceID: UUID, in state: State) -> Effect<Action> {
        guard state.settings.autoDetectRepos else { return .none }
        return .run { [clock] send in
            try await clock.sleep(for: Self.autoUnlinkDebounce)
            await send(.autoUnlinkUnusedRepos(workspaceID: workspaceID))
        }
        .cancellable(id: AutoUnlinkDebounceID.workspace(workspaceID), cancelInFlight: true)
    }
}

/// Turn a worktree-creation error into a message worth showing the user.
/// `GitServiceError` is not `LocalizedError`, so `localizedDescription`
/// yields the useless "operation couldn't be completed" string and drops the
/// `stderr` git printed. Surfacing the raw stderr instead is what makes the
/// alert actionable — e.g. "fatal: '<path>' already exists" or "is already
/// checked out" — for the residual failures sanitization can't prevent
/// (issue #218). Mirrors `GraftService.describeSyncError`.
func worktreeErrorMessage(_ error: Error) -> String {
    if let git = error as? GitServiceError,
       case .commandFailed(_, _, let stderr) = git,
       let stderr, !stderr.isEmpty {
        return stderr.split(separator: "\n").first.map(String.init) ?? stderr
    }
    return error.localizedDescription
}
