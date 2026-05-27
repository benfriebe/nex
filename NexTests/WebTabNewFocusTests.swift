import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Issue #153: opening a blank new tab in a web pane should bump
/// `webPaneURLFocusTokens[paneID]` so the URL bar gets first
/// responder. A new tab opened with a preset URL is loading content,
/// so focus stays with the WKWebView — the token is unchanged.
@MainActor
struct WebTabNewFocusTests {
    private static let wsID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    private static let paneID = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!

    private func makeStore() -> TestStoreOf<AppReducer> {
        let pane = Pane(id: Self.paneID, type: .web)
        let workspace = WorkspaceFeature.State(
            id: Self.wsID, name: "alpha", slug: "alpha", color: .blue,
            panes: [pane],
            layout: .leaf(Self.paneID),
            focusedPaneID: Self.paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000),
            webPanes: [
                Self.paneID: WebPaneState(
                    tabs: [WebTab(id: UUID(), url: "https://example.com")],
                    activeTabID: nil,
                    isPrivate: false
                )
            ]
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

    @Test func blankNewTabBumpsURLFocusToken() async {
        let store = makeStore()
        #expect(store.state.webPaneURLFocusTokens[Self.paneID] == nil)

        await store.send(.webPaneOpenNewTab(paneID: Self.paneID, url: nil)) {
            $0.webPaneURLFocusTokens[Self.paneID] = 1
        }
    }

    @Test func emptyStringURLAlsoBumpsToken() async {
        let store = makeStore()

        await store.send(.webPaneOpenNewTab(paneID: Self.paneID, url: "")) {
            $0.webPaneURLFocusTokens[Self.paneID] = 1
        }
    }

    @Test func preloadedURLDoesNotBumpToken() async {
        let store = makeStore()

        await store.send(
            .webPaneOpenNewTab(paneID: Self.paneID, url: "https://example.com")
        )
        // Token stays nil — the WKWebView gets focus once the page loads.
        #expect(store.state.webPaneURLFocusTokens[Self.paneID] == nil)
    }
}
