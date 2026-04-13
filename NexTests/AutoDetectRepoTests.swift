import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct AutoDetectRepoTests {
    private func makeState(workspaceID: UUID, paneID: UUID, pwd: String = "/tmp") -> AppReducer.State {
        let pane = Pane(id: paneID, workingDirectory: pwd)
        let ws = WorkspaceFeature.State(
            id: workspaceID, name: "WS", slug: "ws", color: .blue,
            panes: [pane], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )
        var state = AppReducer.State()
        state.workspaces.append(ws)
        state.activeWorkspaceID = workspaceID
        state.settings.autoDetectRepos = true
        return state
    }

    @Test func autoLinkResolvedAddsRepoAndAssociation() async {
        let wsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let paneID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/code/myrepo/sub")

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in "main" }
            $0.gitService.getStatus = { _ in .clean }
            $0.gitService.getRemoteURL = { _ in "git@github.com:user/myrepo.git" }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let info = RepoRootInfo(
            worktreeRoot: "/code/myrepo",
            parentRepoRoot: "/code/myrepo"
        )

        await store.send(.autoLinkResolved(workspaceID: wsID, paneID: paneID, info: info))

        #expect(store.state.repoRegistry.count == 1)
        #expect(store.state.repoRegistry.first?.path == "/code/myrepo")
        #expect(store.state.repoRegistry.first?.isAutoDiscovered == true)

        let assocs = store.state.workspaces[id: wsID]?.repoAssociations ?? []
        #expect(assocs.count == 1)
        #expect(assocs.first?.worktreePath == "/code/myrepo")
        #expect(assocs.first?.isAutoDetected == true)
    }

    @Test func autoLinkResolvedSkipsExistingAssociation() async {
        let wsID = UUID()
        let paneID = UUID()
        let repoID = UUID()
        let assocID = UUID()

        var state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/code/repo")
        state.repoRegistry.append(Repo(id: repoID, path: "/code/repo", name: "repo"))
        state.workspaces[id: wsID]?.repoAssociations.append(
            RepoAssociation(
                id: assocID,
                repoID: repoID,
                worktreePath: "/code/repo",
                isAutoDetected: false
            )
        )

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let info = RepoRootInfo(
            worktreeRoot: "/code/repo",
            parentRepoRoot: "/code/repo"
        )

        await store.send(.autoLinkResolved(workspaceID: wsID, paneID: paneID, info: info))

        let assocs = store.state.workspaces[id: wsID]?.repoAssociations ?? []
        #expect(assocs.count == 1)
        #expect(assocs.first?.isAutoDetected == false)
    }

    @Test func autoLinkResolvedHandlesWorktree() async {
        let wsID = UUID()
        let paneID = UUID()
        let state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/work/feature")

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in "feature" }
            $0.gitService.getStatus = { _ in .clean }
            $0.gitService.getRemoteURL = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let info = RepoRootInfo(
            worktreeRoot: "/work/feature",
            parentRepoRoot: "/code/myrepo"
        )

        await store.send(.autoLinkResolved(workspaceID: wsID, paneID: paneID, info: info))

        #expect(store.state.repoRegistry.first?.path == "/code/myrepo")
        let assoc = store.state.workspaces[id: wsID]?.repoAssociations.first
        #expect(assoc?.worktreePath == "/work/feature")
        #expect(assoc?.isAutoDetected == true)
        #expect(assoc?.repoID == store.state.repoRegistry.first?.id)
    }

    @Test func autoUnlinkRemovesOnlyAutoDetectedWithoutPaneInside() async {
        let wsID = UUID()
        let paneID = UUID()
        let repoA = UUID()
        let repoB = UUID()
        let autoAssoc = UUID()
        let manualAssoc = UUID()

        var state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/elsewhere")
        state.repoRegistry.append(Repo(id: repoA, path: "/code/auto", name: "auto", isAutoDiscovered: true))
        state.repoRegistry.append(Repo(id: repoB, path: "/code/manual", name: "manual"))
        state.workspaces[id: wsID]?.repoAssociations.append(
            RepoAssociation(
                id: autoAssoc,
                repoID: repoA,
                worktreePath: "/code/auto",
                isAutoDetected: true
            )
        )
        state.workspaces[id: wsID]?.repoAssociations.append(
            RepoAssociation(
                id: manualAssoc,
                repoID: repoB,
                worktreePath: "/code/manual",
                isAutoDetected: false
            )
        )

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.autoUnlinkUnusedRepos(workspaceID: wsID))

        let assocs = store.state.workspaces[id: wsID]?.repoAssociations ?? []
        #expect(assocs.count == 1)
        #expect(assocs.first?.id == manualAssoc)
    }

    @Test func autoUnlinkKeepsAutoDetectedWhenPaneStillInside() async {
        let wsID = UUID()
        let paneID = UUID()
        let repoID = UUID()
        let assocID = UUID()

        var state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/code/auto/sub/dir")
        state.repoRegistry.append(Repo(id: repoID, path: "/code/auto", name: "auto"))
        state.workspaces[id: wsID]?.repoAssociations.append(
            RepoAssociation(
                id: assocID,
                repoID: repoID,
                worktreePath: "/code/auto",
                isAutoDetected: true
            )
        )

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.autoUnlinkUnusedRepos(workspaceID: wsID))

        #expect(store.state.workspaces[id: wsID]?.repoAssociations.count == 1)
    }

    @Test func autoLinkRespectsSettingDisabled() async {
        let wsID = UUID()
        let paneID = UUID()

        var state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/code/repo")
        state.settings.autoDetectRepos = false

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.gitService.resolveRepoRoot = { _ in
                Issue.record("resolveRepoRoot should not be called when setting is off")
                return nil
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.autoLinkRepoForPane(
            workspaceID: wsID,
            paneID: paneID,
            directory: "/code/repo"
        ))

        #expect(store.state.repoRegistry.isEmpty)
    }

    // MARK: - Race path guards

    @Test func autoLinkResolvedSkipsWhenPaneLeftTheDirectory() async {
        let wsID = UUID()
        let paneID = UUID()
        // Pane is already outside by the time the async resolution lands.
        let state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/elsewhere")

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let info = RepoRootInfo(
            worktreeRoot: "/code/myrepo",
            parentRepoRoot: "/code/myrepo"
        )

        await store.send(.autoLinkResolved(workspaceID: wsID, paneID: paneID, info: info))

        #expect(store.state.repoRegistry.isEmpty)
        #expect(store.state.workspaces[id: wsID]?.repoAssociations.isEmpty == true)
    }

    @Test func autoLinkResolvedSkipsWhenPaneClosed() async {
        let wsID = UUID()
        let paneID = UUID()
        var state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/code/myrepo")
        // Simulate the pane being closed before the async resolution lands.
        state.workspaces[id: wsID]?.panes.remove(id: paneID)

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let info = RepoRootInfo(
            worktreeRoot: "/code/myrepo",
            parentRepoRoot: "/code/myrepo"
        )

        await store.send(.autoLinkResolved(workspaceID: wsID, paneID: paneID, info: info))

        #expect(store.state.repoRegistry.isEmpty)
        #expect(store.state.workspaces[id: wsID]?.repoAssociations.isEmpty == true)
    }

    @Test func autoLinkResolvedSkipsWhenSettingToggledOffMidFlight() async {
        let wsID = UUID()
        let paneID = UUID()
        var state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/code/myrepo")
        // User turned off the setting during the 500ms debounce.
        state.settings.autoDetectRepos = false

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let info = RepoRootInfo(
            worktreeRoot: "/code/myrepo",
            parentRepoRoot: "/code/myrepo"
        )

        await store.send(.autoLinkResolved(workspaceID: wsID, paneID: paneID, info: info))

        #expect(store.state.repoRegistry.isEmpty)
    }

    // MARK: - Repo registry GC + promotion

    @Test func autoUnlinkGCsAutoDiscoveredRepoWhenLastAssocRemoved() async {
        let wsID = UUID()
        let paneID = UUID()
        let repoID = UUID()
        let assocID = UUID()

        var state = makeState(workspaceID: wsID, paneID: paneID, pwd: "/elsewhere")
        state.repoRegistry.append(
            Repo(id: repoID, path: "/code/auto", name: "auto", isAutoDiscovered: true)
        )
        state.workspaces[id: wsID]?.repoAssociations.append(
            RepoAssociation(
                id: assocID,
                repoID: repoID,
                worktreePath: "/code/auto",
                isAutoDetected: true
            )
        )

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.autoUnlinkUnusedRepos(workspaceID: wsID))

        #expect(store.state.repoRegistry.isEmpty)
    }

    @Test func autoUnlinkKeepsAutoDiscoveredRepoWithManualAssociation() async {
        let wsID1 = UUID()
        let wsID2 = UUID()
        let paneID1 = UUID()
        let paneID2 = UUID()
        let repoID = UUID()
        let autoAssocID = UUID()
        let manualAssocID = UUID()

        var state = makeState(workspaceID: wsID1, paneID: paneID1, pwd: "/elsewhere")
        state.repoRegistry.append(
            Repo(id: repoID, path: "/code/auto", name: "auto", isAutoDiscovered: true)
        )
        state.workspaces[id: wsID1]?.repoAssociations.append(
            RepoAssociation(
                id: autoAssocID,
                repoID: repoID,
                worktreePath: "/code/auto",
                isAutoDetected: true
            )
        )
        // A second workspace has a manual association pointing at the same
        // repo — the GC must leave the registry entry alone.
        let ws2 = WorkspaceFeature.State(
            id: wsID2, name: "WS2", slug: "ws2", color: .red,
            panes: [Pane(id: paneID2)], layout: .leaf(paneID2),
            focusedPaneID: paneID2, createdAt: Date(), lastAccessedAt: Date()
        )
        state.workspaces.append(ws2)
        state.workspaces[id: wsID2]?.repoAssociations.append(
            RepoAssociation(
                id: manualAssocID,
                repoID: repoID,
                worktreePath: "/code/auto",
                isAutoDetected: false
            )
        )

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.autoUnlinkUnusedRepos(workspaceID: wsID1))

        #expect(store.state.repoRegistry.count == 1)
        #expect(store.state.workspaces[id: wsID1]?.repoAssociations.isEmpty == true)
        #expect(store.state.workspaces[id: wsID2]?.repoAssociations.count == 1)
    }

    @Test func addRepoPromotesAutoDiscoveredRepo() async {
        let repoID = UUID()
        var state = AppReducer.State()
        state.repoRegistry.append(
            Repo(id: repoID, path: "/code/repo", name: "repo", isAutoDiscovered: true)
        )

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addRepo(path: "/code/repo", name: "repo"))

        #expect(store.state.repoRegistry[id: repoID]?.isAutoDiscovered == false)
    }

    @Test func worktreeCreatedPromotesAutoDiscoveredRepo() async {
        let wsID = UUID()
        let paneID = UUID()
        let repoID = UUID()
        let assocID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

        var state = makeState(workspaceID: wsID, paneID: paneID)
        state.repoRegistry.append(
            Repo(id: repoID, path: "/code/repo", name: "repo", isAutoDiscovered: true)
        )

        let store = TestStore(initialState: state) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .constant(assocID)
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.worktreeCreated(
            workspaceID: wsID,
            repoID: repoID,
            worktreePath: "/work/feature",
            branchName: "feature"
        ))

        #expect(store.state.repoRegistry[id: repoID]?.isAutoDiscovered == false)
    }
}
