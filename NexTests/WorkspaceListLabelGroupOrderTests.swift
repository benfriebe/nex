import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the CLI surfaces added for issue #225:
///   - `workspace-list` metadata (timestamps, labels, agent session) and
///     the `--group` filter
///   - `workspace-label` set/add/remove/clear request/response
///   - `group-reorder` (explicit order) and `group-sort` (by key)
/// Reply JSON is captured via a closure-backed `SocketServer.ReplyHandle`
/// stub, mirroring `WorkspaceDeleteReplyTests`.
@MainActor
struct WorkspaceListLabelGroupOrderTests {
    private static let ws1ID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    private static let ws2ID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    private static let ws3ID = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
    private static let groupID = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!

    private final class CaptureSink: @unchecked Sendable {
        var payloads: [[String: Any]] = []
        var closedCount = 0
    }

    private func makeCaptureHandle(_ sink: CaptureSink) -> SocketServer.ReplyHandle {
        SocketServer.ReplyHandle(
            id: 1,
            send: { json in sink.payloads.append(json) },
            close: { sink.closedCount += 1 }
        )
    }

    private static func makeWorkspace(
        id: UUID,
        name: String,
        labels: [String] = [],
        panes: [Pane]? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1000),
        lastAccessedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> WorkspaceFeature.State {
        let resolvedPanes = panes ?? [Pane(id: UUID())]
        let paneIDs = resolvedPanes.map(\.id)
        var layout: PaneLayout = paneIDs.isEmpty ? .empty : .leaf(paneIDs[0])
        for pid in paneIDs.dropFirst() {
            layout = layout.splitting(
                paneID: paneIDs[0], direction: .horizontal, newPaneID: pid
            ).layout
        }
        var state = WorkspaceFeature.State(
            id: id,
            name: name,
            slug: name.lowercased(),
            color: .blue,
            panes: IdentifiedArrayOf(uniqueElements: resolvedPanes),
            layout: layout,
            focusedPaneID: paneIDs.first,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt
        )
        state.labels = labels
        return state
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
            $0.userDefaults = .ephemeral()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    // MARK: - workspace-list metadata

    @Test func workspaceListEmitsMetadata() async {
        let created = Date(timeIntervalSince1970: 2000)
        let accessed = Date(timeIntervalSince1970: 3000)
        let activity = Date(timeIntervalSince1970: 5000)
        let pane = Pane(
            id: UUID(),
            agentSessionID: "sess-abc",
            lastActivityAt: activity
        )
        let ws = Self.makeWorkspace(
            id: Self.ws1ID, name: "alpha", labels: ["1d", "review"],
            panes: [pane], createdAt: created, lastAccessedAt: accessed
        )
        let store = makeStore(
            workspaces: [ws],
            topLevelOrder: [.workspace(Self.ws1ID)],
            activeWorkspaceID: Self.ws1ID
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceList(group: nil), reply: makeCaptureHandle(sink)))

        #expect(sink.payloads.count == 1)
        #expect(sink.closedCount == 1)
        let list = sink.payloads[0]["workspaces"] as? [[String: Any]]
        #expect(list?.count == 1)
        let entry = list?.first
        #expect(entry?["labels"] as? [String] == ["1d", "review"])
        #expect(entry?["agent_session_id"] as? String == "sess-abc")

        let iso = ISO8601DateFormatter()
        #expect(entry?["created_at"] as? String == iso.string(from: created))
        #expect(entry?["last_accessed_at"] as? String == iso.string(from: accessed))
        #expect(entry?["last_activity_at"] as? String == iso.string(from: activity))
    }

    @Test func workspaceListLastActivityIsMaxAcrossPanes() async {
        let older = Date(timeIntervalSince1970: 4000)
        let newer = Date(timeIntervalSince1970: 9000)
        let ws = Self.makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [
                Pane(id: UUID(), lastActivityAt: older),
                Pane(id: UUID(), lastActivityAt: newer)
            ]
        )
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceList(group: nil), reply: makeCaptureHandle(sink)))
        let entry = (sink.payloads[0]["workspaces"] as? [[String: Any]])?.first
        let iso = ISO8601DateFormatter()
        #expect(entry?["last_activity_at"] as? String == iso.string(from: newer))
    }

    @Test func workspaceListEmptyWorkspaceOmitsActivityAndSession() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [])
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceList(group: nil), reply: makeCaptureHandle(sink)))
        let entry = (sink.payloads[0]["workspaces"] as? [[String: Any]])?.first
        #expect(entry?["last_activity_at"] == nil)
        #expect(entry?["agent_session_id"] == nil)
        // Labels always present (empty array), even with no panes.
        #expect(entry?["labels"] as? [String] == [])
    }

    // MARK: - workspace-list --group filter

    @Test func workspaceListGroupFilterRestrictsToMembers() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "in-group")
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "top-level")
        let group = WorkspaceGroup(id: Self.groupID, name: "Reviews", childOrder: [Self.ws1ID])
        let store = makeStore(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.group(Self.groupID), .workspace(Self.ws2ID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceList(group: "Reviews"), reply: makeCaptureHandle(sink)))
        let list = sink.payloads[0]["workspaces"] as? [[String: Any]]
        #expect(list?.count == 1)
        #expect(list?.first?["id"] as? String == Self.ws1ID.uuidString)
    }

    @Test func workspaceListEmptyGroupReturnsEmptyList() async {
        // The design boundary: an empty group is `ok:true, workspaces:[]`,
        // distinct from the unknown-group error below.
        let group = WorkspaceGroup(id: Self.groupID, name: "Reviews", childOrder: [])
        let store = makeStore(groups: [group], topLevelOrder: [.group(Self.groupID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceList(group: "Reviews"), reply: makeCaptureHandle(sink)))
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect((sink.payloads[0]["workspaces"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func workspaceListUnknownGroupFails() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "alpha")
        let store = makeStore(workspaces: [ws1], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceList(group: "ghost"), reply: makeCaptureHandle(sink)))
        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("ghost") == true)
    }

    // MARK: - workspace-label

    @Test func labelSetReplacesAll() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha", labels: ["old"])
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "set", values: ["3d", "review"]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["labels"] as? [String] == ["3d", "review"])
        #expect(store.state.workspaces[id: Self.ws1ID]?.labels == ["3d", "review"])
    }

    @Test func labelAddPreservesExistingAndDedupes() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha", labels: ["1d"])
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "add", values: ["1d", "hot"]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(store.state.workspaces[id: Self.ws1ID]?.labels == ["1d", "hot"])
    }

    @Test func labelRemoveDropsValue() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha", labels: ["1d", "hot"])
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "remove", values: ["hot"]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(store.state.workspaces[id: Self.ws1ID]?.labels == ["1d"])
    }

    @Test func labelClearEmptiesLabels() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha", labels: ["1d", "hot"])
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "clear", values: []),
            reply: makeCaptureHandle(sink)
        ))
        #expect(sink.payloads[0]["labels"] as? [String] == [])
        #expect(store.state.workspaces[id: Self.ws1ID]?.labels == [])
    }

    @Test func labelAddCreatesBackingPreset() async {
        // A CLI-introduced label must get a gray, recolorable preset so it's
        // not orphaned (invisible/unmanaged in Settings ▸ Labels).
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha")
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "add", values: ["1d"]),
            reply: makeCaptureHandle(sink)
        ))
        await store.receive(\.presets.addLabelPreset)
        #expect(store.state.presets.labelPresets.contains {
            $0.name == "1d" && $0.color == .named(.gray)
        })
    }

    @Test func labelAddKeepsExistingPresetColor() async {
        // An existing preset (user-colored) must not be recolored to gray
        // when the same label is applied from the CLI.
        var appStateWs = Self.makeWorkspace(id: Self.ws1ID, name: "alpha")
        appStateWs.labels = []
        let store = makeStore(workspaces: [appStateWs], topLevelOrder: [.workspace(Self.ws1ID)])
        store.exhaustivity = .off(showSkippedAssertions: false)
        // Seed a blue preset for "hot".
        await store.send(.presets(.addLabelPreset(name: "hot", color: .named(.blue))))

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "add", values: ["hot"]),
            reply: makeCaptureHandle(sink)
        ))
        await store.receive(\.presets.addLabelPreset)
        // Still blue — addLabelPreset is a no-op for an existing name.
        #expect(store.state.presets.labelPresets.filter { $0.name == "hot" }
            == [LabelPreset(name: "hot", color: .named(.blue))])
    }

    @Test func labelRemoveKeepsPreset() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha", labels: ["hot"])
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])
        await store.send(.presets(.addLabelPreset(name: "hot", color: .named(.blue))))

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "remove", values: ["hot"]),
            reply: makeCaptureHandle(sink)
        ))
        // Preset survives even though no workspace uses the label now.
        #expect(store.state.presets.labelPresets.contains { $0.name == "hot" })
        #expect(store.state.workspaces[id: Self.ws1ID]?.labels == [])
    }

    @Test func labelSetAllWhitespaceFails() async {
        // `--set "  "` must not masquerade as a clear (that's what --clear
        // is for); it's rejected and the labels stay put.
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha", labels: ["keep"])
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "alpha", op: "set", values: ["   "]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect(store.state.workspaces[id: Self.ws1ID]?.labels == ["keep"])
    }

    @Test func labelUnknownWorkspaceFails() async {
        let ws = Self.makeWorkspace(id: Self.ws1ID, name: "alpha")
        let store = makeStore(workspaces: [ws], topLevelOrder: [.workspace(Self.ws1ID)])

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceLabel(nameOrID: "ghost", op: "set", values: ["x"]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(sink.payloads[0]["ok"] as? Bool == false)
    }

    // MARK: - group-reorder

    @Test func groupReorderExplicitRewritesChildOrder() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "a")
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "b")
        let ws3 = Self.makeWorkspace(id: Self.ws3ID, name: "c")
        let group = WorkspaceGroup(
            id: Self.groupID, name: "Reviews",
            childOrder: [Self.ws1ID, Self.ws2ID, Self.ws3ID]
        )
        let store = makeStore(
            workspaces: [ws1, ws2, ws3], groups: [group],
            topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupReorder(nameOrID: "Reviews", order: [Self.ws3ID.uuidString, Self.ws1ID.uuidString]),
            reply: makeCaptureHandle(sink)
        ))
        // ws3, ws1 first (as listed); ws2 (omitted) keeps its relative slot at tail.
        #expect(store.state.groups[id: Self.groupID]?.childOrder == [Self.ws3ID, Self.ws1ID, Self.ws2ID])
        #expect(sink.payloads[0]["order"] as? [String]
            == [Self.ws3ID.uuidString, Self.ws1ID.uuidString, Self.ws2ID.uuidString])
    }

    @Test func groupReorderRejectsNonMember() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "a")
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "outsider")
        let group = WorkspaceGroup(id: Self.groupID, name: "Reviews", childOrder: [Self.ws1ID])
        let store = makeStore(
            workspaces: [ws1, ws2], groups: [group],
            topLevelOrder: [.group(Self.groupID), .workspace(Self.ws2ID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupReorder(nameOrID: "Reviews", order: [Self.ws2ID.uuidString]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect(store.state.groups[id: Self.groupID]?.childOrder == [Self.ws1ID])
    }

    @Test func groupReorderRejectsDuplicate() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "a")
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "b")
        let group = WorkspaceGroup(
            id: Self.groupID, name: "Reviews", childOrder: [Self.ws1ID, Self.ws2ID]
        )
        let store = makeStore(
            workspaces: [ws1, ws2], groups: [group], topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupReorder(nameOrID: "Reviews", order: [Self.ws1ID.uuidString, Self.ws1ID.uuidString]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(sink.payloads[0]["ok"] as? Bool == false)
    }

    @Test func groupReorderPreservesStaleMemberAtTail() async {
        // A childOrder id whose workspace was deleted must survive (at the
        // tail) rather than being dropped, and must not appear in the reply.
        let staleID = UUID(uuidString: "A0000000-0000-0000-0000-0000000000FF")!
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "a")
        let group = WorkspaceGroup(
            id: Self.groupID, name: "Reviews", childOrder: [Self.ws1ID, staleID]
        )
        let store = makeStore(
            workspaces: [ws1], groups: [group], topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupReorder(nameOrID: "Reviews", order: [Self.ws1ID.uuidString]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(store.state.groups[id: Self.groupID]?.childOrder == [Self.ws1ID, staleID])
        #expect(sink.payloads[0]["order"] as? [String] == [Self.ws1ID.uuidString])
    }

    @Test func groupReorderResolvesMemberByName() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "alpha")
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "beta")
        let group = WorkspaceGroup(
            id: Self.groupID, name: "Reviews", childOrder: [Self.ws1ID, Self.ws2ID]
        )
        let store = makeStore(
            workspaces: [ws1, ws2], groups: [group], topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupReorder(nameOrID: "Reviews", order: ["beta", "alpha"]),
            reply: makeCaptureHandle(sink)
        ))
        #expect(store.state.groups[id: Self.groupID]?.childOrder == [Self.ws2ID, Self.ws1ID])
    }

    // MARK: - group-sort

    @Test func groupSortByNameAscending() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "charlie")
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "alpha")
        let ws3 = Self.makeWorkspace(id: Self.ws3ID, name: "bravo")
        let group = WorkspaceGroup(
            id: Self.groupID, name: "Reviews",
            childOrder: [Self.ws1ID, Self.ws2ID, Self.ws3ID]
        )
        let store = makeStore(
            workspaces: [ws1, ws2, ws3], groups: [group], topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupSort(nameOrID: "Reviews", by: "name", descending: false),
            reply: makeCaptureHandle(sink)
        ))
        #expect(store.state.groups[id: Self.groupID]?.childOrder == [Self.ws2ID, Self.ws3ID, Self.ws1ID])
    }

    @Test func groupSortByLastActivityDescending() async {
        let ws1 = Self.makeWorkspace(
            id: Self.ws1ID, name: "a",
            panes: [Pane(id: UUID(), lastActivityAt: Date(timeIntervalSince1970: 1000))]
        )
        let ws2 = Self.makeWorkspace(
            id: Self.ws2ID, name: "b",
            panes: [Pane(id: UUID(), lastActivityAt: Date(timeIntervalSince1970: 9000))]
        )
        let ws3 = Self.makeWorkspace(
            id: Self.ws3ID, name: "c",
            panes: [Pane(id: UUID(), lastActivityAt: Date(timeIntervalSince1970: 5000))]
        )
        let group = WorkspaceGroup(
            id: Self.groupID, name: "Reviews",
            childOrder: [Self.ws1ID, Self.ws2ID, Self.ws3ID]
        )
        let store = makeStore(
            workspaces: [ws1, ws2, ws3], groups: [group], topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupSort(nameOrID: "Reviews", by: "last-activity", descending: true),
            reply: makeCaptureHandle(sink)
        ))
        // Most recently active first: ws2 (9000), ws3 (5000), ws1 (1000).
        #expect(store.state.groups[id: Self.groupID]?.childOrder == [Self.ws2ID, Self.ws3ID, Self.ws1ID])
    }

    @Test func groupSortDescendingKeepsTieOrderStable() async {
        // Equal keys under --desc must keep their prior relative order
        // (a whole-array reverse would flip them).
        let tie = Date(timeIntervalSince1970: 7000)
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "a", lastAccessedAt: tie)
        let ws2 = Self.makeWorkspace(id: Self.ws2ID, name: "b", lastAccessedAt: tie)
        let ws3 = Self.makeWorkspace(
            id: Self.ws3ID, name: "c", lastAccessedAt: Date(timeIntervalSince1970: 9000)
        )
        let group = WorkspaceGroup(
            id: Self.groupID, name: "Reviews",
            childOrder: [Self.ws1ID, Self.ws2ID, Self.ws3ID]
        )
        let store = makeStore(
            workspaces: [ws1, ws2, ws3], groups: [group], topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupSort(nameOrID: "Reviews", by: "last-accessed", descending: true),
            reply: makeCaptureHandle(sink)
        ))
        // ws3 (9000) first; the ws1/ws2 tie keeps its original [ws1, ws2] order.
        #expect(store.state.groups[id: Self.groupID]?.childOrder == [Self.ws3ID, Self.ws1ID, Self.ws2ID])
    }

    @Test func groupSortUnknownKeyFails() async {
        let ws1 = Self.makeWorkspace(id: Self.ws1ID, name: "a")
        let group = WorkspaceGroup(id: Self.groupID, name: "Reviews", childOrder: [Self.ws1ID])
        let store = makeStore(
            workspaces: [ws1], groups: [group], topLevelOrder: [.group(Self.groupID)]
        )

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .groupSort(nameOrID: "Reviews", by: "bogus", descending: false),
            reply: makeCaptureHandle(sink)
        ))
        #expect(sink.payloads[0]["ok"] as? Bool == false)
    }

    // MARK: - parse round-trips

    @Test func parseWorkspaceLabel() {
        let data = Data("""
        {"command":"workspace-label","name":"alpha","label_op":"add","label_values":["1d"]}
        """.utf8)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceLabel(nameOrID: "alpha", op: "add", values: ["1d"]))
    }

    @Test func parseGroupReorder() {
        let data = Data("""
        {"command":"group-reorder","name":"Reviews","order":["x","y"]}
        """.utf8)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .groupReorder(nameOrID: "Reviews", order: ["x", "y"]))
    }

    @Test func parseGroupSort() {
        let data = Data("""
        {"command":"group-sort","name":"Reviews","by":"name","descending":true}
        """.utf8)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .groupSort(nameOrID: "Reviews", by: "name", descending: true))
    }

    @Test func parseWorkspaceListWithGroup() {
        let data = Data("""
        {"command":"workspace-list","group":"Reviews"}
        """.utf8)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceList(group: "Reviews"))
    }
}
