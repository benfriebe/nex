import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the `pane-send` request/response path through the
/// reducer. Covers issue #92: label resolution must be scoped to the
/// sender's workspace by default; cross-workspace targeting requires
/// `--workspace`. Also covers the legacy fire-and-forget path
/// (reply == nil) so older CLIs keep working.
@MainActor
struct PaneSendReplyTests {
    private static let ws1ID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    private static let ws2ID = UUID(uuidString: "90000000-0000-0000-0000-000000000002")!
    private static let pane1 = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
    private static let pane2 = UUID(uuidString: "00000000-0000-0000-0000-00000000C002")!
    private static let pane3 = UUID(uuidString: "00000000-0000-0000-0000-00000000C003")!

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

    @Test func sendByLabelInSameWorkspaceRepliesOk() async {
        // Origin pane (pane1) in workspace alpha; label "worker" resolves
        // to pane2 in the same workspace. Should succeed.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1), Pane(id: Self.pane2, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane1, target: "worker", text: "echo", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads.count == 1)
        #expect(sink.closedCount == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["pane_id"] as? String == Self.pane2.uuidString)
        #expect(sink.payloads[0]["workspace_id"] as? String == Self.ws1ID.uuidString)
        #expect(sink.payloads[0]["workspace_name"] as? String == "alpha")
        #expect(sink.payloads[0]["label"] as? String == "worker")
    }

    @Test func sendByUUIDRepliesOk() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1), Pane(id: Self.pane2)]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane1, target: Self.pane2.uuidString, text: "echo", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["pane_id"] as? String == Self.pane2.uuidString)
    }

    // MARK: - Issue #92: scope-by-sender's-workspace

    @Test func sendToLabelOnlyInOtherWorkspaceFailsWithAdvice() async {
        // Origin in workspace alpha; the only pane labeled "worker" is
        // in workspace beta. Pre-fix this would silently route across
        // workspaces; post-fix it should return an error mentioning
        // --workspace.
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
            .paneSend(paneID: Self.pane1, target: "worker", text: "echo", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads.count == 1)
        #expect(sink.closedCount == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let error = sink.payloads[0]["error"] as? String ?? ""
        #expect(error.contains("no pane with label 'worker'"))
        #expect(error.contains("alpha"))
        #expect(error.contains("--workspace"))
    }

    @Test func sendToUnknownLabelFails() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1)]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane1, target: "ghost", text: "echo", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("ghost") == true)
    }

    @Test func sendToAmbiguousLabelInOriginWorkspaceFailsWithAdvice() async {
        // Two panes with the same label in the origin workspace. The
        // sender hasn't passed --workspace; ambiguity should surface.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [
                Pane(id: Self.pane1),
                Pane(id: Self.pane2, label: "worker"),
                Pane(id: Self.pane3, label: "worker")
            ]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane1, target: "worker", text: "echo", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let error = sink.payloads[0]["error"] as? String ?? ""
        #expect(error.contains("ambiguous"))
    }

    // MARK: - --workspace scoping

    @Test func sendWithWorkspaceResolvesCrossWorkspaceLabel() async {
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
            .paneSend(paneID: Self.pane1, target: "worker", text: "echo", workspace: "beta"),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["pane_id"] as? String == Self.pane2.uuidString)
        #expect(sink.payloads[0]["workspace_id"] as? String == Self.ws2ID.uuidString)
    }

    @Test func sendByUUIDInOtherWorkspaceFailsWhenScoped() async {
        // UUID target lives in beta but --workspace asks for alpha.
        // Mirrors `closeWithWorkspaceMismatchFails` for parity.
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
            .paneSend(paneID: Self.pane1, target: Self.pane2.uuidString, text: "echo", workspace: "alpha"),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("alpha") == true)
    }

    @Test func sendWithUnknownWorkspaceFails() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane1, target: "worker", text: "echo", workspace: "ghost"),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("workspace not found") == true)
    }

    // MARK: - Stale origin pane

    @Test func sendWithStaleOriginPaneFailsExplicitly() async {
        // A surviving shell may still have NEX_PANE_ID set after its
        // pane was closed. Falling through to a global lookup here
        // would re-introduce the silent-cross-workspace routing the
        // fix is meant to prevent — the reply must surface that the
        // origin is gone and point at --workspace.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane2, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane3, target: "worker", text: "echo", workspace: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let error = sink.payloads[0]["error"] as? String ?? ""
        #expect(error.contains("origin pane"))
        #expect(error.contains(Self.pane3.uuidString))
        #expect(error.contains("--workspace"))
        // The unrelated pane in alpha is untouched.
        #expect(store.state.workspaces[id: Self.ws1ID]?.panes[id: Self.pane2] != nil)
    }

    // MARK: - Legacy fire-and-forget path

    @Test func sendWithoutReplyOnSuccessStillDispatches() async {
        // Older CLI builds send pane-send fire-and-forget. The reducer
        // must still dispatch the surface command when reply is nil.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1), Pane(id: Self.pane2, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane1, target: "worker", text: "echo", workspace: nil),
            reply: nil
        ))
        // No payload to assert on; the meaningful contract is "no
        // crash + the surface-manager run effect was scheduled". The
        // surface manager is a no-op for unregistered panes, so we just
        // verify the call completes.
    }

    @Test func sendWithoutReplyOnErrorIsSilentNoOp() async {
        // Origin in alpha; label only exists in beta. Pre-fix this
        // would silently dispatch to beta's pane. Post-fix, with
        // reply == nil, the request should be silently dropped (no
        // crash, no cross-workspace dispatch).
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1)]
        )
        let ws2 = makeWorkspace(
            id: Self.ws2ID, name: "beta",
            panes: [Pane(id: Self.pane2, label: "worker")]
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        await store.send(.socketMessage(
            .paneSend(paneID: Self.pane1, target: "worker", text: "echo", workspace: nil),
            reply: nil
        ))
        // Both panes still exist; no exceptions.
        #expect(store.state.workspaces[id: Self.ws1ID]?.panes[id: Self.pane1] != nil)
        #expect(store.state.workspaces[id: Self.ws2ID]?.panes[id: Self.pane2] != nil)
    }
}
