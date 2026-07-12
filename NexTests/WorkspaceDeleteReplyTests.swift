import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the `workspace-delete` request/response path through the
/// reducer (issues #226 / #234). Mirrors `PaneCloseReplyTests` — the
/// JSON reply is captured via a closure-backed `SocketServer.ReplyHandle`
/// stub; no real socket is involved. Covers:
///   - success payload shape (resolve by name and by UUID)
///   - the `path` field (present for a workspace with panes, absent for
///     an empty one) that backs `--prune-worktree`
///   - unknown / ambiguous name failure
///   - the last-workspace refusal that matches the GUI's disabled Delete
///   - the running-agents guard: refused without --force, bypassed with it
///   - the bulk invariant: sequential deletes can drain down to — but
///     never past — the final workspace
///   - the legacy fire-and-forget path (reply == nil) still dispatches
@MainActor
struct WorkspaceDeleteReplyTests {
    private static let ws1ID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private static let ws2ID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    private static let pane1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private static let pane2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    private static let pane3 = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

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

    @Test func deleteByNameRepliesOkAndDispatches() async {
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, workingDirectory: "/tmp/wt/alpha")]
        )
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: makeCaptureHandle(sink)))
        await store.receive(.deleteWorkspace(Self.ws1ID))

        #expect(sink.payloads.count == 1)
        #expect(sink.closedCount == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["workspace_id"] as? String == Self.ws1ID.uuidString)
        #expect(sink.payloads[0]["workspace_name"] as? String == "alpha")
        #expect(sink.payloads[0]["path"] as? String == "/tmp/wt/alpha")
    }

    @Test func deleteByUUIDRepliesOk() async {
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .workspaceDelete(nameOrID: Self.ws2ID.uuidString, force: false), reply: makeCaptureHandle(sink)
        ))
        await store.receive(.deleteWorkspace(Self.ws2ID))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["workspace_id"] as? String == Self.ws2ID.uuidString)
    }

    @Test func deleteEmptyWorkspaceOmitsPath() async {
        // Issue #226's headline case: a workspace whose panes were all
        // closed. It has no working directory, so the reply carries no
        // `path` and `--prune-worktree` cannot reclaim the worktree.
        let empty = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [])
        let other = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [empty, other], activeWorkspaceID: Self.ws2ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: makeCaptureHandle(sink)))
        await store.receive(.deleteWorkspace(Self.ws1ID))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["path"] == nil)
    }

    // MARK: - Error paths

    @Test func deleteUnknownWorkspaceFails() async {
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "ghost", force: false), reply: makeCaptureHandle(sink)))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("ghost") == true)
        #expect(sink.closedCount == 1)
        // Both workspaces untouched.
        #expect(store.state.workspaces.count == 2)
    }

    @Test func deleteAmbiguousNameFails() async {
        // Two workspaces share a name — `resolveWorkspace` returns nil
        // for a non-unique name, so the delete is rejected rather than
        // guessing which one.
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "dup", panes: [Pane(id: Self.pane1)])
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "dup", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "dup", force: false), reply: makeCaptureHandle(sink)))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("ambiguous") == true)
        #expect(store.state.workspaces.count == 2)
    }

    @Test func deleteLastWorkspaceRefused() async {
        // Mirrors the GUI's `.disabled(store.workspaces.count <= 1)`:
        // the app always keeps at least one workspace.
        let only = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let store = makeStore(workspaces: [only], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: makeCaptureHandle(sink)))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("last workspace") == true)
        #expect(sink.closedCount == 1)
        #expect(store.state.workspaces[id: Self.ws1ID] != nil)
    }

    // MARK: - Running-agents guard

    @Test func deleteWithActiveAgentRefusedWithoutForce() async {
        // A workspace with a running agent must not be deleted without
        // --force (mirrors the app-quit warning). Two agents → plural
        // count in the reply.
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [
                Pane(id: Self.pane1, status: .running),
                Pane(id: Self.pane2, status: .waitingForInput)
            ]
        )
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane3)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: makeCaptureHandle(sink)))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("running") == true)
        #expect((sink.payloads[0]["error"] as? String)?.contains("--force") == true)
        #expect(sink.payloads[0]["active_agents"] as? Int == 2)
        #expect(sink.closedCount == 1)
        // Workspace untouched.
        #expect(store.state.workspaces[id: Self.ws1ID] != nil)
    }

    @Test func deleteWithActiveAgentForcedSucceeds() async {
        // --force bypasses the running-agents guard.
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, status: .running)]
        )
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: true), reply: makeCaptureHandle(sink)))
        await store.receive(.deleteWorkspace(Self.ws1ID))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
    }

    @Test func deleteWithOnlyIdlePanesSucceedsWithoutForce() async {
        // Idle panes are not "active agents" — no --force needed.
        let ws1 = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, status: .idle)]
        )
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: makeCaptureHandle(sink)))
        await store.receive(.deleteWorkspace(Self.ws1ID))

        #expect(sink.payloads[0]["ok"] as? Bool == true)
    }

    // MARK: - Bulk invariant

    @Test func sequentialDeletesRefuseFinalWorkspace() async {
        // `nex workspace delete a b` loops one request per id. Deleting
        // the first must succeed; the second, now the last workspace,
        // must be refused — the batch can never leave zero workspaces.
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        let sink1 = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: makeCaptureHandle(sink1)))
        await store.receive(.deleteWorkspace(Self.ws1ID))
        #expect(sink1.payloads[0]["ok"] as? Bool == true)
        #expect(store.state.workspaces.count == 1)

        let sink2 = CaptureSink()
        await store.send(.socketMessage(.workspaceDelete(nameOrID: "beta", force: false), reply: makeCaptureHandle(sink2)))
        #expect(sink2.payloads[0]["ok"] as? Bool == false)
        #expect((sink2.payloads[0]["error"] as? String)?.contains("last workspace") == true)
        #expect(store.state.workspaces[id: Self.ws2ID] != nil)
    }

    // MARK: - Legacy fire-and-forget path

    @Test func deleteWithoutReplyStillDispatches() async {
        let ws1 = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let ws2 = makeWorkspace(id: Self.ws2ID, name: "beta", panes: [Pane(id: Self.pane2)])
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.ws1ID)

        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: nil))
        await store.receive(.deleteWorkspace(Self.ws1ID))
    }

    @Test func deleteLastWorkspaceWithoutReplyIsNoOp() async {
        // Legacy path must still honour the last-workspace guard.
        let only = makeWorkspace(id: Self.ws1ID, name: "alpha", panes: [Pane(id: Self.pane1)])
        let store = makeStore(workspaces: [only], activeWorkspaceID: Self.ws1ID)

        await store.send(.socketMessage(.workspaceDelete(nameOrID: "alpha", force: false), reply: nil))
        #expect(store.state.workspaces[id: Self.ws1ID] != nil)
    }
}

/// Wire-parse coverage for `workspace-delete`: a non-empty `name`
/// yields the `.workspaceDelete` message; a missing/empty name is
/// rejected (nil) so the server never dispatches a nameless delete.
struct WorkspaceDeleteParsingTests {
    private static func parseFirst(_ json: String) -> SocketMessage? {
        SocketServer.parseWireMessage(Data(json.utf8))?.0
    }

    @Test("workspace-delete: accepted with name")
    func acceptedWithName() {
        #expect(Self.parseFirst(#"{"command":"workspace-delete","name":"alpha"}"#)
            == .workspaceDelete(nameOrID: "alpha", force: false))
    }

    @Test("workspace-delete: accepted with UUID name")
    func acceptedWithUUID() {
        let id = "70000000-0000-0000-0000-000000000001"
        #expect(Self.parseFirst(#"{"command":"workspace-delete","name":"\#(id)"}"#)
            == .workspaceDelete(nameOrID: id, force: false))
    }

    @Test("workspace-delete: force flag decoded")
    func forceDecoded() {
        #expect(Self.parseFirst(#"{"command":"workspace-delete","name":"alpha","force":true}"#)
            == .workspaceDelete(nameOrID: "alpha", force: true))
        // Absent force defaults to false.
        #expect(Self.parseFirst(#"{"command":"workspace-delete","name":"alpha"}"#)
            == .workspaceDelete(nameOrID: "alpha", force: false))
    }

    @Test("workspace-delete: rejected with missing name")
    func rejectedMissingName() {
        #expect(Self.parseFirst(#"{"command":"workspace-delete"}"#) == nil)
    }

    @Test("workspace-delete: rejected with empty name")
    func rejectedEmptyName() {
        #expect(Self.parseFirst(#"{"command":"workspace-delete","name":""}"#) == nil)
    }
}
