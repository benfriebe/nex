import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Coverage for the socket / CLI inline-worktree workspace-create path
/// (issue #222): wire decoding of the new fields plus the reducer dispatch
/// through `handleSocketWorkspaceCreate`, which independently re-implements
/// the sanitize → find-or-mint-repo → seed logic.
@MainActor
struct WorkspaceCreateWorktreeSocketTests {
    private func makeAppStore(
        repoRegistry: IdentifiedArrayOf<Repo> = [],
        configure: (@Sendable (inout DependencyValues) -> Void)? = nil
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.repoRegistry = repoRegistry

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
            configure?(&$0)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func jsonData(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Wire decoding

    @Test func parseWorkspaceCreateWithWorktreeFields() {
        let data = jsonData("""
        {"command":"workspace-create","name":"W","worktree":"feat","branch":"feature/x","update_main":true,"repo":"/code/repo"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceCreate(
            name: "W", path: nil, color: nil, group: nil, profile: nil,
            worktree: "feat", branch: "feature/x", updateMain: true, repo: "/code/repo"
        ))
    }

    @Test func parseWorkspaceCreateWorktreeEmptyBranchNormalisesToNil() {
        let data = jsonData("""
        {"command":"workspace-create","name":"W","worktree":"feat","branch":"","repo":"/code/repo"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceCreate(
            name: "W", path: nil, color: nil, group: nil, profile: nil,
            worktree: "feat", branch: nil, updateMain: false, repo: "/code/repo"
        ))
    }

    @Test func parseWorkspaceCreateNoWorktreeDefaultsFieldsOff() {
        let data = jsonData("""
        {"command":"workspace-create","name":"W"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceCreate(
            name: "W", path: nil, color: nil, group: nil, profile: nil,
            worktree: nil, branch: nil, updateMain: false, repo: nil
        ))
    }

    // MARK: - Reducer dispatch

    @Test func socketWorktreeCreateOpensPaneInWorktree() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let received = LockIsolated<(path: String, branch: String)?>(nil)
        let store = makeAppStore(repoRegistry: [repo]) {
            $0.gitService.createWorktree = { _, path, branch in received.setValue((path, branch)) }
        }

        await store.send(.socketMessage(.workspaceCreate(
            name: "Feature", path: nil, color: nil, group: nil, profile: nil,
            worktree: "my feature", branch: "my feature", updateMain: false, repo: "/code/repo"
        ), reply: nil))

        let basePath = SettingsFeature.State().resolvedWorktreeBasePath(forRepoPath: "/code/repo")
        let expectedPath = "\(basePath)/my-feature"
        #expect(received.value?.path == expectedPath)
        #expect(received.value?.branch == "my-feature")

        await store.receive(\.createWorkspace) { state in
            #expect(state.workspaces.count == 1)
            let ws = state.workspaces.first!
            #expect(ws.panes.first?.workingDirectory == expectedPath)
            #expect(ws.repoAssociations.first?.worktreePath == expectedPath)
            #expect(ws.repoAssociations.first?.branchName == "my-feature")
        }
    }

    @Test func socketWorktreeBranchDefaultsToWorktreeName() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let received = LockIsolated<String?>(nil)
        let store = makeAppStore(repoRegistry: [repo]) {
            $0.gitService.createWorktree = { _, _, branch in received.setValue(branch) }
        }

        // No branch supplied → defaults to the (sanitized) worktree name.
        await store.send(.socketMessage(.workspaceCreate(
            name: "Feature", path: nil, color: nil, group: nil, profile: nil,
            worktree: "feat", branch: nil, updateMain: false, repo: "/code/repo"
        ), reply: nil))

        #expect(received.value == "feat")
        await store.receive(\.createWorkspace)
    }

    @Test func socketWorktreeUpdateMainBranchesOffOrigin() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let fetched = LockIsolated(false)
        let plainCreate = LockIsolated(false)
        let baseRef = LockIsolated<String?>(nil)
        let store = makeAppStore(repoRegistry: [repo]) {
            $0.gitService.defaultBranch = { _ in "develop" }
            $0.gitService.fetch = { _, _ in fetched.setValue(true) }
            $0.gitService.createWorktreeFromBase = { _, _, _, ref in baseRef.setValue(ref) }
            $0.gitService.createWorktree = { _, _, _ in plainCreate.setValue(true) }
        }

        await store.send(.socketMessage(.workspaceCreate(
            name: "Feature", path: nil, color: nil, group: nil, profile: nil,
            worktree: "feat", branch: "feat", updateMain: true, repo: "/code/repo"
        ), reply: nil))

        await store.receive(\.createWorkspace)
        #expect(fetched.value == true)
        #expect(baseRef.value == "origin/develop")
        #expect(plainCreate.value == false)
    }

    @Test func socketWorktreeMintsRepoWhenNotRegistered() async {
        // No repo in the registry — the handler mints one from the source path.
        let store = makeAppStore {
            $0.gitService.createWorktree = { _, _, _ in }
        }

        await store.send(.socketMessage(.workspaceCreate(
            name: "Feature", path: nil, color: nil, group: nil, profile: nil,
            worktree: "feat", branch: "feat", updateMain: false, repo: "/code/newrepo"
        ), reply: nil))

        await store.receive(\.createWorkspace) { state in
            #expect(state.repoRegistry.contains(where: { $0.path == "/code/newrepo" }))
            #expect(state.workspaces.first?.repoAssociations.first?.branchName == "feat")
        }
    }

    @Test func socketWorktreeWithExistingGroupPlacesWorkspaceInGroup() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let groupID = UUID()
        var appState = AppReducer.State()
        appState.repoRegistry = [repo]
        appState.groups = [WorkspaceGroup(id: groupID, name: "grp")]
        appState.topLevelOrder = [.group(groupID)]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.gitService.createWorktree = { _, _, _ in }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // --worktree composes with an EXISTING group (mirrors the GUI).
        await store.send(.socketMessage(.workspaceCreate(
            name: "Feature", path: nil, color: nil, group: "grp", profile: nil,
            worktree: "feat", branch: "feat", updateMain: false, repo: "/code/repo"
        ), reply: nil))

        await store.receive(\.createWorkspace) { state in
            let ws = state.workspaces.first!
            #expect(state.groups[id: groupID]?.childOrder.contains(ws.id) == true)
            #expect(ws.repoAssociations.first?.branchName == "feat")
        }
    }

    @Test func socketWorktreeWithUnknownGroupIsRejected() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let gitCalled = LockIsolated(false)
        let store = makeAppStore(repoRegistry: [repo]) {
            $0.gitService.createWorktree = { _, _, _ in gitCalled.setValue(true) }
        }

        // An unknown group name is rejected — the worktree path does not
        // create groups. No workspace, no git shell-out.
        await store.send(.socketMessage(.workspaceCreate(
            name: "Feature", path: nil, color: nil, group: "nope", profile: nil,
            worktree: "feat", branch: "feat", updateMain: false, repo: "/code/repo"
        ), reply: nil))
        await store.finish()

        #expect(store.state.workspaces.isEmpty)
        #expect(gitCalled.value == false)
    }

    @Test func socketWorktreeGitFailureCreatesNoWorkspace() async {
        let repo = Repo(id: UUID(), path: "/code/repo", name: "repo")
        let store = makeAppStore(repoRegistry: [repo]) {
            $0.gitService.createWorktree = { _, _, _ in
                throw GitServiceError.commandFailed(command: "git worktree add", exitCode: 128, stderr: "fatal: boom")
            }
        }

        await store.send(.socketMessage(.workspaceCreate(
            name: "Feature", path: nil, color: nil, group: nil, profile: nil,
            worktree: "feat", branch: "feat", updateMain: false, repo: "/code/repo"
        ), reply: nil))
        await store.finish()

        // Failure short-circuits before `.createWorkspace` — no workspace.
        #expect(store.state.workspaces.isEmpty)
    }
}
