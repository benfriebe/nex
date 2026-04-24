import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct WorkspaceGroupCRUDTests {
    private static let wsID1 = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private static let wsID2 = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    private static let wsID3 = UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
    private static let groupA = UUID(uuidString: "40000000-0000-0000-0000-0000000000A1")!
    private static let groupB = UUID(uuidString: "40000000-0000-0000-0000-0000000000A2")!

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
        activeWorkspaceID: UUID? = nil,
        selectedWorkspaceIDs: Set<UUID> = []
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.groups = groups
        appState.topLevelOrder = topLevelOrder
        appState.activeWorkspaceID = activeWorkspaceID
        appState.selectedWorkspaceIDs = selectedWorkspaceIDs

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = UUIDGenerator { Self.groupA }
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    // MARK: - createGroup

    @Test func createGroupAppendsToTopLevelOrder() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let store = makeStore(
            workspaces: [ws],
            topLevelOrder: [.workspace(Self.wsID1)]
        )

        await store.send(.createGroup(name: "Monitors")) { state in
            #expect(state.groups.count == 1)
            #expect(state.groups.first?.name == "Monitors")
            #expect(state.topLevelOrder.last?.groupID != nil)
        }
    }

    @Test func createGroupTrimsWhitespaceAndSkipsEmpty() async {
        let store = makeStore()

        await store.send(.createGroup(name: "   ")) { state in
            #expect(state.groups.isEmpty)
        }

        await store.send(.createGroup(name: "  Spaces  ")) { state in
            #expect(state.groups.count == 1)
            #expect(state.groups.first?.name == "Spaces")
        }
    }

    @Test func createGroupInsertsAfterSpecifiedEntry() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let store = makeStore(
            workspaces: [ws1, ws2],
            topLevelOrder: [.workspace(Self.wsID1), .workspace(Self.wsID2)]
        )

        await store.send(.createGroup(
            name: "Between",
            color: nil,
            insertAfter: .workspace(Self.wsID1)
        )) { state in
            #expect(state.topLevelOrder.count == 3)
            if case .workspace(let id) = state.topLevelOrder[0] { #expect(id == Self.wsID1) }
            if case .group = state.topLevelOrder[1] {} else { Issue.record("expected group at index 1") }
            if case .workspace(let id) = state.topLevelOrder[2] { #expect(id == Self.wsID2) }
        }
    }

    @Test func createGroupDefaultPlacementAppendsToEndOfList() async {
        // Default (`newGroupPlacement == .endOfList`): an anchorless
        // createGroup appends to the bottom of the sidebar regardless of
        // which workspace is active.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            topLevelOrder: [
                .workspace(Self.wsID1),
                .workspace(Self.wsID2),
                .workspace(Self.wsID3)
            ],
            activeWorkspaceID: Self.wsID2
        )

        await store.send(.createGroup(name: "Monitors")) { state in
            #expect(state.topLevelOrder.count == 4)
            #expect(state.topLevelOrder.last?.groupID == Self.groupA)
        }
    }

    @Test func createGroupNearSelectionPlacementFollowsActiveWorkspace() async {
        // With `newGroupPlacement == .nearSelection`, an anchorless
        // createGroup inserts the new group directly after the active
        // workspace's sidebar entry rather than appending to the end.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.topLevelOrder = [
            .workspace(Self.wsID1),
            .workspace(Self.wsID2),
            .workspace(Self.wsID3)
        ]
        appState.activeWorkspaceID = Self.wsID2
        appState.settings.newGroupPlacement = .nearSelection

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = UUIDGenerator { Self.groupA }
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createGroup(name: "Monitors")) { state in
            #expect(state.topLevelOrder.count == 4)
            if case .workspace(let id) = state.topLevelOrder[0] { #expect(id == Self.wsID1) }
            if case .workspace(let id) = state.topLevelOrder[1] { #expect(id == Self.wsID2) }
            if case .group = state.topLevelOrder[2] {} else { Issue.record("expected group at index 2") }
            if case .workspace(let id) = state.topLevelOrder[3] { #expect(id == Self.wsID3) }
        }
    }

    @Test func createGroupNearSelectionAnchorsToParentGroupWhenNested() async {
        // When the active workspace lives inside a group, `.nearSelection`
        // inserts the new group after the parent group's entry so the two
        // groups are adjacent in the sidebar.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        let parentGroup = WorkspaceGroup(
            id: Self.groupB,
            name: "Parent",
            childOrder: [Self.wsID2]
        )
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.groups = [parentGroup]
        appState.topLevelOrder = [
            .workspace(Self.wsID1),
            .group(Self.groupB),
            .workspace(Self.wsID3)
        ]
        appState.activeWorkspaceID = Self.wsID2
        appState.settings.newGroupPlacement = .nearSelection

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = UUIDGenerator { Self.groupA }
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createGroup(name: "Sibling")) { state in
            #expect(state.topLevelOrder.count == 4)
            if case .workspace(let id) = state.topLevelOrder[0] { #expect(id == Self.wsID1) }
            if case .group(let id) = state.topLevelOrder[1] { #expect(id == Self.groupB) }
            if case .group(let id) = state.topLevelOrder[2] { #expect(id == Self.groupA) }
            if case .workspace(let id) = state.topLevelOrder[3] { #expect(id == Self.wsID3) }
        }
    }

    @Test func createGroupNearSelectionGroupingActiveTopLevelTakesItsSlot() async {
        // Regression for the P1 bug: when the "New Group..." row-menu flow
        // folds the active, top-level workspace into a new group
        // (`initialWorkspaceIDs = [active]`), the new group must land in
        // the slot that workspace occupied instead of falling through to
        // `append`, because the anchor is removed before the insertion
        // index lookup.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.topLevelOrder = [
            .workspace(Self.wsID1),
            .workspace(Self.wsID2),
            .workspace(Self.wsID3)
        ]
        appState.activeWorkspaceID = Self.wsID2
        appState.settings.newGroupPlacement = .nearSelection

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = UUIDGenerator { Self.groupA }
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createGroup(
            name: "Bundle",
            color: nil,
            insertAfter: nil,
            initialWorkspaceIDs: [Self.wsID2]
        )) { state in
            #expect(state.topLevelOrder.count == 3)
            if case .workspace(let id) = state.topLevelOrder[0] { #expect(id == Self.wsID1) }
            if case .group(let id) = state.topLevelOrder[1] { #expect(id == Self.groupA) }
            if case .workspace(let id) = state.topLevelOrder[2] { #expect(id == Self.wsID3) }
            #expect(state.groups[id: Self.groupA]?.childOrder == [Self.wsID2])
        }
    }

    @Test func createGroupNearSelectionAnchorsToRowNotActiveWorkspace() async {
        // Regression for the P2 bug: `.nearSelection` must anchor to the
        // workspace being grouped (first initialWorkspaceIDs entry), not
        // to the currently active workspace. The row-level "New Group..."
        // on a non-active row previously placed the new group next to
        // `activeWorkspaceID` instead.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.topLevelOrder = [
            .workspace(Self.wsID1),
            .workspace(Self.wsID2),
            .workspace(Self.wsID3)
        ]
        // Active workspace is wsID1, but the user right-clicks wsID3.
        appState.activeWorkspaceID = Self.wsID1
        appState.settings.newGroupPlacement = .nearSelection

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = UUIDGenerator { Self.groupA }
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createGroup(
            name: "Bundle",
            color: nil,
            insertAfter: nil,
            initialWorkspaceIDs: [Self.wsID3]
        )) { state in
            // The new group takes wsID3's slot (end of list here), not a
            // slot next to wsID1 (the active workspace).
            #expect(state.topLevelOrder.count == 3)
            if case .workspace(let id) = state.topLevelOrder[0] { #expect(id == Self.wsID1) }
            if case .workspace(let id) = state.topLevelOrder[1] { #expect(id == Self.wsID2) }
            if case .group(let id) = state.topLevelOrder[2] { #expect(id == Self.groupA) }
            #expect(state.groups[id: Self.groupA]?.childOrder == [Self.wsID3])
        }
    }

    @Test func createGroupExplicitInsertAfterStillHonoredAfterDetachment() async {
        // When the caller supplies an explicit `insertAfter` that points at
        // a workspace being folded into the new group, the new group must
        // still land in that slot; an explicit anchor is authoritative and
        // should survive the detachment step.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            topLevelOrder: [
                .workspace(Self.wsID1),
                .workspace(Self.wsID2),
                .workspace(Self.wsID3)
            ]
        )

        await store.send(.createGroup(
            name: "Bundle",
            color: nil,
            insertAfter: .workspace(Self.wsID2),
            initialWorkspaceIDs: [Self.wsID2]
        )) { state in
            #expect(state.topLevelOrder.count == 3)
            if case .workspace(let id) = state.topLevelOrder[0] { #expect(id == Self.wsID1) }
            if case .group(let id) = state.topLevelOrder[1] { #expect(id == Self.groupA) }
            if case .workspace(let id) = state.topLevelOrder[2] { #expect(id == Self.wsID3) }
        }
    }

    @Test func createGroupMovesInitialWorkspacesFromTopLevel() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            topLevelOrder: [
                .workspace(Self.wsID1),
                .workspace(Self.wsID2),
                .workspace(Self.wsID3)
            ]
        )

        await store.send(.createGroup(
            name: "Bundle",
            color: nil,
            insertAfter: nil,
            initialWorkspaceIDs: [Self.wsID1, Self.wsID3]
        )) { state in
            #expect(state.groups.count == 1)
            let group = state.groups.first!
            #expect(group.childOrder == [Self.wsID1, Self.wsID3])
            // The two workspaces are no longer top-level; ws2 still is.
            let remaining: [UUID] = state.topLevelOrder.compactMap(\.workspaceID)
            #expect(remaining == [Self.wsID2])
        }
    }

    // MARK: - renameGroup

    @Test func renameGroupTrimsAndIgnoresEmpty() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "Old", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.renameGroup(id: Self.groupA, name: "   ")) { state in
            #expect(state.groups[id: Self.groupA]?.name == "Old")
        }
        await store.send(.renameGroup(id: Self.groupA, name: "  New  ")) { state in
            #expect(state.groups[id: Self.groupA]?.name == "New")
        }
    }

    @Test func renameGroupClearsRenamingIDWhenMatches() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "Old", childOrder: [])
        var appState = AppReducer.State()
        appState.groups = [group]
        appState.topLevelOrder = [.group(Self.groupA)]
        appState.renamingGroupID = Self.groupA

        let store = TestStore(initialState: appState) { AppReducer() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.renameGroup(id: Self.groupA, name: "New")) { state in
            #expect(state.renamingGroupID == nil)
            #expect(state.groups[id: Self.groupA]?.name == "New")
        }
    }

    // MARK: - setGroupColor

    @Test func setGroupColorAssignsAndClears() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "G", color: .blue, childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.setGroupColor(id: Self.groupA, color: .purple)) { state in
            #expect(state.groups[id: Self.groupA]?.color == .purple)
        }
        await store.send(.setGroupColor(id: Self.groupA, color: nil)) { state in
            #expect(state.groups[id: Self.groupA]?.color == nil)
        }
    }

    // MARK: - setGroupIcon + custom emoji prompt

    @Test func setGroupIconAssignsAndClears() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "G", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.setGroupIcon(id: Self.groupA, icon: .systemName("star.fill"))) { state in
            #expect(state.groups[id: Self.groupA]?.icon == .systemName("star.fill"))
        }
        await store.send(.setGroupIcon(id: Self.groupA, icon: .emoji("🔥"))) { state in
            #expect(state.groups[id: Self.groupA]?.icon == .emoji("🔥"))
        }
        await store.send(.setGroupIcon(id: Self.groupA, icon: nil)) { state in
            #expect(state.groups[id: Self.groupA]?.icon == nil)
        }
    }

    @Test func setGroupIconIgnoresUnknownGroup() async {
        let store = makeStore()
        let unknown = UUID(uuidString: "90000000-0000-0000-0000-000000000099")!
        await store.send(.setGroupIcon(id: unknown, icon: .emoji("⭐")))
    }

    @Test func customEmojiPromptOpensAndClears() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "Work", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.requestGroupCustomEmoji(Self.groupA)) { state in
            #expect(state.groupCustomEmojiPrompt?.groupID == Self.groupA)
            #expect(state.groupCustomEmojiPrompt?.groupName == "Work")
        }
        await store.send(.cancelGroupCustomEmoji) { state in
            #expect(state.groupCustomEmojiPrompt == nil)
        }
    }

    @Test func confirmGroupCustomEmojiAppliesFirstGrapheme() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "Work", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.requestGroupCustomEmoji(Self.groupA))
        // "🔥💰" is two grapheme clusters; the reducer keeps only the first.
        await store.send(.confirmGroupCustomEmoji("🔥💰")) { state in
            #expect(state.groups[id: Self.groupA]?.icon == .emoji("🔥"))
            #expect(state.groupCustomEmojiPrompt == nil)
        }
    }

    @Test func confirmGroupCustomEmojiWithWhitespaceClearsPromptAndLeavesIconNil() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "Work", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.requestGroupCustomEmoji(Self.groupA))
        // Whitespace-only payload is rejected; group icon stays nil
        // and the prompt clears.
        await store.send(.confirmGroupCustomEmoji("   ")) { state in
            #expect(state.groups[id: Self.groupA]?.icon == nil)
            #expect(state.groupCustomEmojiPrompt == nil)
        }
    }

    @Test func confirmGroupCustomEmojiRejectsNonEmoji() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "Work", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.requestGroupCustomEmoji(Self.groupA))
        // A plain letter passes the "non-empty grapheme" gate but
        // fails the emoji check; icon stays nil, prompt still clears.
        await store.send(.confirmGroupCustomEmoji("a")) { state in
            #expect(state.groups[id: Self.groupA]?.icon == nil)
            #expect(state.groupCustomEmojiPrompt == nil)
        }
    }

    // MARK: - deleteGroup (cascade = false)

    @Test func deleteGroupPromotesChildrenToTopLevel() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsID2, Self.wsID3]
        )
        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            groups: [group],
            topLevelOrder: [.workspace(Self.wsID1), .group(Self.groupA)]
        )

        await store.send(.deleteGroup(id: Self.groupA, cascade: false)) { state in
            #expect(state.groups.isEmpty)
            #expect(state.workspaces.count == 3)
            #expect(state.topLevelOrder == [
                .workspace(Self.wsID1),
                .workspace(Self.wsID2),
                .workspace(Self.wsID3)
            ])
        }
    }

    // MARK: - deleteGroup (cascade = true)

    @Test func deleteGroupCascadeRemovesWorkspacesAndSurfaces() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Keep")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Doomed")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsID2]
        )
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.workspace(Self.wsID1), .group(Self.groupA)],
            activeWorkspaceID: Self.wsID2
        )

        await store.send(.deleteGroup(id: Self.groupA, cascade: true)) { state in
            #expect(state.groups.isEmpty)
            #expect(state.workspaces[id: Self.wsID2] == nil)
            #expect(state.workspaces.count == 1)
            // Active workspace should fall back to the surviving one
            #expect(state.activeWorkspaceID == Self.wsID1)
            #expect(state.topLevelOrder == [.workspace(Self.wsID1)])
        }
    }

    // MARK: - moveWorkspaceToGroup

    @Test func moveWorkspaceTopLevelIntoGroup() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsID2]
        )
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.workspace(Self.wsID1), .group(Self.groupA)]
        )

        await store.send(.moveWorkspaceToGroup(
            workspaceID: Self.wsID1, groupID: Self.groupA, index: nil
        )) { state in
            #expect(state.groups[id: Self.groupA]?.childOrder == [Self.wsID2, Self.wsID1])
            #expect(state.topLevelOrder == [.group(Self.groupA)])
        }
    }

    @Test func moveWorkspaceGroupToTopLevel() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsID2]
        )
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.workspace(Self.wsID1), .group(Self.groupA)]
        )

        await store.send(.moveWorkspaceToGroup(
            workspaceID: Self.wsID2, groupID: nil, index: 0
        )) { state in
            #expect(state.groups[id: Self.groupA]?.childOrder == [])
            #expect(state.topLevelOrder == [
                .workspace(Self.wsID2),
                .workspace(Self.wsID1),
                .group(Self.groupA)
            ])
        }
    }

    @Test func moveWorkspaceBetweenGroups() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let groupA = WorkspaceGroup(id: Self.groupA, name: "A", childOrder: [Self.wsID1])
        let groupB = WorkspaceGroup(id: Self.groupB, name: "B", childOrder: [Self.wsID2])
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [groupA, groupB],
            topLevelOrder: [.group(Self.groupA), .group(Self.groupB)]
        )

        await store.send(.moveWorkspaceToGroup(
            workspaceID: Self.wsID1, groupID: Self.groupB, index: 0
        )) { state in
            #expect(state.groups[id: Self.groupA]?.childOrder == [])
            #expect(state.groups[id: Self.groupB]?.childOrder == [Self.wsID1, Self.wsID2])
        }
    }

    @Test func moveWorkspaceWithinGroupReorders() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "G",
            childOrder: [Self.wsID1, Self.wsID2, Self.wsID3]
        )
        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            groups: [group],
            topLevelOrder: [.group(Self.groupA)]
        )

        await store.send(.moveWorkspaceToGroup(
            workspaceID: Self.wsID3, groupID: Self.groupA, index: 0
        )) { state in
            #expect(state.groups[id: Self.groupA]?.childOrder == [Self.wsID3, Self.wsID1, Self.wsID2])
        }
    }

    @Test func moveWorkspaceIntoCollapsedGroupExpandsByDefault() async {
        // Default (`settings.expandGroupOnWorkspaceDrop == true`): dropping a
        // workspace into a collapsed group auto-expands it so the moved
        // workspace is immediately visible.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "G",
            isCollapsed: true,
            childOrder: []
        )
        let store = makeStore(
            workspaces: [ws1],
            groups: [group],
            topLevelOrder: [.workspace(Self.wsID1), .group(Self.groupA)]
        )

        await store.send(.moveWorkspaceToGroup(
            workspaceID: Self.wsID1, groupID: Self.groupA, index: nil
        )) { state in
            #expect(state.groups[id: Self.groupA]?.isCollapsed == false)
            #expect(state.groups[id: Self.groupA]?.childOrder == [Self.wsID1])
        }
    }

    @Test func moveWorkspaceIntoCollapsedGroupKeepsItCollapsedWhenSettingDisabled() async {
        // Issue #59: with `expandGroupOnWorkspaceDrop` off, dropping a
        // workspace into a collapsed group must not expand it — the move is
        // silent and the workspace becomes visible only when the user
        // expands the group themselves.
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "G",
            isCollapsed: true,
            childOrder: []
        )
        var appState = AppReducer.State()
        appState.workspaces = [ws1]
        appState.groups = [group]
        appState.topLevelOrder = [.workspace(Self.wsID1), .group(Self.groupA)]
        appState.settings.expandGroupOnWorkspaceDrop = false

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = UUIDGenerator { Self.groupA }
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.moveWorkspaceToGroup(
            workspaceID: Self.wsID1, groupID: Self.groupA, index: nil
        )) { state in
            #expect(state.groups[id: Self.groupA]?.isCollapsed == true)
            #expect(state.groups[id: Self.groupA]?.childOrder == [Self.wsID1])
        }
    }

    // MARK: - requestGroupDelete

    @Test func requestGroupDeleteCapturesWorkspaceCount() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let group = WorkspaceGroup(
            id: Self.groupA,
            name: "Monitors",
            childOrder: [Self.wsID1, Self.wsID2]
        )
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.group(Self.groupA)]
        )

        await store.send(.requestGroupDelete(Self.groupA)) { state in
            let confirmation = state.groupDeleteConfirmation
            #expect(confirmation?.groupID == Self.groupA)
            #expect(confirmation?.groupName == "Monitors")
            #expect(confirmation?.workspaceCount == 2)
        }

        await store.send(.cancelGroupDelete) { state in
            #expect(state.groupDeleteConfirmation == nil)
        }
    }

    // MARK: - Bulk create group from selection

    @Test func requestBulkCreateGroupOrdersSelectionBySidebar() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "C")
        // Put ws2 inside a group; select ws3 and ws2. The prompt should
        // list them in sidebar order (ws3 first if it's above the group).
        let group = WorkspaceGroup(id: Self.groupA, name: "G", childOrder: [Self.wsID2])
        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            groups: [group],
            topLevelOrder: [
                .workspace(Self.wsID1),
                .workspace(Self.wsID3),
                .group(Self.groupA)
            ],
            selectedWorkspaceIDs: [Self.wsID2, Self.wsID3]
        )

        await store.send(.requestBulkCreateGroup) { state in
            #expect(state.groupBulkCreatePrompt?.workspaceIDs == [Self.wsID3, Self.wsID2])
        }
    }

    @Test func confirmBulkCreateGroupBuildsGroup() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B")
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.topLevelOrder = [.workspace(Self.wsID1), .workspace(Self.wsID2)]
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]
        appState.groupBulkCreatePrompt = GroupBulkCreatePrompt(
            workspaceIDs: [Self.wsID1, Self.wsID2]
        )

        let store = TestStore(initialState: appState) { AppReducer() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = UUIDGenerator { Self.groupA }
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.confirmBulkCreateGroup(name: "New", color: .green)) { state in
            #expect(state.groupBulkCreatePrompt == nil)
            #expect(state.selectedWorkspaceIDs.isEmpty)
        }
        await store.receive(\.createGroup) { state in
            #expect(state.groups.count == 1)
            let group = state.groups.first!
            #expect(group.name == "New")
            #expect(group.color == .green)
            #expect(group.childOrder == [Self.wsID1, Self.wsID2])
            #expect(state.topLevelOrder == [.group(group.id)])
        }
    }

    @Test func confirmBulkCreateGroupBlocksOnEmptyName() async {
        var appState = AppReducer.State()
        appState.groupBulkCreatePrompt = GroupBulkCreatePrompt(workspaceIDs: [Self.wsID1])

        let store = TestStore(initialState: appState) { AppReducer() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.confirmBulkCreateGroup(name: "   ", color: nil)) { state in
            #expect(state.groupBulkCreatePrompt == nil)
            #expect(state.groups.isEmpty)
        }
    }

    // MARK: - beginRenameGroup / setRenamingGroupID

    @Test func beginRenameGroupRequiresExistingGroup() async {
        let group = WorkspaceGroup(id: Self.groupA, name: "X", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupA)])

        await store.send(.beginRenameGroup(Self.groupB)) { state in
            #expect(state.renamingGroupID == nil)
        }
        await store.send(.beginRenameGroup(Self.groupA)) { state in
            #expect(state.renamingGroupID == Self.groupA)
        }
        await store.send(.setRenamingGroupID(nil)) { state in
            #expect(state.renamingGroupID == nil)
        }
    }

    // MARK: - Regression guards

    /// If a stale caller sends `moveWorkspaceToGroup` with a deleted group id,
    /// the reducer must not detach the workspace from its current parent.
    @Test func moveWorkspaceToUnknownGroupIsNoOp() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let groupA = WorkspaceGroup(id: Self.groupA, name: "G", childOrder: [Self.wsID1])
        let store = makeStore(
            workspaces: [ws],
            groups: [groupA],
            topLevelOrder: [.group(Self.groupA)]
        )

        // groupB does not exist — must not orphan wsID1.
        await store.send(.moveWorkspaceToGroup(
            workspaceID: Self.wsID1,
            groupID: Self.groupB,
            index: nil
        )) { state in
            #expect(state.groups[id: Self.groupA]?.childOrder == [Self.wsID1])
            #expect(state.topLevelOrder == [.group(Self.groupA)])
        }
    }

    /// `createGroup(autoRename: true)` drops the user straight into inline
    /// rename so the placeholder name can be replaced without another click.
    @Test func createGroupAutoRenameSetsRenamingGroupID() async {
        let store = makeStore()

        await store.send(.createGroup(name: "New Group", autoRename: true)) { state in
            #expect(state.groups.count == 1)
            let newID = state.groups.first!.id
            #expect(state.renamingGroupID == newID)
        }
    }

    /// The bulk-create path passes `autoRename: false` (the default) because
    /// the user already typed a name into the NewGroupSheet — don't re-open
    /// the inline rename.
    @Test func createGroupWithoutAutoRenameLeavesRenamingGroupIDNil() async {
        let store = makeStore()

        await store.send(.createGroup(name: "Monitors")) { state in
            #expect(state.groups.count == 1)
            #expect(state.renamingGroupID == nil)
        }
    }

    // MARK: - moveGroup

    /// `moveGroup` reorders `.group(id)` inside `topLevelOrder`; doesn't
    /// touch `state.workspaces` or `childOrder`.
    @Test func moveGroupReordersTopLevelEntries() async {
        let wsA = Self.makeWorkspace(id: Self.wsID1, name: "A")
        let groupA = WorkspaceGroup(id: Self.groupA, name: "G1", childOrder: [])
        let groupB = WorkspaceGroup(id: Self.groupB, name: "G2", childOrder: [])
        let store = makeStore(
            workspaces: [wsA],
            groups: [groupA, groupB],
            topLevelOrder: [
                .workspace(Self.wsID1),
                .group(Self.groupA),
                .group(Self.groupB)
            ]
        )

        // Move groupA from index 1 → index 2 (post-remove). Result: [ws, G2, G1].
        await store.send(.moveGroup(id: Self.groupA, toIndex: 2)) { state in
            #expect(state.topLevelOrder == [
                .workspace(Self.wsID1),
                .group(Self.groupB),
                .group(Self.groupA)
            ])
        }
    }

    @Test func moveGroupSameIndexIsNoOp() async {
        let groupA = WorkspaceGroup(id: Self.groupA, name: "G", childOrder: [])
        let store = makeStore(
            groups: [groupA],
            topLevelOrder: [.group(Self.groupA)]
        )

        // No state change expected when fromIdx == toIndex.
        await store.send(.moveGroup(id: Self.groupA, toIndex: 0))
    }

    @Test func moveGroupIgnoresOutOfBoundsIndex() async {
        let groupA = WorkspaceGroup(id: Self.groupA, name: "G", childOrder: [])
        let store = makeStore(
            groups: [groupA],
            topLevelOrder: [.group(Self.groupA)]
        )

        // toIndex == topLevelOrder.count (1) is out of bounds per guard.
        await store.send(.moveGroup(id: Self.groupA, toIndex: 1))
    }
}
