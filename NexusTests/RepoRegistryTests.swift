import ComposableArchitecture
import Foundation
@testable import Nexus
import Testing

@MainActor
struct RepoRegistryTests {
    @Test func addRepoAppendsToRegistry() async {
        let repoID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .constant(repoID)
            $0.gitService.getRemoteURL = { _ in "https://github.com/user/repo.git" }
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addRepo(path: "/path/to/repo", name: "my-repo"))

        await store.receive(\.repoAdded) { state in
            #expect(state.repoRegistry.count == 1)
            #expect(state.repoRegistry.first?.path == "/path/to/repo")
            #expect(state.repoRegistry.first?.name == "my-repo")
            #expect(state.repoRegistry.first?.remoteURL == "https://github.com/user/repo.git")
        }
    }

    @Test func addRepoDeduplcatesByPath() async {
        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(path: "/existing/repo", name: "existing"))

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addRepo(path: "/existing/repo", name: "duplicate"))
        // No repoAdded action should be received — deduplication
    }

    @Test func removeRepoRemovesFromRegistry() async {
        let repoID = UUID()
        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/repo", name: "repo"))

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.removeRepo(repoID)) { state in
            state.repoRegistry = []
        }
    }

    @Test func removeRepoCascadesAssociations() async {
        let repoID = UUID()
        let assocID = UUID()
        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/repo", name: "repo"))

        let ws = WorkspaceFeature.State(name: "Test")
        initialState.workspaces.append(ws)
        initialState.workspaces[id: ws.id]?.repoAssociations.append(
            RepoAssociation(id: assocID, repoID: repoID, worktreePath: "/repo")
        )

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.removeRepo(repoID)) { state in
            state.repoRegistry = []
            state.workspaces[id: ws.id]?.repoAssociations = []
        }
    }

    @Test func renameRepo() async {
        let repoID = UUID()
        var initialState = AppReducer.State()
        initialState.repoRegistry.append(Repo(id: repoID, path: "/repo", name: "old-name"))

        let store = TestStore(initialState: initialState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.renameRepo(id: repoID, name: "new-name")) { state in
            state.repoRegistry[id: repoID]?.name = "new-name"
        }
    }

    @Test func scanForRepos() async {
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.scanForRepos = { _, _ in
                [
                    ScannedRepo(path: "/code/repo1", name: "repo1"),
                    ScannedRepo(path: "/code/repo2", name: "repo2")
                ]
            }
            $0.gitService.getRemoteURL = { _ in nil }
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.scanForRepos(rootPath: "/code"))
        await store.receive(.scanCompleted([
            ScannedRepo(path: "/code/repo1", name: "repo1"),
            ScannedRepo(path: "/code/repo2", name: "repo2")
        ]))
    }
}
