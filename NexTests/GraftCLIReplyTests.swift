import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the `graft-start` / `graft-stop` / `graft-status` request-
/// response paths through the reducer. The graft service is fully
/// stubbed — assertions focus on scope resolution, payload shape, and
/// the close lifecycle.
@MainActor
struct GraftCLIReplyTests {
    private static let wsID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private static let paneID = UUID(uuidString: "70000000-0000-0000-0000-00000000000A")!
    private static let assocID = UUID(uuidString: "70000000-0000-0000-0000-0000000000B1")!
    private static let repoID = UUID(uuidString: "70000000-0000-0000-0000-0000000000C1")!

    private final class CaptureSink: @unchecked Sendable {
        var payloads: [[String: Any]] = []
        var closed = 0
    }

    private func makeCaptureHandle(_ sink: CaptureSink) -> SocketServer.ReplyHandle {
        SocketServer.ReplyHandle(
            id: 1,
            send: { json in sink.payloads.append(json) },
            close: { sink.closed += 1 }
        )
    }

    private func makeStore(
        sessions: IdentifiedArrayOf<GraftSession> = [],
        activeSessions: @escaping @Sendable () async -> [GraftSession] = { [] },
        graftStartResult: @escaping @Sendable (RepoAssociation) async throws -> GraftSession,
        graftStopResult: @escaping @Sendable (UUID) async throws -> Void = { _ in }
    ) -> TestStoreOf<AppReducer> {
        var workspace = WorkspaceFeature.State(id: Self.wsID, name: "alpha")
        let pane = Pane(id: Self.paneID)
        workspace.panes = IdentifiedArrayOf(uniqueElements: [pane])
        workspace.layout = .leaf(Self.paneID)
        workspace.focusedPaneID = Self.paneID
        workspace.repoAssociations = [
            RepoAssociation(
                id: Self.assocID,
                repoID: Self.repoID,
                worktreePath: "/tmp/wt",
                branchName: "feature/x"
            )
        ]

        var appState = AppReducer.State()
        appState.workspaces = [workspace]
        appState.repoRegistry = [Repo(id: Self.repoID, path: "/tmp/parent", name: "my-repo")]
        appState.activeWorkspaceID = Self.wsID
        appState.topLevelOrder = [.workspace(Self.wsID)]
        appState.graft = GraftFeature.State(sessions: sessions, orphans: [])

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.continuousClock = ImmediateClock()
            $0.graftService = GraftService(
                start: graftStartResult,
                stop: graftStopResult,
                activeSessions: activeSessions,
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private static func makeSession() -> GraftSession {
        GraftSession(
            id: assocID,
            worktreePath: "/tmp/wt",
            parentRepoRoot: "/tmp/parent",
            branch: "feature/x",
            status: .watching,
            stashRef: nil,
            lastSync: nil
        )
    }

    // MARK: - graft-start

    @Test func graftStartUsesPaneIDForScopeAndRepliesOk() async {
        let session = Self.makeSession()
        let store = makeStore(
            graftStartResult: { _ in session }
        )
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStart(workspace: nil, repo: nil, paneID: Self.paneID),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads.count == 1)
        #expect(sink.closed == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        let started = sink.payloads[0]["started"] as? [[String: Any]] ?? []
        #expect(started.count == 1)
        #expect(started.first?["association_id"] as? String == Self.assocID.uuidString)
        #expect(started.first?["branch"] as? String == "feature/x")
    }

    @Test func graftStartFailsWhenNeitherFilterNorPaneID() async {
        let session = Self.makeSession()
        let store = makeStore(graftStartResult: { _ in session })
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStart(workspace: nil, repo: nil, paneID: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let msg = sink.payloads[0]["error"] as? String ?? ""
        #expect(msg.contains("--workspace") || msg.contains("NEX_PANE_ID"))
    }

    @Test func graftStartRepoFilterMatchesByName() async {
        let session = Self.makeSession()
        let calledFor = LockedString()
        let store = makeStore(graftStartResult: { assoc in
            calledFor.set(assoc.id.uuidString)
            return session
        })

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStart(workspace: nil, repo: "my-repo", paneID: nil),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(calledFor.value == Self.assocID.uuidString)
    }

    @Test func graftStartFailsWhenWorkspaceFilterUnknown() async {
        let session = Self.makeSession()
        let store = makeStore(graftStartResult: { _ in session })
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStart(workspace: "nope", repo: nil, paneID: nil),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("workspace not found") == true)
    }

    // MARK: - graft-stop

    @Test func graftStopReturnsStoppedIDs() async {
        let session = Self.makeSession()
        let store = makeStore(
            sessions: [session],
            activeSessions: { [session] },
            graftStartResult: { _ in session },
            graftStopResult: { _ in }
        )
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStop(workspace: nil, repo: nil, paneID: Self.paneID),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        let stopped = sink.payloads[0]["stopped"] as? [String] ?? []
        #expect(stopped == [Self.assocID.uuidString])
    }

    @Test func graftStopWithoutActiveSessionIsNoOpButOk() async {
        let session = Self.makeSession()
        let store = makeStore(graftStartResult: { _ in session })
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStop(workspace: nil, repo: nil, paneID: Self.paneID),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect((sink.payloads[0]["stopped"] as? [String])?.isEmpty == true)
    }

    /// Issue #231: a session the reducer mirror lost track of must
    /// still be stoppable — the stop handler filters against the
    /// SERVICE's sessions, not reducer state.
    @Test func graftStopReachesSessionMissingFromReducerMirror() async {
        let session = Self.makeSession()
        let stopCalls = LockedString()
        let store = makeStore(
            sessions: [],
            activeSessions: { [session] },
            graftStartResult: { _ in session },
            graftStopResult: { id in stopCalls.set(id.uuidString) }
        )
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStop(workspace: nil, repo: nil, paneID: Self.paneID),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        let stopped = sink.payloads[0]["stopped"] as? [String] ?? []
        #expect(stopped == [Self.assocID.uuidString])
        #expect(stopCalls.value == Self.assocID.uuidString)
    }

    /// Issue #231: a session whose owning association was deleted
    /// (workspace gone) resolves via NO workspace scope, but
    /// `graft stop --repo <path>` must still reach it by matching the
    /// service session's worktree path directly.
    @Test func graftStopRepoFilterReachesOrphanWithDeletedAssociation() async {
        let orphanID = UUID(uuidString: "70000000-0000-0000-0000-0000000000EE")!
        let orphanSession = GraftSession(
            id: orphanID,
            worktreePath: "/tmp/wt-orphan",
            parentRepoRoot: "/tmp/parent-orphan",
            branch: "gone-branch",
            status: .watching,
            stashRef: nil,
            lastSync: nil
        )
        let stopCalls = LockedString()
        let store = makeStore(
            activeSessions: { [orphanSession] },
            graftStartResult: { _ in orphanSession },
            graftStopResult: { id in stopCalls.set(id.uuidString) }
        )
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStop(workspace: nil, repo: "/tmp/wt-orphan", paneID: nil),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        let stopped = sink.payloads[0]["stopped"] as? [String] ?? []
        #expect(stopped == [orphanID.uuidString])
        #expect(stopCalls.value == orphanID.uuidString)
    }

    // MARK: - graft-status

    @Test func graftStatusListsActiveSessions() async {
        let session = Self.makeSession()
        let store = makeStore(
            sessions: [session],
            activeSessions: { [session] },
            graftStartResult: { _ in session }
        )
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStatus,
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        let sessions = sink.payloads[0]["sessions"] as? [[String: Any]] ?? []
        #expect(sessions.count == 1)
        #expect(sessions.first?["branch"] as? String == "feature/x")
        #expect(sessions.first?["status"] as? String == "watching")
    }

    /// Issue #231: `status` must report what the SERVICE holds even
    /// when the reducer mirror is empty, so an `alreadyActive`
    /// rejection is always explainable from the CLI.
    @Test func graftStatusShowsSessionMissingFromReducerMirror() async {
        let session = Self.makeSession()
        let store = makeStore(
            sessions: [],
            activeSessions: { [session] },
            graftStartResult: { _ in session }
        )
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .graftStatus,
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        let sessions = sink.payloads[0]["sessions"] as? [[String: Any]] ?? []
        #expect(sessions.count == 1)
        #expect(sessions.first?["association_id"] as? String == Self.assocID.uuidString)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String = ""
    func set(_ v: String) {
        lock.withLock { _value = v }
    }

    var value: String { lock.withLock { _value } }
}
