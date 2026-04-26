import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the `pane-capture` request/response path through the
/// reducer. Mirrors `PaneCloseReplyTests` — captures the JSON reply via
/// a closure-backed `SocketServer.ReplyHandle` stub. No real socket is
/// involved.
///
/// The happy path exercises the resolution + dispatch logic and ends in
/// "pane closed during capture" because the test `SurfaceManager` has no
/// live surfaces. That's the correct failure shape for a torn-down pane,
/// which is what `surface(for:) == nil` represents in test conditions.
@MainActor
struct PaneCaptureReplyTests {
    private static let ws1ID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
    private static let ws2ID = UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
    private static let pane1 = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
    private static let pane2 = UUID(uuidString: "00000000-0000-0000-0000-00000000C002")!

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

    // MARK: - Resolution errors (synchronous)

    @Test func captureMarkdownPaneFailsWithTypeError() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "notes", type: .markdown)]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneCapture(paneID: nil, target: "notes", workspace: nil, lines: nil, includeScrollback: false),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads.count == 1)
        #expect(sink.closedCount == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let error = sink.payloads[0]["error"] as? String ?? ""
        #expect(error.contains("not a terminal"))
        #expect(error.contains("markdown"))
    }

    @Test func captureUnknownLabelFails() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneCapture(paneID: nil, target: "ghost", workspace: nil, lines: nil, includeScrollback: false),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("ghost") == true)
    }

    @Test func captureAmbiguousLabelFailsWithAdvice() async {
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
            .paneCapture(paneID: nil, target: "worker", workspace: nil, lines: nil, includeScrollback: false),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let error = sink.payloads[0]["error"] as? String ?? ""
        #expect(error.contains("ambiguous"))
        #expect(error.contains("--workspace"))
    }

    @Test func captureRejectsNonPositiveLines() async {
        // The CLI rejects `--lines 0` upfront, but a raw socket/TCP
        // client can send any int — the reducer must guard against it.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        for invalidLines in [0, -1, -50] {
            let sink = CaptureSink()
            await store.send(.socketMessage(
                .paneCapture(
                    paneID: Self.pane1, target: nil, workspace: nil,
                    lines: invalidLines, includeScrollback: false
                ),
                reply: makeCaptureHandle(sink)
            ))
            #expect(sink.payloads.count == 1)
            #expect(sink.payloads[0]["ok"] as? Bool == false)
            #expect((sink.payloads[0]["error"] as? String)?.contains("positive integer") == true)
        }
    }

    @Test func captureUnknownWorkspaceFails() async {
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneCapture(paneID: nil, target: "worker", workspace: "ghost", lines: nil, includeScrollback: false),
            reply: makeCaptureHandle(sink)
        ))

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("workspace not found") == true)
    }

    // MARK: - Dispatch reaches surface manager

    @Test func captureShellPaneReachesSurfaceManager() async {
        // Resolution succeeds and the effect runs; the test SurfaceManager
        // has no live surfaces so captureContents returns nil, which the
        // reducer surfaces as "pane closed during capture". Confirms the
        // happy-path resolution + effect plumbing reaches the surface read.
        let ws = makeWorkspace(
            id: Self.ws1ID, name: "alpha",
            panes: [Pane(id: Self.pane1, label: "worker")]
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.ws1ID)

        let sink = CaptureSink()
        await store.send(.socketMessage(
            .paneCapture(paneID: Self.pane1, target: nil, workspace: nil, lines: nil, includeScrollback: false),
            reply: makeCaptureHandle(sink)
        ))

        await store.finish()

        #expect(sink.payloads.count == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String) == "pane closed during capture")
    }

    // MARK: - tailLines helper

    @Test func tailLinesKeepsLastN() {
        let text = "one\ntwo\nthree\nfour\n"
        #expect(AppReducer.tailLines(text, 2) == "three\nfour\n")
    }

    @Test func tailLinesPreservesNoTrailingNewline() {
        let text = "one\ntwo\nthree"
        #expect(AppReducer.tailLines(text, 2) == "two\nthree")
    }

    @Test func tailLinesAllWhenNExceedsLineCount() {
        let text = "one\ntwo\n"
        #expect(AppReducer.tailLines(text, 99) == "one\ntwo\n")
    }

    @Test func tailLinesZeroReturnsEmpty() {
        #expect(AppReducer.tailLines("anything\n", 0) == "")
    }

    @Test func tailLinesEmptyText() {
        #expect(AppReducer.tailLines("", 5) == "")
    }
}
