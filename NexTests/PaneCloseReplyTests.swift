import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the `pane-close` request/response path through the
/// reducer. Mirrors `PaneListTests` — captures the JSON reply via a
/// closure-backed `SocketServer.ReplyHandle` stub. No real socket is
/// involved. Covers:
///   - success payload shape
///   - unknown UUID / unknown label
///   - ambiguous label across workspaces (advises `--workspace`)
///   - `--workspace` scoping (resolves collisions, rejects cross-scope UUIDs)
///   - legacy fire-and-forget path (reply == nil) still dispatches the close
@MainActor
struct PaneCloseReplyTests {
    private static let ws1ID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
    private static let ws2ID = UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
    private static let pane1 = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
    private static let pane2 = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!
    private static let pane3 = UUID(uuidString: "00000000-0000-0000-0000-00000000B003")!

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
        panes: [Pane]
    ) -> WorkspaceFeature.State {
        let paneIDs = panes.map(\.id)
        var layout: PaneLayout = paneIDs.isEmpty ? .empty : .leaf(paneIDs[0])
        for pid in paneIDs.dropFirst() {
            layout = layout.splitting(
                paneID: paneIDs[0], direction: .horizontal, newPaneID: pid
            ).layout
        }
        return WorkspaceFeature.State(
            id: id, name: name, slug: name.lowercased(), color: .blue,
            panes: IdentifiedArrayOf(uniqueElements: panes),
            layout: layout,
            focusedPaneID: paneIDs.first,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    // MARK: - Success paths

    @Test func closeByTargetLabelRepliesOkAndClosesPane() async {
        // Caller is inside `pane2` (origin) and closes `pane1` by
        // label. Origin scope is implicit via paneID.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker"), Pane(id: Self.pane2, label: "other")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: Self.pane2, target: "worker", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))
        await store.receive(.workspaces(.element(
            id: Self.ws1ID, action: .closePane(Self.pane1)
        )))

        #expect(sink.payloads.count == 1)
        #expect(sink.closedCount == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["pane_id"] as? String == Self.pane1.uuidString)
        #expect(sink.payloads[0]["workspace_id"] as? String == Self.ws1ID.uuidString)
        #expect(sink.payloads[0]["workspace_name"] as? String == "alpha")
        #expect(sink.payloads[0]["label"] as? String == "worker")
    }

    @Test func closeByLabelOutsideNexRequiresWorkspaceFlag() async {
        // `paneID == nil` simulates a caller without NEX_PANE_ID set.
        // A bare label has no implicit scope and no global fallback —
        // the request must specify `--workspace`.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: "worker", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("--workspace") == true)
        // Pane untouched.
        #expect(store.state.workspaces[id: Self.ws1ID]?.panes[id: Self.pane1] != nil)
    }

    @Test func closeByPaneIDRepliesOk() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1), Pane(id: Self.pane2)]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: Self.pane1, target: nil, workspace: nil),
            reply: makeCaptureHandle(sink)
        ))
        await store.receive(.workspaces(.element(
            id: Self.ws1ID, action: .closePane(Self.pane1)
        )))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["pane_id"] as? String == Self.pane1.uuidString)
    }

    // MARK: - --workspace scoping

    @Test func closeByLabelWithWorkspaceResolvesCollision() async {
        // Both workspaces have a pane labelled "worker". Without
        // --workspace this is ambiguous; with --workspace it picks the
        // one in that workspace.
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane2, label: "worker")]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: "worker", workspace: "beta"),
            reply: makeCaptureHandle(sink)
        ))
        await store.receive(.workspaces(.element(
            id: Self.ws2ID, action: .closePane(Self.pane2)
        )))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["pane_id"] as? String == Self.pane2.uuidString)
        #expect(sink.payloads[0]["workspace_id"] as? String == Self.ws2ID.uuidString)
    }

    @Test func closeByLabelWithWorkspaceUUIDResolves() async {
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane2, label: "worker")]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: "worker", workspace: Self.ws2ID.uuidString),
            reply: makeCaptureHandle(sink)
        ))
        await store.receive(.workspaces(.element(
            id: Self.ws2ID, action: .closePane(Self.pane2)
        )))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
    }

    @Test func closeWithUnknownWorkspaceFails() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: "worker", workspace: "ghost"),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("workspace not found") == true)
        #expect(sink.closedCount == 1)
        // Original pane still there.
        #expect(store.state.workspaces[id: Self.ws1ID]?.panes[id: Self.pane1] != nil)
    }

    @Test func closeWithWorkspaceMismatchFails() async {
        // Target UUID is real but lives in a different workspace than
        // the one --workspace asks for.
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "a")]
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane2, label: "b")]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: Self.pane1.uuidString, workspace: "beta"),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("beta") == true)
        #expect(store.state.workspaces[id: Self.ws1ID]?.panes[id: Self.pane1] != nil)
    }

    // MARK: - Error paths

    @Test func closeByAmbiguousLabelFailsWithAdvice() async {
        // Two panes with the same label in the origin workspace —
        // origin scope can't disambiguate, so the error should mention
        // `--workspace`.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [
                Pane(id: Self.pane1, label: "worker"),
                Pane(id: Self.pane2, label: "worker"),
                Pane(id: Self.pane3)
            ]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: Self.pane3, target: "worker", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let error = sink.payloads[0]["error"] as? String ?? ""
        #expect(error.contains("ambiguous"))
        #expect(error.contains("--workspace"))
        // Both labelled panes still there.
        #expect(store.state.workspaces[id: Self.ws1ID]?.panes[id: Self.pane1] != nil)
        #expect(store.state.workspaces[id: Self.ws1ID]?.panes[id: Self.pane2] != nil)
    }

    @Test func closeByUnknownLabelFails() async {
        // Origin pane in alpha; label doesn't exist there.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: Self.pane1, target: "ghost", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("ghost") == true)
    }

    @Test func closeByUnknownUUIDFails() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1)]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        let ghost = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: ghost.uuidString, workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("UUID") == true)
    }

    @Test func closeFromOriginInOtherWorkspaceFailsWithAdvice() async {
        // Issue #92 contract: when an origin pane is set, label lookup
        // is scoped to the origin's workspace by default. A label that
        // exists only in another workspace must NOT silently route.
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1)]
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane2, label: "worker")]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: Self.pane1, target: "worker", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let error = sink.payloads[0]["error"] as? String ?? ""
        #expect(error.contains("alpha"))
        #expect(error.contains("--workspace"))
        // Beta's pane is untouched.
        #expect(store.state.workspaces[id: Self.ws2ID]?.panes[id: Self.pane2] != nil)
    }

    @Test func closeWithPaneIDOnlyUnknownFails() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1)]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneClose(paneID: Self.pane3, target: nil, workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
    }

    // MARK: - Legacy fire-and-forget path

    @Test func closeWithoutReplyStillDispatches() async {
        // Older CLI builds don't wait for a response — the reducer
        // must still perform the close when `reply` is nil.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1), Pane(id: Self.pane2)]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        await store.send(.socketMessage(
            .paneClose(paneID: Self.pane1, target: nil, workspace: nil),
            reply: nil
        ))
        await store.receive(.workspaces(.element(
            id: Self.ws1ID, action: .closePane(Self.pane1)
        )))
    }
}
