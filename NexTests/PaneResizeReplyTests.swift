import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Tests for the `pane-resize` request/response handler (issue #241).
/// Drives `handlePaneResize` directly with a captured `ReplyHandle` and
/// asserts both the structured JSON reply and the resulting layout ratio.
///
/// The split ratio is always the *first* child's fraction, so a
/// second-child pane's requested share `s` is stored as `1 - s`. The
/// handler clamps the effective share to `[0.1, 0.9]`.
@MainActor
struct PaneResizeReplyTests {
    static let coordinator = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let worker = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let solo = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let ws1 = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let ws2 = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    /// - ws1 "alpha": coordinator (first) | worker (second), split 0.5.
    /// - ws2 "beta": a single-pane workspace (no sibling to resize against).
    static func makeState() -> AppReducer.State {
        let epoch = Date(timeIntervalSince1970: 1000)
        let ws1State = WorkspaceFeature.State(
            id: ws1, name: "alpha", slug: "alpha", color: .blue,
            panes: [Pane(id: coordinator, label: "coordinator"), Pane(id: worker, label: "worker")],
            layout: .split(.horizontal, ratio: 0.5, first: .leaf(coordinator), second: .leaf(worker)),
            focusedPaneID: coordinator,
            createdAt: epoch,
            lastAccessedAt: epoch
        )
        let ws2State = WorkspaceFeature.State(
            id: ws2, name: "beta", slug: "beta", color: .green,
            panes: [Pane(id: solo, label: "solo")],
            layout: .leaf(solo),
            focusedPaneID: solo,
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

    @Test("resize: first-child --ratio sets the split ratio directly")
    func ratioFirstChild() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneResize(
            state: &state, paneID: nil, target: Self.coordinator.uuidString,
            workspaceFilter: nil, ratio: 0.4, delta: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["split_path"] as? String) == "d")
        #expect((rec.sent[0]["ratio"] as? Double) == 0.4)
        #expect((rec.sent[0]["target_share"] as? Double) == 0.4)
        #expect((rec.sent[0]["label"] as? String) == "coordinator")
        // Layout actually updated.
        if case .split(_, let ratio, _, _) = state.workspaces[id: Self.ws1]!.layout {
            #expect(ratio == 0.4)
        } else {
            Issue.record("layout is not a split")
        }
        #expect(rec.closeCount == 1)
    }

    @Test("resize: second-child --ratio stores the complement")
    func ratioSecondChild() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneResize(
            state: &state, paneID: nil, target: Self.worker.uuidString,
            workspaceFilter: nil, ratio: 0.4, delta: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        // worker's requested 0.4 share → first-child ratio 0.6.
        #expect((rec.sent[0]["ratio"] as? Double) == 0.6)
        #expect((rec.sent[0]["target_share"] as? Double) == 0.4)
        if case .split(_, let ratio, _, _) = state.workspaces[id: Self.ws1]!.layout {
            #expect(ratio == 0.6)
        }
    }

    @Test("resize: --grow nudges the first child up by the delta")
    func growFirstChild() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneResize(
            state: &state, paneID: nil, target: Self.coordinator.uuidString,
            workspaceFilter: nil, ratio: nil, delta: 0.1, reply: rec.handle()
        )
        // 0.5 current share + 0.1 = 0.6.
        #expect((rec.sent[0]["ratio"] as? Double) == 0.6)
        #expect((rec.sent[0]["target_share"] as? Double) == 0.6)
    }

    @Test("resize: --shrink on the second child raises the stored ratio")
    func shrinkSecondChild() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneResize(
            state: &state, paneID: nil, target: Self.worker.uuidString,
            workspaceFilter: nil, ratio: nil, delta: -0.1, reply: rec.handle()
        )
        // worker's current share 0.5 - 0.1 = 0.4 → first-child ratio 0.6.
        #expect((rec.sent[0]["target_share"] as? Double) == 0.4)
        #expect((rec.sent[0]["ratio"] as? Double) == 0.6)
    }

    @Test("resize: an out-of-range ratio clamps to [0.1, 0.9]")
    func ratioClamps() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneResize(
            state: &state, paneID: nil, target: Self.coordinator.uuidString,
            workspaceFilter: nil, ratio: 0.98, delta: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["target_share"] as? Double) == 0.9)
        #expect((rec.sent[0]["ratio"] as? Double) == 0.9)
    }

    @Test("resize: a sole-leaf pane has no sibling and errors")
    func soleLeafErrors() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneResize(
            state: &state, paneID: Self.solo, target: nil,
            workspaceFilter: nil, ratio: 0.4, delta: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
        #expect(rec.closeCount == 1)
        // Layout untouched.
        #expect(state.workspaces[id: Self.ws2]?.layout == .leaf(Self.solo))
    }

    @Test("resize: an unknown target errors without mutating")
    func unknownTargetErrors() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneResize(
            state: &state, paneID: nil, target: UUID().uuidString,
            workspaceFilter: nil, ratio: 0.4, delta: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
        if case .split(_, let ratio, _, _) = state.workspaces[id: Self.ws1]!.layout {
            #expect(ratio == 0.5)
        }
    }
}
