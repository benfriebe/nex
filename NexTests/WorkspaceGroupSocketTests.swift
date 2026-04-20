import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the socket-dispatch path for group + workspace-placement
/// commands introduced in Phase 6 (CLI / socket support). Resolves
/// name-or-UUID inputs through `State.resolveGroup` /
/// `resolveWorkspace` and lands mutations through the existing group
/// reducer actions.
@MainActor
struct WorkspaceGroupSocketTests {
    private static let ws1ID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
    private static let ws2ID = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
    private static let groupAID = UUID(uuidString: "60000000-0000-0000-0000-0000000000A1")!
    private static let groupBID = UUID(uuidString: "60000000-0000-0000-0000-0000000000A2")!

    private static func makeWorkspace(id: UUID, name: String) -> WorkspaceFeature.State {
        let paneID = UUID()
        return WorkspaceFeature.State(
            id: id,
            name: name,
            slug: name.lowercased(),
            color: .blue,
            panes: [Pane(id: paneID)],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private func makeStore(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [],
        groups: IdentifiedArrayOf<WorkspaceGroup> = [],
        topLevelOrder: [SidebarID] = [],
        activeWorkspaceID: UUID? = nil
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.groups = groups
        appState.topLevelOrder = topLevelOrder
        appState.activeWorkspaceID = activeWorkspaceID

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

    // MARK: - resolveGroup / resolveWorkspace

    @Test func resolveGroupPrefersUUIDOverName() {
        let a = WorkspaceGroup(id: Self.groupAID, name: "Dupes", childOrder: [])
        let b = WorkspaceGroup(id: Self.groupBID, name: "Dupes", childOrder: [])
        var state = AppReducer.State()
        state.groups = [a, b]

        // A UUID string resolves to the exact group, bypassing name collision.
        #expect(state.resolveGroup(Self.groupBID.uuidString)?.id == Self.groupBID)
    }

    @Test func resolveGroupAmbiguousNameReturnsNil() {
        let a = WorkspaceGroup(id: Self.groupAID, name: "Dupes", childOrder: [])
        let b = WorkspaceGroup(id: Self.groupBID, name: "Dupes", childOrder: [])
        var state = AppReducer.State()
        state.groups = [a, b]

        #expect(state.resolveGroup("Dupes") == nil)
    }

    @Test func resolveGroupExactNameMatches() {
        let a = WorkspaceGroup(id: Self.groupAID, name: "Monitors", childOrder: [])
        var state = AppReducer.State()
        state.groups = [a]

        #expect(state.resolveGroup("Monitors")?.id == Self.groupAID)
    }

    @Test func resolveGroupUnknownReturnsNil() {
        var state = AppReducer.State()
        state.groups = []
        #expect(state.resolveGroup("Missing") == nil)
    }

    // MARK: - group-create / rename / delete

    @Test func socketGroupCreateSpawnsGroup() async {
        let store = makeStore()

        await store.send(.socketMessage(.groupCreate(
            name: "Monitors",
            color: .blue
        ), reply: nil)) { state in
            #expect(state.groups.count == 1)
            let group = state.groups.first
            #expect(group?.name == "Monitors")
            #expect(group?.color == .blue)
            // Icon stays nil — setting an icon is UI-only.
            #expect(group?.icon == nil)
            // `topLevelOrder` was updated too so the new group is
            // visible in the sidebar.
            #expect(state.topLevelOrder.contains(where: {
                if case .group = $0 { true } else { false }
            }))
        }
    }

    @Test func socketGroupRenameByName() async {
        let group = WorkspaceGroup(id: Self.groupAID, name: "Old", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupAID)])

        await store.send(.socketMessage(.groupRename(nameOrID: "Old", newName: "New"), reply: nil))
        await store.receive(\.renameGroup) { state in
            #expect(state.groups[id: Self.groupAID]?.name == "New")
        }
    }

    @Test func socketGroupRenameUnknownIsNoOp() async {
        let store = makeStore()
        await store.send(.socketMessage(.groupRename(nameOrID: "Missing", newName: "Ignored"), reply: nil))
    }

    @Test func socketGroupDeletePromoteChildren() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "B")
        let group = WorkspaceGroup(
            id: Self.groupAID,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.ws1ID, Self.ws2ID]
        )
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.group(Self.groupAID)],
            activeWorkspaceID: Self.ws1ID
        )

        await store.send(.socketMessage(.groupDelete(nameOrID: "G", cascade: false), reply: nil))
        await store.receive(\.deleteGroup) { state in
            // Children promoted; group removed. Dialog is never
            // shown — the CLI path skips the confirmation.
            #expect(state.groups[id: Self.groupAID] == nil)
            #expect(state.groupDeleteConfirmation == nil)
            #expect(state.workspaces[id: Self.ws1ID] != nil)
            #expect(state.workspaces[id: Self.ws2ID] != nil)
        }
    }

    @Test func socketGroupDeleteCascadeDropsWorkspaces() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "A")
        let group = WorkspaceGroup(
            id: Self.groupAID,
            name: "G",
            childOrder: [Self.ws1ID]
        )
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "B")
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.group(Self.groupAID), .workspace(Self.ws2ID)],
            activeWorkspaceID: Self.ws1ID
        )

        await store.send(.socketMessage(.groupDelete(nameOrID: "G", cascade: true), reply: nil))
        await store.receive(\.deleteGroup) { state in
            #expect(state.groups[id: Self.groupAID] == nil)
            #expect(state.workspaces[id: Self.ws1ID] == nil)
            #expect(state.workspaces[id: Self.ws2ID] != nil)
        }
    }

    // MARK: - workspace-create with group

    @Test func socketWorkspaceCreateWithExistingGroupMovesInto() async {
        let existing = WorkspaceGroup(id: Self.groupAID, name: "Monitors", childOrder: [])
        let store = makeStore(groups: [existing], topLevelOrder: [.group(Self.groupAID)])

        await store.send(.socketMessage(.workspaceCreate(
            name: "Alpha",
            path: "/tmp",
            color: .blue,
            group: "Monitors"
        ), reply: nil))
        // The socket handler seeds state inline, then dispatches
        // `.moveWorkspaceToGroup` which is the action we receive.
        await store.receive(\.moveWorkspaceToGroup) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.groups[id: Self.groupAID]?.childOrder.count == 1)
            #expect(state.groups.count == 1) // no new group was created
        }
    }

    @Test func socketWorkspaceCreateWithMissingGroupCreatesIt() async {
        let store = makeStore()

        await store.send(.socketMessage(.workspaceCreate(
            name: "Alpha",
            path: nil,
            color: nil,
            group: "Fresh"
        ), reply: nil))
        await store.receive(\.moveWorkspaceToGroup) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.groups.count == 1)
            let newGroup = state.groups.first
            #expect(newGroup?.name == "Fresh")
            // New group adopted the new workspace.
            #expect(newGroup?.childOrder.count == 1)
        }
    }

    @Test func socketWorkspaceCreateWithoutGroupStaysTopLevel() async {
        let store = makeStore()

        await store.send(.socketMessage(.workspaceCreate(
            name: "Alpha",
            path: nil,
            color: nil,
            group: nil
        ), reply: nil))
        // With no group, the handler just dispatches the existing
        // `createWorkspace` action — no move-to-group follow-up.
        await store.receive(\.createWorkspace) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.groups.isEmpty)
        }
    }

    // MARK: - workspace-move

    @Test func socketWorkspaceMoveIntoGroup() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "Alpha")
        let group = WorkspaceGroup(id: Self.groupAID, name: "Monitors", childOrder: [])
        let store = makeStore(
            workspaces: [ws],
            groups: [group],
            topLevelOrder: [.workspace(Self.ws1ID), .group(Self.groupAID)]
        )

        await store.send(.socketMessage(.workspaceMove(
            nameOrID: "Alpha",
            group: "Monitors",
            index: nil
        ), reply: nil))
        await store.receive(\.moveWorkspaceToGroup) { state in
            #expect(state.groups[id: Self.groupAID]?.childOrder == [Self.ws1ID])
        }
    }

    @Test func socketWorkspaceMoveToTopLevel() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "Alpha")
        let group = WorkspaceGroup(
            id: Self.groupAID,
            name: "Monitors",
            childOrder: [Self.ws1ID]
        )
        let store = makeStore(
            workspaces: [ws],
            groups: [group],
            topLevelOrder: [.group(Self.groupAID)]
        )

        await store.send(.socketMessage(.workspaceMove(
            nameOrID: "Alpha",
            group: nil,
            index: nil
        ), reply: nil))
        await store.receive(\.moveWorkspaceToGroup) { state in
            #expect(state.groups[id: Self.groupAID]?.childOrder.isEmpty == true)
            #expect(state.topLevelOrder.contains(.workspace(Self.ws1ID)))
        }
    }

    @Test func socketWorkspaceMoveUnknownWorkspaceIsNoOp() async {
        let group = WorkspaceGroup(id: Self.groupAID, name: "Monitors", childOrder: [])
        let store = makeStore(
            groups: [group],
            topLevelOrder: [.group(Self.groupAID)]
        )

        await store.send(.socketMessage(.workspaceMove(
            nameOrID: "Missing",
            group: "Monitors",
            index: nil
        ), reply: nil))
        // No follow-up action expected — store stays idle.
    }

    @Test func socketWorkspaceMoveUnknownGroupIsNoOp() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "Alpha")
        let store = makeStore(
            workspaces: [ws],
            topLevelOrder: [.workspace(Self.ws1ID)]
        )

        await store.send(.socketMessage(.workspaceMove(
            nameOrID: "Alpha",
            group: "Missing",
            index: nil
        ), reply: nil))
    }

    // MARK: - Findings fixes

    @Test func socketWorkspaceCreateRejectsAmbiguousGroupName() async {
        // Two groups named "Dupes" — the name is ambiguous so we
        // can't safely auto-create a third one. Whole message is
        // a no-op: no workspace created, no new group created.
        let a = WorkspaceGroup(id: Self.groupAID, name: "Dupes", childOrder: [])
        let b = WorkspaceGroup(id: Self.groupBID, name: "Dupes", childOrder: [])
        let store = makeStore(
            groups: [a, b],
            topLevelOrder: [.group(Self.groupAID), .group(Self.groupBID)]
        )

        await store.send(.socketMessage(.workspaceCreate(
            name: "Alpha",
            path: nil,
            color: nil,
            group: "Dupes"
        ), reply: nil))
        // No effects expected. Workspace count stays zero, group
        // count stays at two.
        #expect(store.state.workspaces.isEmpty)
        #expect(store.state.groups.count == 2)
    }

    @Test func socketWorkspaceCreateWhitespaceGroupFallsBackToTopLevel() async {
        let store = makeStore()
        // Whitespace-only group name should NOT create a blank
        // group. Instead the message degrades to "create workspace
        // top-level" so the workspace still lands somewhere.
        await store.send(.socketMessage(.workspaceCreate(
            name: "Alpha",
            path: nil,
            color: nil,
            group: "   "
        ), reply: nil))
        await store.receive(\.createWorkspace) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.groups.isEmpty)
        }
    }

    @Test func socketGroupCreateWhitespaceNameIsNoOp() async {
        let store = makeStore()
        await store.send(.socketMessage(.groupCreate(
            name: "   ",
            color: nil
        ), reply: nil))
        // No group appended, no persist.
        #expect(store.state.groups.isEmpty)
    }

    @Test func socketGroupCreateTrimsName() async {
        let store = makeStore()
        await store.send(.socketMessage(.groupCreate(
            name: "  Monitors  ",
            color: nil
        ), reply: nil)) { state in
            #expect(state.groups.first?.name == "Monitors")
        }
    }
}
