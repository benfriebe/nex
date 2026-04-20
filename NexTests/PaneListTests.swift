import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the `pane-list` request/response path end-to-end through
/// the reducer. Uses a capture-reply fake `SocketServer.ReplyHandle`
/// (closure-backed) to observe the JSON payload the reducer writes,
/// then close-notifies. No real socket or dispatch source is involved.
@MainActor
struct PaneListTests {
    private static let ws1ID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private static let ws2ID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    private static let pane1 = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
    private static let pane2 = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
    private static let pane3 = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!

    /// Capture sink that collects every `send` and `close` call. Safe
    /// to share across the handle + test body because calls happen on
    /// the main actor via the TestStore.
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

    private func makeStore(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State>,
        activeWorkspaceID: UUID?
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.activeWorkspaceID = activeWorkspaceID
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

    private func makeWorkspace(
        id: UUID,
        name: String,
        panes: [Pane],
        focusedPaneID: UUID? = nil
    ) -> WorkspaceFeature.State {
        let paneIDs = panes.map(\.id)
        let layout: PaneLayout = paneIDs.isEmpty ? .empty : .leaf(paneIDs[0])
        // Naive nested split for test cases with >1 pane — good
        // enough for the layout.allPaneIDs walk the reducer uses.
        var finalLayout = layout
        for id in paneIDs.dropFirst() {
            finalLayout = finalLayout.splitting(
                paneID: paneIDs[0], direction: .horizontal, newPaneID: id
            ).layout
        }
        return WorkspaceFeature.State(
            id: id,
            name: name,
            slug: name.lowercased(),
            color: .blue,
            panes: IdentifiedArrayOf(uniqueElements: panes),
            layout: finalLayout,
            focusedPaneID: focusedPaneID ?? paneIDs.first,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    // MARK: - Success paths

    @Test func paneListAcrossAllWorkspacesIncludesEveryPane() async {
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [
                Pane(id: Self.pane1, label: "worker-1", workingDirectory: "/tmp/a", status: .running),
                Pane(id: Self.pane2, workingDirectory: "/tmp/b")
            ],
            focusedPaneID: Self.pane1
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane3, workingDirectory: "/tmp/c")]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        let handle = makeCaptureHandle(sink)

        await store.send(.socketMessage(
            .paneList(paneID: nil, workspace: nil, scope: nil),
            reply: handle
        ))

        #expect(sink.payloads.count == 1)
        #expect(sink.closedCount == 1)

        let payload = sink.payloads[0]
        #expect(payload["ok"] as? Bool == true)

        let panes = payload["panes"] as? [[String: Any]] ?? []
        #expect(panes.count == 3)
        let ids = panes.compactMap { $0["id"] as? String }
        #expect(ids.contains(Self.pane1.uuidString))
        #expect(ids.contains(Self.pane2.uuidString))
        #expect(ids.contains(Self.pane3.uuidString))

        // Focus + active workspace flags should reflect the input state.
        let pane1Entry = panes.first(where: { ($0["id"] as? String) == Self.pane1.uuidString })
        #expect(pane1Entry?["is_focused"] as? Bool == true)
        #expect(pane1Entry?["is_active_workspace"] as? Bool == true)

        let pane3Entry = panes.first(where: { ($0["id"] as? String) == Self.pane3.uuidString })
        #expect(pane3Entry?["is_active_workspace"] as? Bool == false)
    }

    @Test func paneListWorkspaceFilterByNameNarrowsResults() async {
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1)]
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane2)]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneList(paneID: nil, workspace: "beta", scope: nil),
            reply: makeCaptureHandle(sink)
        ))

        let panes = sink.payloads[0]["panes"] as? [[String: Any]] ?? []
        #expect(panes.count == 1)
        #expect((panes[0]["id"] as? String) == Self.pane2.uuidString)
        #expect((panes[0]["workspace_name"] as? String) == "beta")
    }

    @Test func paneListScopeCurrentReturnsOwningWorkspace() async {
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1), Pane(id: Self.pane2)]
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane3)]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws2ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneList(paneID: Self.pane1, workspace: nil, scope: "current"),
            reply: makeCaptureHandle(sink)
        ))

        let panes = sink.payloads[0]["panes"] as? [[String: Any]] ?? []
        // alpha has pane1 + pane2, beta is excluded.
        #expect(panes.count == 2)
        let ids = Set(panes.compactMap { $0["id"] as? String })
        #expect(ids == [Self.pane1.uuidString, Self.pane2.uuidString])
    }

    // MARK: - Error paths

    @Test func paneListWorkspaceNotFoundRepliesError() async {
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneList(paneID: nil, workspace: "missing", scope: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("missing") == true)
        #expect(sink.closedCount == 1)
    }

    @Test func paneListMutuallyExclusiveFiltersError() async {
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneList(paneID: Self.pane1, workspace: "alpha", scope: "current"),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect(sink.closedCount == 1)
    }

    @Test func paneListScopeCurrentWithUnknownPaneError() async {
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneList(paneID: Self.pane2, workspace: nil, scope: "current"),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect(sink.closedCount == 1)
    }

    // MARK: - Nil handle is a no-op

    @Test func paneListWithoutReplyIsNoOp() async {
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.ws1ID)

        // A well-formed .paneList without a reply handle should parse and
        // dispatch without crashing — the reducer silently drops it since
        // there's no one to answer.
        await store.send(.socketMessage(
            .paneList(paneID: nil, workspace: nil, scope: nil),
            reply: nil
        ))
    }
}
