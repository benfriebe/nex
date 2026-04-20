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
        // Mirror the backfill the reducer applies on load: when no
        // groups are in play, `topLevelOrder` is the workspaces list.
        // Without this, `visibleWorkspaceOrder` (used by range-select,
        // Cmd+N numbering, etc.) is empty in tests constructed
        // directly from state.
        appState.topLevelOrder = workspaces.map { .workspace($0.id) }

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
        paneID: UUID? = nil,
        lastAccessedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> WorkspaceFeature.State {
        let pid = paneID ?? UUID()
        return WorkspaceFeature.State(
            id: id, name: name, slug: name.lowercased(), color: color,
            panes: [Pane(id: pid)], layout: .leaf(pid),
            focusedPaneID: pid, createdAt: Date(), lastAccessedAt: lastAccessedAt
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

    @Test func createWorkspaceWithoutColorPicksNonRepeatingColor() async {
        // Seed with an existing workspace whose color is red, then create a new
        // workspace without specifying a color. The reducer should resolve the
        // default via nextRandomColor(), which must not return red.
        let existing = Self.makeWorkspace(id: Self.wsID1, name: "Existing", color: .red, paneID: Self.paneID1)
        let store = makeStore(workspaces: [existing], activeWorkspaceID: Self.wsID1)

        await store.send(.createWorkspace(name: "New"))

        #expect(store.state.workspaces.count == 2)
        let newColor = store.state.workspaces.last?.color
        #expect(newColor != nil)
        #expect(newColor != .red)
        #expect(WorkspaceColor.allCases.contains(newColor!))
    }

    @Test func createWorkspaceWithSingleRepoSetsWorkingDirectory() async {
        let repo = Repo(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            path: "/Users/test/myrepo",
            name: "myrepo"
        )
        let store = makeStore()

        await store.send(.createWorkspace(name: "Repo WS", color: .blue, repos: [repo])) { state in
            state.repoRegistry.append(repo)
            #expect(state.workspaces.count == 1)
            let ws = state.workspaces.first!
            #expect(ws.panes.first?.workingDirectory == "/Users/test/myrepo")
            #expect(ws.repoAssociations.count == 1)
            #expect(ws.repoAssociations.first?.repoID == repo.id)
        }
    }

    // MARK: - deleteWorkspace

    @Test func deleteActiveWorkspaceFocusesMostRecentlyUsed() async {
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "WS1", paneID: Self.paneID1,
            lastAccessedAt: Date(timeIntervalSince1970: 2000)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "WS2", paneID: Self.paneID2,
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )

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

    @Test func deleteActiveWorkspacePrefersMiddleIfMostRecent() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        // Order in list: ws1, ws2, ws3. But ws2 was the most recently focused
        // non-active workspace — history should pick it over ws1 or ws3.
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "WS1", paneID: Self.paneID1,
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "WS2", paneID: Self.paneID2,
            lastAccessedAt: Date(timeIntervalSince1970: 3000)
        )
        let ws3 = Self.makeWorkspace(
            id: wsID3, name: "WS3", paneID: UUID(),
            lastAccessedAt: Date(timeIntervalSince1970: 5000)
        )

        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            activeWorkspaceID: wsID3
        )

        await store.send(.deleteWorkspace(wsID3)) { state in
            #expect(state.workspaces.count == 2)
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

    /// Regression: once `state.workspaces` insertion order diverges
    /// from the sidebar walk order (e.g. after a bulk top-level drag
    /// that only touches `topLevelOrder`), Cmd+N and next/previous
    /// should still activate the workspace the user sees at that
    /// position — not the stale insertion-order entry.
    @Test func switchActionsFollowSidebarOrderNotInsertionOrder() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        // Insertion order is [ws1, ws2] but the sidebar shows [ws2, ws1]
        // (topLevelOrder reversed), mirroring what a bulk drag via
        // `.moveWorkspacesToGroup` would leave behind.
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.topLevelOrder = [.workspace(Self.wsID2), .workspace(Self.wsID1)]
        appState.activeWorkspaceID = Self.wsID2
        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // Cmd+1 should land on ws2 (first in the visible sidebar),
        // not ws1 (first in insertion order).
        await store.send(.switchToWorkspaceByIndex(0))
        await store.receive(.setActiveWorkspace(Self.wsID2))

        // Next from ws2 (visible index 0) should be ws1 (visible idx 1).
        await store.send(.switchToNextWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID1))

        // Previous from ws1 (visible index 1) should wrap back to ws2.
        await store.send(.switchToPreviousWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID2))
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

    // MARK: - beginRenameActiveWorkspace / setRenamingWorkspaceID

    @Test func beginRenameActiveWorkspaceSetsID() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.beginRenameActiveWorkspace) { state in
            state.renamingWorkspaceID = Self.wsID1
        }
    }

    @Test func beginRenameActiveWorkspaceWithNoActiveIsNoOp() async {
        let store = makeStore()

        await store.send(.beginRenameActiveWorkspace) { state in
            #expect(state.renamingWorkspaceID == nil)
        }
    }

    @Test func deleteWorkspaceClearsPendingRename() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.renamingWorkspaceID = Self.wsID1

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

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.renamingWorkspaceID == nil)
        }
    }

    @Test func deleteOtherWorkspacePreservesPendingRename() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.renamingWorkspaceID = Self.wsID1

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

        await store.send(.deleteWorkspace(Self.wsID2)) { state in
            #expect(state.renamingWorkspaceID == Self.wsID1)
        }
    }

    @Test func setRenamingWorkspaceIDClears() async {
        var appState = AppReducer.State()
        appState.renamingWorkspaceID = Self.wsID1

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

        await store.send(.setRenamingWorkspaceID(nil)) { state in
            state.renamingWorkspaceID = nil
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

        await store.send(.stateLoaded(
            [ws1, ws2],
            groups: [],
            topLevelOrder: [],
            activeWorkspaceID: Self.wsID2,
            repoRegistry: [repo]
        )) { state in
            #expect(state.workspaces.count == 2)
            #expect(state.activeWorkspaceID == Self.wsID2)
            #expect(state.repoRegistry.count == 1)
            #expect(state.repoRegistry.first?.path == "/tmp/repo")
            // Empty topLevelOrder is backfilled from the flat workspaces list
            #expect(state.topLevelOrder == [.workspace(Self.wsID1), .workspace(Self.wsID2)])
            #expect(state.groups.isEmpty)
        }
    }

    @Test func stateLoadedEmptyCreatesDefault() async {
        let store = makeStore()

        await store.send(.stateLoaded([], groups: [], topLevelOrder: [], activeWorkspaceID: nil, repoRegistry: []))

        // Should fire createWorkspace with "Default" and a random color
        await store.receive(\.createWorkspace) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces.first?.name == "Default")
        }
    }

    @Test func stateLoadedClearsSessionIDs() async {
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.panes[id: Self.paneID1]?.claudeSessionID = "session-xyz"
        ws.panes[id: Self.paneID1]?.status = .running

        let store = makeStore()

        await store.send(.stateLoaded(
            [ws],
            groups: [],
            topLevelOrder: [],
            activeWorkspaceID: Self.wsID1,
            repoRegistry: []
        )) { state in
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.claudeSessionID == nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.status == .idle)
        }
    }

    @Test func stateLoadedHonoursPersistedTopLevelOrder() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B", paneID: Self.paneID2)
        let groupID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let group = WorkspaceGroup(
            id: groupID,
            name: "Monitors",
            isCollapsed: false,
            childOrder: [Self.wsID2]
        )
        let order: [SidebarID] = [.workspace(Self.wsID1), .group(groupID)]

        let store = makeStore()

        await store.send(.stateLoaded(
            [ws1, ws2],
            groups: [group],
            topLevelOrder: order,
            activeWorkspaceID: Self.wsID1,
            repoRegistry: []
        )) { state in
            #expect(state.topLevelOrder == order)
            #expect(state.groups.count == 1)
            #expect(state.groups[id: groupID]?.childOrder == [Self.wsID2])
            #expect(state.groupID(forWorkspace: Self.wsID2) == groupID)
            #expect(state.groupID(forWorkspace: Self.wsID1) == nil)
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

    // MARK: - paneMoveToWorkspace

    @Test func movePaneToWorkspaceByName() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Target", paneID: Self.paneID2)

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Target", create: false
        ), reply: nil)) { state in
            // Source workspace has no panes
            #expect(state.workspaces[id: Self.wsID1]?.panes.count == 0)
            #expect(state.workspaces[id: Self.wsID1]?.layout.isEmpty == true)
            #expect(state.workspaces[id: Self.wsID1]?.focusedPaneID == nil)

            // Target workspace has both panes
            #expect(state.workspaces[id: Self.wsID2]?.panes.count == 2)
            #expect(state.workspaces[id: Self.wsID2]?.panes[id: Self.paneID1] != nil)
            #expect(state.workspaces[id: Self.wsID2]?.focusedPaneID == Self.paneID1)

            // Active workspace switched
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    @Test func movePaneToWorkspaceWithCreate() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)

        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "NewWS", create: true
        ), reply: nil)) { state in
            // New workspace was created
            #expect(state.workspaces.count == 2)
            let newWS = state.workspaces.first(where: { $0.name == "NewWS" })
            #expect(newWS != nil)
            #expect(newWS?.panes[id: Self.paneID1] != nil)
            #expect(newWS?.layout == .leaf(Self.paneID1))
            #expect(newWS?.focusedPaneID == Self.paneID1)

            // Source is empty
            #expect(state.workspaces[id: Self.wsID1]?.panes.count == 0)
        }
    }

    @Test func movePaneToWorkspaceNotFoundWithoutCreate() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)

        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "NonExistent", create: false
        ), reply: nil))
        // No state change — pane stays in source
    }

    @Test func movePaneToSameWorkspaceNoOp() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)

        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Source", create: false
        ), reply: nil))
        // No state change — same workspace
    }

    @Test func moveLastPaneLeavesSourceEmpty() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Target", paneID: Self.paneID2)

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Target", create: false
        ), reply: nil)) { state in
            // Source workspace still exists but is empty
            #expect(state.workspaces[id: Self.wsID1] != nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes.isEmpty == true)
            #expect(state.workspaces[id: Self.wsID1]?.layout.isEmpty == true)
        }
    }

    @Test func movePaneToEmptyWorkspace() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        let ws2 = WorkspaceFeature.State(
            id: Self.wsID2, name: "Empty", slug: "empty", color: .green,
            panes: [], layout: .empty, focusedPaneID: nil,
            createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Empty", create: false
        ), reply: nil)) { state in
            // Pane becomes sole leaf in target
            #expect(state.workspaces[id: Self.wsID2]?.panes.count == 1)
            #expect(state.workspaces[id: Self.wsID2]?.layout == .leaf(Self.paneID1))
            #expect(state.workspaces[id: Self.wsID2]?.focusedPaneID == Self.paneID1)
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

    // MARK: - configLoaded (TCP port)

    @Test func configLoadedSetsTCPPort() async {
        let store = makeStore()

        await store.send(.configLoaded(
            focusFollowsMouse: false, focusFollowsMouseDelay: 100, theme: nil, tcpPort: 19400
        )) { state in
            #expect(state.tcpPort == 19400)
        }
    }

    @Test func configLoadedZeroTCPPortMeansDisabled() async {
        let store = makeStore()

        await store.send(.configLoaded(
            focusFollowsMouse: true, focusFollowsMouseDelay: 200, theme: nil, tcpPort: 0
        )) { state in
            #expect(state.tcpPort == 0)
            #expect(state.focusFollowsMouse == true)
            #expect(state.focusFollowsMouseDelay == 200)
        }
    }

    // MARK: - setTCPPort

    @Test func setTCPPortUpdatesState() async {
        let store = makeStore()

        await store.send(.setTCPPort(19400)) { state in
            #expect(state.tcpPort == 19400)
        }
    }

    @Test func setTCPPortClampsToValidRange() async {
        let store = makeStore()

        await store.send(.setTCPPort(99999)) { state in
            #expect(state.tcpPort == 65535)
        }
    }

    @Test func setTCPPortNegativeClampsToZero() async {
        let store = makeStore()

        await store.send(.setTCPPort(-1)) { state in
            #expect(state.tcpPort == 0)
        }
    }

    @Test func setTCPPortClearsError() async {
        var appState = AppReducer.State()
        appState.tcpPortError = "Port 19400 is unavailable"

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setTCPPort(19401)) { state in
            #expect(state.tcpPortError == nil)
            #expect(state.tcpPort == 19401)
        }
    }

    @Test func setTCPPortToZeroDisables() async {
        var appState = AppReducer.State()
        appState.tcpPort = 19400

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setTCPPort(0)) { state in
            #expect(state.tcpPort == 0)
        }
    }

    // MARK: - tcpPortStartFailed

    @Test func tcpPortStartFailedSetsError() async {
        let store = makeStore()

        await store.send(.setTCPPort(19400)) { state in
            state.tcpPort = 19400
        }

        await store.send(.tcpPortStartFailed(19400)) { state in
            #expect(state.tcpPortError == "Port 19400 is unavailable")
        }
    }

    @Test func tcpPortStartFailedPreservesPort() async {
        let store = makeStore()

        await store.send(.setTCPPort(8080)) { state in
            state.tcpPort = 8080
        }

        await store.send(.tcpPortStartFailed(8080)) { state in
            #expect(state.tcpPortError == "Port 8080 is unavailable")
            #expect(state.tcpPort == 8080)
        }
    }

    // MARK: - Multi-select workspaces

    @Test func toggleWorkspaceSelectionAddsAndRemoves() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.toggleWorkspaceSelection(Self.wsID1)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1])
            #expect(state.lastSelectionAnchor == Self.wsID1)
        }
        await store.send(.toggleWorkspaceSelection(Self.wsID2)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, Self.wsID2])
            #expect(state.lastSelectionAnchor == Self.wsID2)
        }
        await store.send(.toggleWorkspaceSelection(Self.wsID1)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID2])
        }
    }

    @Test func rangeSelectWorkspaceSelectsInclusiveRange() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())

        let store = makeStore(workspaces: [ws1, ws2, ws3], activeWorkspaceID: Self.wsID1)

        // Anchor at ws1 (active), shift-click ws3 picks all three
        await store.send(.rangeSelectWorkspace(wsID3)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, Self.wsID2, wsID3])
            #expect(state.lastSelectionAnchor == wsID3)
        }
    }

    /// Regression: when workspaces are reorganised into groups, the
    /// shift-range must still cover the visible sidebar run — not the
    /// (now-divergent) `state.workspaces` insertion order.
    @Test func rangeSelectSpansVisibleOrderAcrossGroups() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let wsID4 = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let groupID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())
        let ws4 = Self.makeWorkspace(id: wsID4, name: "WS4", paneID: UUID())

        var state = AppReducer.State()
        state.workspaces = [ws1, ws2, ws3, ws4]
        // Visible order in sidebar: ws1, ws3, ws4, ws2 (ws3 + ws4 are
        // inside the group; ws1 and ws2 are top-level).
        state.groups = [WorkspaceGroup(id: groupID, name: "G", childOrder: [wsID3, wsID4])]
        state.topLevelOrder = [
            .workspace(Self.wsID1),
            .group(groupID),
            .workspace(Self.wsID2)
        ]
        state.activeWorkspaceID = Self.wsID1

        let store = TestStore(initialState: state) {
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

        // Anchor = ws1 (active). Shift-click ws4 must cover ws1, ws3,
        // ws4 (the three visible rows between them) — NOT ws1, ws2,
        // ws3, ws4 as the old insertion-order logic would have picked.
        await store.send(.rangeSelectWorkspace(wsID4)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, wsID3, wsID4])
            #expect(state.lastSelectionAnchor == wsID4)
        }
    }

    /// Regression: Cmd+N, the row's ⌘N badge, next/previous cycling and
    /// shift-range all read `visibleWorkspaceOrder`. Workspaces inside a
    /// collapsed group aren't on screen, so they must not contribute to
    /// the order — otherwise ⌘N numbering skips values, Cmd-] cycles to
    /// invisible workspaces, and shift-range selects rows the user
    /// cannot see.
    @Test func visibleWorkspaceOrderExcludesCollapsedGroupChildren() {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let wsID4 = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let groupID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())
        let ws4 = Self.makeWorkspace(id: wsID4, name: "WS4", paneID: UUID())

        var state = AppReducer.State()
        state.workspaces = [ws1, ws2, ws3, ws4]
        state.groups = [
            WorkspaceGroup(id: groupID, name: "G", isCollapsed: true, childOrder: [wsID3, wsID4])
        ]
        state.topLevelOrder = [
            .workspace(Self.wsID1),
            .group(groupID),
            .workspace(Self.wsID2)
        ]

        #expect(state.visibleWorkspaceOrder == [Self.wsID1, Self.wsID2])

        state.groups[id: groupID]?.isCollapsed = false
        #expect(state.visibleWorkspaceOrder == [Self.wsID1, wsID3, wsID4, Self.wsID2])
    }

    /// Cmd+N must map to the N-th *visible* workspace. With a collapsed
    /// group between ws1 and ws2, ⌘2 should activate ws2 — not ws3 (the
    /// first child of the collapsed group).
    @Test func switchToWorkspaceByIndexSkipsCollapsedGroupChildren() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let groupID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())

        var state = AppReducer.State()
        state.workspaces = [ws1, ws2, ws3]
        state.groups = [
            WorkspaceGroup(id: groupID, name: "G", isCollapsed: true, childOrder: [wsID3])
        ]
        state.topLevelOrder = [
            .workspace(Self.wsID1),
            .group(groupID),
            .workspace(Self.wsID2)
        ]
        state.activeWorkspaceID = Self.wsID1

        let store = TestStore(initialState: state) {
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

        // Index 1 is ws2 (visible), not ws3 (hidden inside collapsed group).
        await store.send(.switchToWorkspaceByIndex(1))
        await store.receive(\.setActiveWorkspace) { state in
            state.activeWorkspaceID = Self.wsID2
        }
    }

    @Test func selectAllWorkspacesFillsSelection() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())
        let store = makeStore(workspaces: [ws1, ws2, ws3], activeWorkspaceID: Self.wsID1)

        await store.send(.selectAllWorkspaces) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, Self.wsID2, wsID3])
            #expect(state.lastSelectionAnchor == wsID3)
        }
    }

    @Test func clearWorkspaceSelectionEmptiesSet() async {
        var appState = AppReducer.State()
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]
        appState.lastSelectionAnchor = Self.wsID2

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.clearWorkspaceSelection) { state in
            #expect(state.selectedWorkspaceIDs.isEmpty)
            #expect(state.lastSelectionAnchor == nil)
        }
    }

    @Test func setBulkColorAppliesToAllSelected() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", color: .red, paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", color: .blue, paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setBulkColor(.green)) { state in
            #expect(state.workspaces[id: Self.wsID1]?.color == .green)
            #expect(state.workspaces[id: Self.wsID2]?.color == .green)
        }
    }

    @Test func requestBulkDeletePresentsConfirmation() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.requestBulkDelete) { state in
            #expect(state.bulkDeleteConfirmationIDs == [Self.wsID1])
        }
    }

    @Test func requestBulkDeleteBlockedWhenSelectionCoversAll() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.requestBulkDelete) { state in
            #expect(state.bulkDeleteConfirmationIDs == nil)
        }
    }

    @Test func confirmBulkDeleteRemovesWorkspaces() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1,
                                     lastAccessedAt: Date(timeIntervalSince1970: 1000))
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2,
                                     lastAccessedAt: Date(timeIntervalSince1970: 2000))
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID(),
                                     lastAccessedAt: Date(timeIntervalSince1970: 3000))
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, wsID3]
        appState.lastSelectionAnchor = wsID3
        appState.bulkDeleteConfirmationIDs = [Self.wsID1, wsID3]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.confirmBulkDelete) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces[id: Self.wsID2] != nil)
            #expect(state.activeWorkspaceID == Self.wsID2)
            #expect(state.bulkDeleteConfirmationIDs == nil)
            #expect(state.selectedWorkspaceIDs.isEmpty)
            #expect(state.lastSelectionAnchor == nil)
        }
    }

    @Test func confirmBulkDeleteGuardsAgainstDeletingAll() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.bulkDeleteConfirmationIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.confirmBulkDelete) { state in
            #expect(state.workspaces.count == 2)
            #expect(state.bulkDeleteConfirmationIDs == nil)
        }
    }

    @Test func deleteWorkspaceClearsSelectionEntry() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]
        appState.lastSelectionAnchor = Self.wsID1

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID2])
            #expect(state.lastSelectionAnchor == nil)
        }
    }
}
