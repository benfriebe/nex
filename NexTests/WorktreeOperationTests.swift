import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct WorktreeOperationTests {
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
                throw GitServiceError.commandFailed(command: "git worktree add", exitCode: 128)
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
