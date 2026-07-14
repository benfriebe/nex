import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Tests for the `pane-move-adjacent` request/response handler (issue
/// #241) — the CLI form of GUI drag-and-drop. Drives `handlePaneMoveAdjacent`
/// directly with a captured `ReplyHandle` and asserts the structured JSON
/// reply plus target/anchor resolution and the error paths. The layout
/// transform itself is delegated to the already-tested
/// `PaneLayout.movingPane(_:toAdjacentOf:zone:)` via a dispatched
/// `movePane` action, so these tests focus on the handler's own logic.
@MainActor
struct PaneMoveAdjacentReplyTests {
    static let coordinator = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let worker = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let extra = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let other = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let ws1 = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let ws2 = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    /// - ws1 "alpha": coordinator | (worker / extra)
    /// - ws2 "beta": a single pane "other"
    static func makeState() -> AppReducer.State {
        let epoch = Date(timeIntervalSince1970: 1000)
        let ws1State = WorkspaceFeature.State(
            id: ws1, name: "alpha", slug: "alpha", color: .blue,
            panes: [
                Pane(id: coordinator, label: "coordinator"),
                Pane(id: worker, label: "worker"),
                Pane(id: extra, label: "extra")
            ],
            layout: .split(
                .horizontal, ratio: 0.5,
                first: .leaf(coordinator),
                second: .split(.vertical, ratio: 0.5, first: .leaf(worker), second: .leaf(extra))
            ),
            focusedPaneID: coordinator,
            createdAt: epoch,
            lastAccessedAt: epoch
        )
        let ws2State = WorkspaceFeature.State(
            id: ws2, name: "beta", slug: "beta", color: .green,
            panes: [Pane(id: other, label: "other")],
            layout: .leaf(other),
            focusedPaneID: other,
            createdAt: epoch,
            lastAccessedAt: epoch
        )
        var state = AppReducer.State()
        state.workspaces = [ws1State, ws2State]
        return state
    }

    final class ReplyRecorder: @unchecked Sendable {
        private(set) var sent: [[String: Any]] = []
        private(set) var closeCount = 0
        func handle() -> SocketServer.ReplyHandle {
            SocketServer.ReplyHandle(
                id: 1,
                send: { [weak self] json in self?.sent.append(json) },
                close: { [weak self] in self?.closeCount += 1 }
            )
        }
    }

    @Test("move-adjacent: UUID target + anchor docks and echoes the reply")
    func uuidTargetAnchor() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneMoveAdjacent(
            state: &state, paneID: nil, target: Self.extra.uuidString,
            anchor: Self.coordinator.uuidString, zone: .bottom,
            workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["pane_id"] as? String) == Self.extra.uuidString)
        #expect((rec.sent[0]["anchor_id"] as? String) == Self.coordinator.uuidString)
        #expect((rec.sent[0]["zone"] as? String) == "below")
        #expect((rec.sent[0]["workspace_name"] as? String) == "alpha")
        #expect((rec.sent[0]["label"] as? String) == "extra")
        #expect(rec.closeCount == 1)
    }

    @Test("move-adjacent: label target + anchor resolves within the workspace")
    func labelTargetAnchor() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneMoveAdjacent(
            state: &state, paneID: Self.coordinator, target: "worker",
            anchor: "coordinator", zone: .right,
            workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["pane_id"] as? String) == Self.worker.uuidString)
        #expect((rec.sent[0]["anchor_id"] as? String) == Self.coordinator.uuidString)
        #expect((rec.sent[0]["zone"] as? String) == "right-of")
    }

    @Test("move-adjacent: an anchor in another workspace is rejected")
    func anchorCrossWorkspaceRejected() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneMoveAdjacent(
            state: &state, paneID: nil, target: Self.worker.uuidString,
            anchor: Self.other.uuidString, zone: .bottom,
            workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
    }

    @Test("move-adjacent: an unknown anchor is rejected")
    func unknownAnchorRejected() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneMoveAdjacent(
            state: &state, paneID: nil, target: Self.worker.uuidString,
            anchor: "nope", zone: .bottom,
            workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
    }

    @Test("move-adjacent: moving a pane adjacent to itself is rejected")
    func selfMoveRejected() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneMoveAdjacent(
            state: &state, paneID: nil, target: Self.worker.uuidString,
            anchor: Self.worker.uuidString, zone: .bottom,
            workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
    }
}
