import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct WorktreeOperationTests {
    // MARK: - Name sanitization (issue #218)

    @Test func sanitizedGitNameReplacesSpacesAndTrims() {
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "my worktree") == "my-worktree")
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "  hello  ") == "hello")
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "a  b   c") == "a-b-c")
    }

    @Test func sanitizedGitNameIsFixedPointOnValidRefs() {
        // Already-valid names must survive unchanged — slashes for
        // namespacing, dots, underscores, hyphens, and case are all preserved.
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "feature/test") == "feature/test")
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "my-tree") == "my-tree")
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "Feature/Foo_1.2") == "Feature/Foo_1.2")
    }

    @Test func sanitizedGitNameNeutralisesUnsafeChars() {
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "a~b^c:d?e*f[g") == "a-b-c-d-e-f-g")
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "foo//bar") == "foo/bar")
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "foo..bar") == "foo.bar")
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "/leading/trailing/") == "leading/trailing")
    }

    @Test func sanitizedGitNameReturnsNilWhenNothingUsable() {
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "") == nil)
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "   ") == nil)
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "!!!") == nil)
        #expect(WorkspaceFeature.State.sanitizedGitName(from: "-/-") == nil)
    }

    @Test func createWorktreeSanitizesUnsafeNameBeforeGit() async {
        let repoID = UUID()
        let wsID = UUID()
        let assocID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))
        initialState.workspaces.append(WorkspaceFeature.State(id: wsID, name: "Dev"))
        initialState.activeWorkspaceID = wsID

        // Capture what actually reaches git — it must be sanitized, never raw.
        let received = LockIsolated<(path: String, branch: String)?>(nil)
        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .constant(assocID)
            $0.gitService.createWorktree = { _, path, branch in
                received.setValue((path, branch))
            }
            $0.gitService.getStatus = { _ in .clean }
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorktree(
            workspaceID: wsID,
            repoID: repoID,
            worktreeName: "my worktree",
            branchName: "my worktree"
        ))

        let basePath = SettingsFeature.State().resolvedWorktreeBasePath(forRepoPath: "/code/repo")
        let expectedPath = "\(basePath)/my-worktree"
        #expect(received.value?.path == expectedPath)
        #expect(received.value?.branch == "my-worktree")

        await store.receive(.worktreeCreated(
            workspaceID: wsID,
            repoID: repoID,
            worktreePath: expectedPath,
            branchName: "my-worktree"
        )) { state in
            #expect(state.workspaces[id: wsID]?.repoAssociations.first?.worktreePath == expectedPath)
            #expect(state.workspaces[id: wsID]?.repoAssociations.first?.branchName == "my-worktree")
        }
    }

    @Test func createWorktreeRejectsUnusableNameWithoutShellingOut() async {
        let repoID = UUID()
        let wsID = UUID()

        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))
        initialState.workspaces.append(WorkspaceFeature.State(id: wsID, name: "Dev"))
        initialState.activeWorkspaceID = wsID

        let gitCalled = LockIsolated(false)
        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.gitService.createWorktree = { _, _, _ in gitCalled.setValue(true) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorktree(
            workspaceID: wsID,
            repoID: repoID,
            worktreeName: "!!!",
            branchName: "!!!"
        ))

        await store.receive(\.worktreeCreationFailed) { state in
            #expect(state.worktreeCreationError != nil)
        }
        #expect(gitCalled.value == false)
    }

    @Test func worktreeCreationFailureSurfacesAndDismisses() async {
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.worktreeCreationFailed(workspaceID: UUID(), error: "boom")) { state in
            state.worktreeCreationError = "boom"
        }
        await store.send(.dismissWorktreeCreationError) { state in
            state.worktreeCreationError = nil
        }
    }

    @Test func createWorktreeSurfacesGitStderrNotOpaqueDescription() async {
        // A residual git failure (path exists, branch checked out elsewhere)
        // must surface git's real diagnostic — not the useless
        // localizedDescription of a non-LocalizedError `GitServiceError`, and
        // not git's leading "Preparing worktree (…)" progress line, which
        // precedes the actual "fatal: …" on stderr and once hid the "already
        // exists" reason from the alert (issue #218).
        let repoID = UUID()
        let wsID = UUID()

        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))
        initialState.workspaces.append(WorkspaceFeature.State(id: wsID, name: "Dev"))
        initialState.activeWorkspaceID = wsID

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.gitService.createWorktree = { _, _, _ in
                // Real `git worktree add -b` failure shape: progress line
                // first, the fatal diagnostic second.
                throw GitServiceError.commandFailed(
                    command: "git worktree add",
                    exitCode: 128,
                    stderr: "Preparing worktree (new branch '2')\n"
                        + "fatal: '/code/repo/../wt/2' already exists"
                )
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorktree(
            workspaceID: wsID,
            repoID: repoID,
            worktreeName: "2",
            branchName: "2"
        ))

        await store.receive(\.worktreeCreationFailed) { state in
            #expect(state.worktreeCreationError == "fatal: '/code/repo/../wt/2' already exists")
        }
    }

    @Test func createWorktreeSuccess() async {
        let repoID = UUID()
        let wsID = UUID()
        let assocID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))

        let ws = WorkspaceFeature.State(id: wsID, name: "Dev")
        initialState.workspaces.append(ws)
        initialState.activeWorkspaceID = wsID

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .constant(assocID)
            $0.gitService.createWorktree = { _, _, _ in }
            $0.gitService.getStatus = { _ in .clean }
            $0.gitService.getCurrentBranch = { _ in nil }
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorktree(workspaceID: wsID, repoID: repoID, worktreeName: "my-tree", branchName: "feature/test"))

        let basePath = SettingsFeature.State()
            .resolvedWorktreeBasePath(forRepoPath: "/code/repo")
        let expectedPath = "\(basePath)/my-tree"
        await store.receive(.worktreeCreated(
            workspaceID: wsID,
            repoID: repoID,
            worktreePath: expectedPath,
            branchName: "feature/test"
        )) { state in
            #expect(state.workspaces[id: wsID]?.repoAssociations.count == 1)
            let assoc = state.workspaces[id: wsID]?.repoAssociations.first
            #expect(assoc?.repoID == repoID)
            #expect(assoc?.worktreePath == expectedPath)
            #expect(assoc?.branchName == "feature/test")
        }
    }

    @Test func createWorktreeFailure() async {
        let repoID = UUID()
        let wsID = UUID()

        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))

        let ws = WorkspaceFeature.State(id: wsID, name: "Dev")
        initialState.workspaces.append(ws)

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.gitService.createWorktree = { _, _, _ in
                throw GitServiceError.commandFailed(command: "git worktree add", exitCode: 128, stderr: nil)
            }
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorktree(workspaceID: wsID, repoID: repoID, worktreeName: "bad-tree", branchName: "bad-branch"))

        await store.receive(.worktreeCreationFailed(workspaceID: wsID, error: "The operation couldn\u{2019}t be completed. (Nex.GitServiceError error 0.)"))
    }

    @Test func removeWorktreeAssociationWithDelete() async {
        let repoID = UUID()
        let wsID = UUID()
        let assocID = UUID()

        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))

        var ws = WorkspaceFeature.State(id: wsID, name: "Dev")
        ws.repoAssociations.append(RepoAssociation(
            id: assocID,
            repoID: repoID,
            worktreePath: "/code/repo/.worktrees/Dev",
            branchName: "feature/test"
        ))
        initialState.workspaces.append(ws)

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.gitService.removeWorktree = { _, _ in }
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.removeWorktreeAssociation(
            workspaceID: wsID,
            associationID: assocID,
            deleteWorktree: true
        )) { state in
            state.workspaces[id: wsID]?.repoAssociations = []
        }
    }

    // MARK: - Inline worktree on new workspace (issue #222)

    @Test func createWorkspaceWithWorktreeOpensFirstPaneInWorktree() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")

        let received = LockIsolated<(path: String, branch: String)?>(nil)
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.createWorktree = { _, path, branch in
                received.setValue((path, branch))
            }
            $0.gitService.getStatus = { _ in .clean }
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorkspaceWithWorktree(
            name: "Feature",
            color: .blue,
            repo: repo,
            worktreeName: "my feature",
            branchName: "my feature",
            updateMain: false
        ))

        let basePath = SettingsFeature.State().resolvedWorktreeBasePath(forRepoPath: "/code/repo")
        let expectedPath = "\(basePath)/my-feature"
        // Names must be sanitized before reaching git.
        #expect(received.value?.path == expectedPath)
        #expect(received.value?.branch == "my-feature")

        await store.receive(\.createWorkspace) { state in
            #expect(state.workspaces.count == 1)
            let ws = state.workspaces.first!
            // First pane opens in the worktree, not the repo root.
            #expect(ws.panes.first?.workingDirectory == expectedPath)
            // The association points at the worktree path + branch.
            #expect(ws.repoAssociations.count == 1)
            #expect(ws.repoAssociations.first?.worktreePath == expectedPath)
            #expect(ws.repoAssociations.first?.branchName == "my-feature")
            #expect(state.worktreeCreationError == nil)
        }
    }

    @Test func createWorkspaceWithWorktreeRejectsUnusableNameWithoutShellingOut() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let gitCalled = LockIsolated(false)
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.gitService.createWorktree = { _, _, _ in gitCalled.setValue(true) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorkspaceWithWorktree(
            name: "Feature",
            color: .blue,
            repo: repo,
            worktreeName: "!!!",
            branchName: "!!!",
            updateMain: false
        )) { state in
            #expect(state.worktreeCreationError != nil)
        }
        // No workspace created, no git shell-out.
        #expect(store.state.workspaces.isEmpty)
        #expect(gitCalled.value == false)
    }

    @Test func createWorkspaceWithWorktreeUpdateMainBranchesOffOrigin() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")

        let fetched = LockIsolated(false)
        let plainCreate = LockIsolated(false)
        let baseRef = LockIsolated<String?>(nil)
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.defaultBranch = { _ in "main" }
            $0.gitService.fetch = { _, _ in fetched.setValue(true) }
            $0.gitService.createWorktreeFromBase = { _, _, _, ref in baseRef.setValue(ref) }
            $0.gitService.createWorktree = { _, _, _ in plainCreate.setValue(true) }
            $0.gitService.getStatus = { _ in .clean }
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorkspaceWithWorktree(
            name: "Feature",
            color: .blue,
            repo: repo,
            worktreeName: "feat",
            branchName: "feat",
            updateMain: true
        ))

        await store.receive(\.createWorkspace)

        #expect(fetched.value == true)
        #expect(baseRef.value == "origin/main")
        // The update-main path must NOT use the plain HEAD-based create.
        #expect(plainCreate.value == false)
    }

    @Test func createWorkspaceWithWorktreeSurfacesGitFailure() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.gitService.createWorktree = { _, _, _ in
                throw GitServiceError.commandFailed(
                    command: "git worktree add",
                    exitCode: 128,
                    stderr: "fatal: '/code/wt/feat' already exists"
                )
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createWorkspaceWithWorktree(
            name: "Feature",
            color: .blue,
            repo: repo,
            worktreeName: "feat",
            branchName: "feat",
            updateMain: false
        ))

        await store.receive(\.worktreeCreationFailed) { state in
            #expect(state.worktreeCreationError == "fatal: '/code/wt/feat' already exists")
        }
        // No workspace created on failure.
        #expect(store.state.workspaces.isEmpty)
    }

    @Test func removeWorktreeAssociationWithoutDelete() async {
        let repoID = UUID()
        let wsID = UUID()
        let assocID = UUID()

        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))

        var ws = WorkspaceFeature.State(id: wsID, name: "Dev")
        ws.repoAssociations.append(RepoAssociation(
            id: assocID,
            repoID: repoID,
            worktreePath: "/code/repo/.worktrees/Dev"
        ))
        initialState.workspaces.append(ws)

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.removeWorktreeAssociation(
            workspaceID: wsID,
            associationID: assocID,
            deleteWorktree: false
        )) { state in
            state.workspaces[id: wsID]?.repoAssociations = []
        }
    }
}
