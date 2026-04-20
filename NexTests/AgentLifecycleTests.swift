import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct AgentLifecycleTests {
    private func makeAppStore(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State>,
        activeWorkspaceID: UUID
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.activeWorkspaceID = activeWorkspaceID
        // Disable auto-detection so tests don't have to deal with the
        // debounced effects scheduled by paneDirectoryChanged / closePane.
        appState.settings.autoDetectRepos = false

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test func socketMessageRoutesToCorrectWorkspace() async {
        let paneID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let paneID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let wsID1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let wsID2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

        let ws1 = WorkspaceFeature.State(
            id: wsID1, name: "WS1", slug: "ws1", color: .blue,
            panes: [Pane(id: paneID1)], layout: .leaf(paneID1),
            focusedPaneID: paneID1, createdAt: Date(), lastAccessedAt: Date()
        )
        let ws2 = WorkspaceFeature.State(
            id: wsID2, name: "WS2", slug: "ws2", color: .red,
            panes: [Pane(id: paneID2)], layout: .leaf(paneID2),
            focusedPaneID: paneID2, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeAppStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: wsID1
        )

        // Send socket message for pane in WS2 (background workspace)
        await store.send(.socketMessage(.agentStopped(paneID: paneID2), reply: nil))

        // The .send() effect routes to the child — wait for it
        await store.receive(
            .workspaces(.element(id: wsID2, action: .agentStopped(paneID: paneID2)))
        ) { state in
            state.workspaces[id: wsID2]?.panes[id: paneID2]?.status = .waitingForInput
        }
    }

    @Test func surfaceTitleChangedRoutesToCorrectWorkspace() async {
        let paneID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let paneID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let wsID1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let wsID2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

        let ws1 = WorkspaceFeature.State(
            id: wsID1, name: "WS1", slug: "ws1", color: .blue,
            panes: [Pane(id: paneID1)], layout: .leaf(paneID1),
            focusedPaneID: paneID1, createdAt: Date(), lastAccessedAt: Date()
        )
        let ws2 = WorkspaceFeature.State(
            id: wsID2, name: "WS2", slug: "ws2", color: .red,
            panes: [Pane(id: paneID2)], layout: .leaf(paneID2),
            focusedPaneID: paneID2, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeAppStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: wsID1
        )

        await store.send(.surfaceTitleChanged(paneID: paneID2, title: "vim main.swift"))

        await store.receive(
            .workspaces(.element(id: wsID2, action: .paneTitleChanged(paneID: paneID2, title: "vim main.swift")))
        ) { state in
            state.workspaces[id: wsID2]?.panes[id: paneID2]?.title = "vim main.swift"
            state.workspaces[id: wsID2]?.panes[id: paneID2]?.lastActivityAt = Date(timeIntervalSince1970: 1000)
        }
    }

    @Test func surfaceDirectoryChangedRoutesToCorrectWorkspace() async {
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let wsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        let ws = WorkspaceFeature.State(
            id: wsID, name: "WS", slug: "ws", color: .blue,
            panes: [Pane(id: paneID)], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeAppStore(
            workspaces: [ws],
            activeWorkspaceID: wsID
        )

        await store.send(.surfaceDirectoryChanged(paneID: paneID, directory: "/tmp/test"))

        await store.receive(
            .workspaces(.element(id: wsID, action: .paneDirectoryChanged(paneID: paneID, directory: "/tmp/test")))
        ) { state in
            state.workspaces[id: wsID]?.panes[id: paneID]?.workingDirectory = "/tmp/test"
            state.workspaces[id: wsID]?.panes[id: paneID]?.lastActivityAt = Date(timeIntervalSince1970: 1000)
        }
    }

    @Test func socketMessageForUnknownPaneIsIgnored() async {
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let wsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let unknownPaneID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let ws = WorkspaceFeature.State(
            id: wsID, name: "WS", slug: "ws", color: .blue,
            panes: [Pane(id: paneID)], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeAppStore(
            workspaces: [ws],
            activeWorkspaceID: wsID
        )

        // Should produce no child effects — unknown pane
        await store.send(.socketMessage(.agentStopped(paneID: unknownPaneID), reply: nil))
    }

    // MARK: - Desktop Notifications

    @Test func desktopNotificationForUnknownPaneIsIgnored() async {
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let wsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let unknownPaneID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let ws = WorkspaceFeature.State(
            id: wsID, name: "WS", slug: "ws", color: .blue,
            panes: [Pane(id: paneID)], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeAppStore(
            workspaces: [ws],
            activeWorkspaceID: wsID
        )

        // Unknown pane — no effect
        await store.send(.desktopNotification(paneID: unknownPaneID, title: "Test", body: "msg"))
    }

    @Test func sessionStartedStoresSessionID() async {
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let wsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        let ws = WorkspaceFeature.State(
            id: wsID, name: "WS", slug: "ws", color: .blue,
            panes: [Pane(id: paneID)], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeAppStore(
            workspaces: [ws],
            activeWorkspaceID: wsID
        )

        await store.send(.socketMessage(.sessionStarted(paneID: paneID, sessionID: "abc-123"), reply: nil))

        await store.receive(
            .workspaces(.element(id: wsID, action: .sessionStarted(paneID: paneID, sessionID: "abc-123")))
        ) { state in
            state.workspaces[id: wsID]?.panes[id: paneID]?.claudeSessionID = "abc-123"
        }
    }

    @Test func agentErrorAlwaysNotifies() async {
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let wsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        let ws = WorkspaceFeature.State(
            id: wsID, name: "WS", slug: "ws", color: .blue,
            panes: [Pane(id: paneID)], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeAppStore(
            workspaces: [ws],
            activeWorkspaceID: wsID
        )

        // Error events always fire a notification (even if focused)
        await store.send(.socketMessage(.agentError(paneID: paneID, message: "crash"), reply: nil))

        await store.receive(
            .workspaces(.element(id: wsID, action: .agentError(paneID: paneID)))
        ) { state in
            state.workspaces[id: wsID]?.panes[id: paneID]?.status = .waitingForInput
        }
    }
}
