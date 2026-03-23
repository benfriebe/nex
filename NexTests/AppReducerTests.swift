import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct AppReducerTests {
    // MARK: - Helpers

    private func makeStore(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [],
        activeWorkspaceID: UUID? = nil,
        repoRegistry: IdentifiedArrayOf<Repo> = []
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.activeWorkspaceID = activeWorkspaceID
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
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private static let wsID1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let wsID2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private static let paneID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let paneID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private static func makeWorkspace(
        id: UUID,
        name: String,
        color: WorkspaceColor = .blue,
        paneID: UUID? = nil
    ) -> WorkspaceFeature.State {
        let pid = paneID ?? UUID()
        return WorkspaceFeature.State(
            id: id, name: name, slug: name.lowercased(), color: color,
            panes: [Pane(id: pid)], layout: .leaf(pid),
            focusedPaneID: pid, createdAt: Date(), lastAccessedAt: Date()
        )
    }

    // MARK: - createWorkspace

    @Test func createWorkspaceAddsWorkspaceAndActivates() async {
        let store = makeStore()

        await store.send(.createWorkspace(name: "Test", color: .green)) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces.first?.name == "Test")
            #expect(state.workspaces.first?.color == .green)
            #expect(state.activeWorkspaceID == state.workspaces.first?.id)
            #expect(state.isNewWorkspaceSheetPresented == false)
        }
    }

    @Test func createWorkspaceWithSingleRepoSetsWorkingDirectory() async {
        let repo = Repo(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            path: "/Users/test/myrepo",
            name: "myrepo"
        )
        let store = makeStore()

        await store.send(.createWorkspace(name: "Repo WS", color: .blue, repos: [repo])) { state in
            #expect(state.workspaces.count == 1)
            let ws = state.workspaces.first!
            #expect(ws.panes.first?.workingDirectory == "/Users/test/myrepo")
            #expect(ws.repoAssociations.count == 1)
            #expect(ws.repoAssociations.first?.repoID == repo.id)
        }
    }

    // MARK: - deleteWorkspace

    @Test func deleteWorkspaceRemovesAndSelectsNext() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces[id: Self.wsID1] == nil)
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    @Test func deleteWorkspaceLastOneSelectsNil() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "Only", paneID: Self.paneID1)

        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.workspaces.isEmpty)
            #expect(state.activeWorkspaceID == nil)
        }
    }

    // MARK: - setActiveWorkspace

    @Test func setActiveWorkspaceUpdatesID() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.setActiveWorkspace(Self.wsID2)) { state in
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    // MARK: - switchToWorkspaceByIndex

    @Test func switchToWorkspaceByIndexValid() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.switchToWorkspaceByIndex(1))
        await store.receive(.setActiveWorkspace(Self.wsID2)) { state in
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    @Test func switchToWorkspaceByIndexOutOfBounds() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS1")

        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1
        )

        // Out of bounds — should produce no effect
        await store.send(.switchToWorkspaceByIndex(5))
    }

    // MARK: - switchToNextWorkspace / switchToPreviousWorkspace

    @Test func switchToNextWorkspaceCycles() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID2
        )

        // At the end — should wrap to first
        await store.send(.switchToNextWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID1)) { state in
            #expect(state.activeWorkspaceID == Self.wsID1)
        }
    }

    @Test func switchToPreviousWorkspaceCycles() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        // At the beginning — should wrap to last
        await store.send(.switchToPreviousWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID2)) { state in
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    // MARK: - toggleSidebar

    @Test func toggleSidebarFlips() async {
        let store = makeStore()
        #expect(store.state.isSidebarVisible == true)

        await store.send(.toggleSidebar) { state in
            #expect(state.isSidebarVisible == false)
        }

        await store.send(.toggleSidebar) { state in
            #expect(state.isSidebarVisible == true)
        }
    }

    // MARK: - showNewWorkspaceSheet / dismissNewWorkspaceSheet

    @Test func showNewWorkspaceSheet() async {
        let store = makeStore()

        await store.send(.showNewWorkspaceSheet) { state in
            #expect(state.isNewWorkspaceSheetPresented == true)
        }
    }

    @Test func dismissNewWorkspaceSheet() async {
        var appState = AppReducer.State()
        appState.isNewWorkspaceSheetPresented = true

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.dismissNewWorkspaceSheet) { state in
            #expect(state.isNewWorkspaceSheetPresented == false)
        }
    }

    // MARK: - toggleInspector

    @Test func toggleInspectorFlips() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        #expect(store.state.isInspectorVisible == false)

        await store.send(.toggleInspector) { state in
            #expect(state.isInspectorVisible == true)
        }

        await store.send(.toggleInspector) { state in
            #expect(state.isInspectorVisible == false)
        }
    }

    // MARK: - stateLoaded

    @Test func stateLoadedRestoresState() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Loaded1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Loaded2", paneID: Self.paneID2)
        let repo = Repo(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
            path: "/tmp/repo",
            name: "repo"
        )

        let store = makeStore()

        await store.send(.stateLoaded([ws1, ws2], activeWorkspaceID: Self.wsID2, repoRegistry: [repo])) { state in
            #expect(state.workspaces.count == 2)
            #expect(state.activeWorkspaceID == Self.wsID2)
            #expect(state.repoRegistry.count == 1)
            #expect(state.repoRegistry.first?.path == "/tmp/repo")
        }
    }

    @Test func stateLoadedEmptyCreatesDefault() async {
        let store = makeStore()

        await store.send(.stateLoaded([], activeWorkspaceID: nil, repoRegistry: []))

        // Should fire createWorkspace with "Default"
        await store.receive(.createWorkspace(name: "Default", color: .blue)) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces.first?.name == "Default")
        }
    }

    @Test func stateLoadedClearsSessionIDs() async {
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.panes[id: Self.paneID1]?.claudeSessionID = "session-xyz"
        ws.panes[id: Self.paneID1]?.status = .running

        let store = makeStore()

        await store.send(.stateLoaded([ws], activeWorkspaceID: Self.wsID1, repoRegistry: [])) { state in
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.claudeSessionID == nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.status == .idle)
        }
    }

    // MARK: - gitStatusUpdated

    @Test func gitStatusUpdatedStoresStatus() async {
        let assocID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
        let store = makeStore()

        await store.send(.gitStatusUpdated(associationID: assocID, status: .dirty(changedFiles: 3))) { state in
            #expect(state.gitStatuses[assocID] == .dirty(changedFiles: 3))
        }
    }

    // MARK: - refreshGitStatus

    @Test func refreshGitStatusQueriesAssociations() async {
        let assocID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
        let repoID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!

        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.repoAssociations.append(RepoAssociation(
            id: assocID, repoID: repoID, worktreePath: "/tmp/repo"
        ))

        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.refreshGitStatus)

        await store.receive(.gitStatusUpdated(associationID: assocID, status: .clean)) { state in
            #expect(state.gitStatuses[assocID] == .clean)
        }
    }
}
