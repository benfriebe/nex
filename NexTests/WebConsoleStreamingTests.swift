import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Phase 7 (issue #145): `nex web console --follow` subscriber
/// lifecycle. Mirrors `PaneCaptureReplyTests` — captures JSON replies
/// via a closure-backed `SocketServer.ReplyHandle` stub, no real
/// socket involved.
@MainActor
struct WebConsoleStreamingTests {
    private static let wsID = UUID(uuidString: "90000000-0000-0000-0000-000000000002")!
    private static let paneID = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!
    private static let tabID = UUID(uuidString: "00000000-0000-0000-0000-00000000D002")!

    private final class ConsoleSink: @unchecked Sendable {
        var payloads: [[String: Any]] = []
        var closedCount = 0
    }

    private func makeConsoleHandle(_ sink: ConsoleSink, id: UInt64 = 1) -> SocketServer.ReplyHandle {
        SocketServer.ReplyHandle(
            id: id,
            send: { json in sink.payloads.append(json) },
            close: { sink.closedCount += 1 }
        )
    }

    private func makeLine(_ message: String) -> ConsoleLine {
        ConsoleLine(
            tabID: Self.tabID, level: .log, message: message, url: "https://example.com",
            lineNumber: nil, columnNumber: nil, capturedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private func makeStore(webState: WebPaneState? = nil) -> TestStoreOf<AppReducer> {
        let pane = Pane(id: Self.paneID, label: "web", type: .web)
        let resolvedWebState = webState ?? WebPaneState(
            tabs: [WebTab(id: Self.tabID, url: "https://example.com")],
            activeTabID: Self.tabID, isPrivate: false
        )
        let workspace = WorkspaceFeature.State(
            id: Self.wsID, name: "alpha", slug: "alpha", color: .blue,
            panes: [pane],
            layout: .leaf(Self.paneID),
            focusedPaneID: Self.paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000),
            webPanes: [Self.paneID: resolvedWebState]
        )

        var appState = AppReducer.State()
        appState.workspaces = [workspace]
        appState.activeWorkspaceID = Self.wsID
        appState.topLevelOrder = [.workspace(Self.wsID)]

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

    // MARK: - Registration

    @Test func followRegistersSubscriberAndDoesNotClose() async {
        let store = makeStore()
        let sink = ConsoleSink()

        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: true
            ),
            reply: makeConsoleHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads.count == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["follow"] as? Bool == true)
        #expect(sink.closedCount == 0)
        #expect(store.state.webConsoleSubscribers[Self.paneID]?[1] != nil)
    }

    @Test func nonFollowClosesAndNeverRegisters() async {
        let store = makeStore()
        let sink = ConsoleSink()

        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: false
            ),
            reply: makeConsoleHandle(sink)
        ))
        await store.finish()

        #expect(sink.closedCount == 1)
        #expect(store.state.webConsoleSubscribers[Self.paneID] == nil)
    }

    // MARK: - Fan-out

    @Test func newLineIsDeliveredToFollowSubscriber() async {
        let store = makeStore()
        let sink = ConsoleSink()

        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: true
            ),
            reply: makeConsoleHandle(sink)
        ))
        await store.finish()
        #expect(sink.payloads.count == 1)

        await store.send(.workspaces(.element(
            id: Self.wsID,
            action: .webConsoleLineReceived(paneID: Self.paneID, line: makeLine("hello"))
        )))
        await store.finish()

        #expect(sink.payloads.count == 2)
        #expect(sink.payloads[1]["message"] as? String == "hello")
        #expect(sink.payloads[1]["level"] as? String == "log")
        #expect(sink.closedCount == 0)
    }

    @Test func multipleSubscribersAllReceiveTheLine() async {
        let store = makeStore()
        let sinkA = ConsoleSink()
        let sinkB = ConsoleSink()

        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: true
            ),
            reply: makeConsoleHandle(sinkA, id: 1)
        ))
        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: true
            ),
            reply: makeConsoleHandle(sinkB, id: 2)
        ))
        await store.finish()

        await store.send(.workspaces(.element(
            id: Self.wsID,
            action: .webConsoleLineReceived(paneID: Self.paneID, line: makeLine("broadcast"))
        )))
        await store.finish()

        #expect(sinkA.payloads.last?["message"] as? String == "broadcast")
        #expect(sinkB.payloads.last?["message"] as? String == "broadcast")
    }

    // MARK: - Disconnect cleanup

    @Test func subscriberDisconnectRemovesHandle() async {
        let store = makeStore()
        let sink = ConsoleSink()

        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: true
            ),
            reply: makeConsoleHandle(sink)
        ))
        await store.finish()
        #expect(store.state.webConsoleSubscribers[Self.paneID]?[1] != nil)

        await store.send(.socketMessage(.socketSubscriberDisconnected(replyID: 1), reply: nil))
        await store.finish()

        #expect(store.state.webConsoleSubscribers[Self.paneID] == nil)
    }

    @Test func disconnectOfUnknownReplyIDIsANoOp() async {
        let store = makeStore()
        // No subscriber ever registered — a stray disconnect
        // notification (e.g. from any ordinary request/response call)
        // must not crash or mutate anything.
        await store.send(.socketMessage(.socketSubscriberDisconnected(replyID: 999), reply: nil))
        await store.finish()

        #expect(store.state.webConsoleSubscribers.isEmpty)
    }

    // MARK: - Pane-close cleanup

    @Test func closingThePaneClosesAndDropsSubscribers() async {
        let store = makeStore()
        let sink = ConsoleSink()

        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: true
            ),
            reply: makeConsoleHandle(sink)
        ))
        await store.finish()
        #expect(sink.closedCount == 0)

        await store.send(.workspaces(.element(id: Self.wsID, action: .closePane(Self.paneID))))
        await store.finish()

        #expect(sink.closedCount == 1)
        #expect(store.state.webConsoleSubscribers[Self.paneID] == nil)
    }

    // MARK: - Back-pressure

    @Test func dropCounterAttachesToTheLineThatCausedTheEviction() async {
        // Capacity 1 so a second append evicts the first entry inside
        // the very same `.webConsoleLineReceived` that the fan-out
        // reacts to — deterministic without needing to push 1000 lines
        // through the buffer.
        var webState = WebPaneState(
            tabs: [WebTab(id: Self.tabID, url: "https://example.com")],
            activeTabID: Self.tabID, isPrivate: false
        )
        webState.consoleBuffer = RingBuffer<ConsoleLine>(capacity: 1)
        webState.consoleBuffer.append(makeLine("first"))
        let store = makeStore(webState: webState)
        let sink = ConsoleSink()

        await store.send(.socketMessage(
            .webConsole(
                paneID: Self.paneID, target: nil, workspace: nil,
                since: 0, level: nil, clear: false, follow: true
            ),
            reply: makeConsoleHandle(sink)
        ))
        await store.finish()
        // No eviction yet — the buffer holds exactly one entry.
        #expect(sink.payloads[0]["dropped"] as? Int == 0)

        await store.send(.workspaces(.element(
            id: Self.wsID,
            action: .webConsoleLineReceived(paneID: Self.paneID, line: makeLine("second"))
        )))
        await store.finish()

        #expect(sink.payloads.count == 2)
        #expect(sink.payloads[1]["message"] as? String == "second")
        #expect(sink.payloads[1]["dropped"] as? Int == 1)
    }
}
