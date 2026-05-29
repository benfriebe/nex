import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Tests for the outside-Nex `pane-split` / `pane-create` / `pane-name`
/// request/response handlers (issue #117). Drives the handlers directly
/// with a captured `ReplyHandle` so we can assert the structured JSON the
/// CLI sees, plus the state mutation for `pane name`.
///
/// `split` / `create` mint the new pane's UUID up front (controlled here
/// via `$0.uuid = .constant`) and thread it into the existing
/// `splitPane` / `splitPaneAtPath` / `createPane` actions through their
/// defaulted `newPaneID` parameter, so the reply returns `pane_id`.
@MainActor
struct PaneCommandReplyTests {
    static let pane1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let pane2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let pane3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let ws1 = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let ws2 = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    static let ws3 = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    /// The UUID the controlled `uuid` dependency mints for the new pane.
    static let newPane = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    /// - ws1 "alpha" with pane1 (label "worker") + pane3 (no label)
    /// - ws2 "beta" with pane2 (label "worker")
    /// - ws3 "gamma" empty (no panes) — exercises create-into-empty
    static func makeState() -> AppReducer.State {
        let epoch = Date(timeIntervalSince1970: 1000)
        let ws1State = WorkspaceFeature.State(
            id: ws1, name: "alpha", slug: "alpha", color: .blue,
            panes: [Pane(id: pane1, label: "worker"), Pane(id: pane3)],
            layout: .leaf(pane1),
            focusedPaneID: pane1,
            createdAt: epoch,
            lastAccessedAt: epoch
        )

        let ws2State = WorkspaceFeature.State(
            id: ws2, name: "beta", slug: "beta", color: .green,
            panes: [Pane(id: pane2, label: "worker")],
            layout: .leaf(pane2),
            focusedPaneID: pane2,
            createdAt: epoch,
            lastAccessedAt: epoch
        )

        let ws3State = WorkspaceFeature.State(
            id: ws3, name: "gamma", slug: "gamma", color: .blue,
            panes: [], layout: .empty,
            focusedPaneID: nil,
            createdAt: epoch,
            lastAccessedAt: epoch
        )

        var state = AppReducer.State()
        state.workspaces = [ws1State, ws2State, ws3State]
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

    // MARK: - pane split

    @Test("split: UUID target resolves globally and returns the new pane id")
    func splitUUIDTarget() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        withDependencies { $0.uuid = .constant(Self.newPane) } operation: {
            _ = AppReducer().handlePaneSplit(
                state: &state, paneID: nil, direction: nil, path: nil,
                name: nil, target: Self.pane2.uuidString, workspaceFilter: nil,
                reply: rec.handle()
            )
        }
        #expect(rec.sent.count == 1)
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["pane_id"] as? String) == Self.newPane.uuidString)
        #expect((rec.sent[0]["workspace_name"] as? String) == "beta")
        // ws2 (beta) focuses pane2 ready to be split.
        #expect(state.workspaces[id: Self.ws2]?.focusedPaneID == Self.pane2)
        #expect(rec.closeCount == 1)
    }

    @Test("split: bare label with no scope errors")
    func splitLabelNoScopeErrors() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneSplit(
            state: &state, paneID: nil, direction: nil, path: nil,
            name: nil, target: "worker", workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
        #expect(rec.closeCount == 1)
    }

    @Test("split: --workspace alone targets that workspace's focused pane")
    func splitWorkspaceOnly() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        withDependencies { $0.uuid = .constant(Self.newPane) } operation: {
            _ = AppReducer().handlePaneSplit(
                state: &state, paneID: nil, direction: nil, path: nil,
                name: nil, target: nil, workspaceFilter: "beta", reply: rec.handle()
            )
        }
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["pane_id"] as? String) == Self.newPane.uuidString)
        #expect((rec.sent[0]["workspace_name"] as? String) == "beta")
    }

    @Test("split: no target / workspace / paneID errors")
    func splitNoAnchorErrors() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneSplit(
            state: &state, paneID: nil, direction: nil, path: nil,
            name: nil, target: nil, workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
    }

    @Test("split: --workspace wins over the caller's NEX_PANE_ID workspace")
    func splitWorkspaceOverridesCallerPane() {
        // Caller is pane1 in workspace alpha but asks to split in beta.
        // Before the fix this errored ("pane is not in workspace beta")
        // because the caller's paneID branch was taken first.
        var state = Self.makeState()
        let rec = ReplyRecorder()
        withDependencies { $0.uuid = .constant(Self.newPane) } operation: {
            _ = AppReducer().handlePaneSplit(
                state: &state, paneID: Self.pane1, direction: nil, path: nil,
                name: nil, target: nil, workspaceFilter: "beta", reply: rec.handle()
            )
        }
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["workspace_name"] as? String) == "beta")
        #expect((rec.sent[0]["pane_id"] as? String) == Self.newPane.uuidString)
    }

    // MARK: - pane create

    @Test("create: --workspace into a populated workspace returns the new pane id")
    func createWorkspacePopulated() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        withDependencies { $0.uuid = .constant(Self.newPane) } operation: {
            _ = AppReducer().handlePaneCreate(
                state: &state, paneID: nil, path: nil, name: nil,
                target: nil, workspaceFilter: "alpha", reply: rec.handle()
            )
        }
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["pane_id"] as? String) == Self.newPane.uuidString)
        #expect((rec.sent[0]["workspace_name"] as? String) == "alpha")
    }

    @Test("create: --workspace into an empty workspace returns the new pane id")
    func createWorkspaceEmpty() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        withDependencies { $0.uuid = .constant(Self.newPane) } operation: {
            _ = AppReducer().handlePaneCreate(
                state: &state, paneID: nil, path: nil, name: nil,
                target: nil, workspaceFilter: "gamma", reply: rec.handle()
            )
        }
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["pane_id"] as? String) == Self.newPane.uuidString)
        #expect((rec.sent[0]["workspace_name"] as? String) == "gamma")
    }

    @Test("create: no anchor errors")
    func createNoAnchorErrors() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneCreate(
            state: &state, paneID: nil, path: nil, name: nil,
            target: nil, workspaceFilter: nil, reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
    }

    @Test("create: --workspace wins over the caller's NEX_PANE_ID workspace")
    func createWorkspaceOverridesCallerPane() {
        // Caller is pane1 in workspace alpha but asks to create in beta.
        // Before the fix this errored ("pane is not in workspace beta").
        var state = Self.makeState()
        let rec = ReplyRecorder()
        withDependencies { $0.uuid = .constant(Self.newPane) } operation: {
            _ = AppReducer().handlePaneCreate(
                state: &state, paneID: Self.pane1, path: nil, name: nil,
                target: nil, workspaceFilter: "beta", reply: rec.handle()
            )
        }
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["workspace_name"] as? String) == "beta")
        #expect((rec.sent[0]["pane_id"] as? String) == Self.newPane.uuidString)
    }

    // MARK: - pane name

    @Test("name: UUID target renames that pane")
    func nameUUIDTarget() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneName(
            state: &state, paneID: nil, target: Self.pane3.uuidString,
            workspaceFilter: nil, name: "renamed", reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect((rec.sent[0]["pane_id"] as? String) == Self.pane3.uuidString)
        #expect(state.workspaces[id: Self.ws1]?.panes[id: Self.pane3]?.label == "renamed")
    }

    @Test("name: caller pane (paneID, no target) renames the caller")
    func nameCallerPane() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneName(
            state: &state, paneID: Self.pane1, target: nil,
            workspaceFilter: nil, name: "primary", reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == true)
        #expect(state.workspaces[id: Self.ws1]?.panes[id: Self.pane1]?.label == "primary")
    }

    @Test("name: bare label with no scope errors and does not mutate")
    func nameLabelNoScopeErrors() {
        var state = Self.makeState()
        let rec = ReplyRecorder()
        _ = AppReducer().handlePaneName(
            state: &state, paneID: nil, target: "worker",
            workspaceFilter: nil, name: "x", reply: rec.handle()
        )
        #expect((rec.sent[0]["ok"] as? Bool) == false)
        #expect(state.workspaces[id: Self.ws1]?.panes[id: Self.pane1]?.label == "worker")
        #expect(state.workspaces[id: Self.ws2]?.panes[id: Self.pane2]?.label == "worker")
    }
}
