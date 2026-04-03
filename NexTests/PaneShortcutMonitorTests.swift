import AppKit
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct PaneShortcutMonitorTests {
    // MARK: - Helpers

    private static let wsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let paneID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let paneID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private static func makeWorkspace(
        id: UUID = wsID,
        name: String = "Test",
        paneID: UUID = paneID1
    ) -> WorkspaceFeature.State {
        WorkspaceFeature.State(
            id: id, name: name, slug: name.lowercased(), color: .blue,
            panes: [Pane(id: paneID)], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )
    }

    private static func makeTwoPaneWorkspace(
        id: UUID = wsID,
        paneID1: UUID = paneID1,
        paneID2: UUID = paneID2
    ) -> WorkspaceFeature.State {
        WorkspaceFeature.State(
            id: id, name: "Test", slug: "test", color: .blue,
            panes: [Pane(id: paneID1), Pane(id: paneID2)],
            layout: .split(.horizontal, ratio: 0.5, first: .leaf(paneID1), second: .leaf(paneID2)),
            focusedPaneID: paneID1, createdAt: Date(), lastAccessedAt: Date()
        )
    }

    private func makeStoreAndMonitor(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [],
        activeWorkspaceID: UUID? = nil,
        keybindings: KeyBindingMap = .defaults
    ) -> (Store<AppReducer.State, AppReducer.Action>, PaneShortcutMonitor) {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.activeWorkspaceID = activeWorkspaceID
        appState.keybindings = keybindings

        let store = Store(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }

        let monitor = PaneShortcutMonitor(store: store)
        return (store, monitor)
    }

    private func keyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: - No active workspace

    @Test func noActiveWorkspaceReturnsFalse() {
        let (_, monitor) = makeStoreAndMonitor()
        let event = keyEvent(keyCode: 30, modifierFlags: .command)
        #expect(monitor.handleKeyEvent(event) == false)
    }

    // MARK: - Focus next pane

    @Test func cmdRightArrowFocusesNextPane() {
        let ws = Self.makeTwoPaneWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 124, modifierFlags: [.command, .option, .numericPad, .function])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID2)
    }

    @Test func cmdCloseBracketFocusesNextPane() {
        let ws = Self.makeTwoPaneWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 30, modifierFlags: .command)
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID2)
    }

    // MARK: - Focus previous pane

    @Test func cmdLeftArrowFocusesPreviousPane() {
        let ws = Self.makeTwoPaneWorkspace(paneID1: Self.paneID1, paneID2: Self.paneID2)
        var state = ws
        state.focusedPaneID = Self.paneID2

        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [state],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 123, modifierFlags: [.command, .option, .numericPad, .function])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID1)
    }

    @Test func cmdOpenBracketFocusesPreviousPane() {
        let ws = Self.makeTwoPaneWorkspace(paneID1: Self.paneID1, paneID2: Self.paneID2)
        var state = ws
        state.focusedPaneID = Self.paneID2

        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [state],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 33, modifierFlags: .command)
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID1)
    }

    // MARK: - Split pane

    @Test func cmdDSplitsHorizontal() {
        let ws = Self.makeWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 2, modifierFlags: .command)
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]!.panes.count == 2)
        if case .split(let dir, _, _, _) = store.workspaces[id: Self.wsID]!.layout {
            #expect(dir == .horizontal)
        } else {
            Issue.record("Expected split layout")
        }
    }

    @Test func cmdShiftDSplitsVertical() {
        let ws = Self.makeWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 2, modifierFlags: [.command, .shift])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]!.panes.count == 2)
        if case .split(let dir, _, _, _) = store.workspaces[id: Self.wsID]!.layout {
            #expect(dir == .vertical)
        } else {
            Issue.record("Expected split layout")
        }
    }

    // MARK: - Close pane

    @Test func cmdWClosesPaneWhenMultiplePanes() {
        let ws = Self.makeTwoPaneWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 13, modifierFlags: .command)
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]!.panes.count == 1)
    }

    @Test func cmdWDeletesWorkspaceWhenLastPane() {
        let ws = Self.makeWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 13, modifierFlags: .command)
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID] == nil)
    }

    // MARK: - Workspace switching

    @Test func cmdOptDownSwitchesToNextWorkspace() {
        let wsID2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let ws1 = Self.makeWorkspace(id: Self.wsID, name: "WS1")
        let ws2 = Self.makeWorkspace(id: wsID2, name: "WS2", paneID: Self.paneID2)
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 125, modifierFlags: [.command, .option, .numericPad, .function])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.activeWorkspaceID == wsID2)
    }

    @Test func cmdOptUpSwitchesToPreviousWorkspace() {
        let wsID2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let ws1 = Self.makeWorkspace(id: Self.wsID, name: "WS1")
        let ws2 = Self.makeWorkspace(id: wsID2, name: "WS2", paneID: Self.paneID2)
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws1, ws2],
            activeWorkspaceID: wsID2
        )

        let event = keyEvent(keyCode: 126, modifierFlags: [.command, .option, .numericPad, .function])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.activeWorkspaceID == Self.wsID)
    }

    // MARK: - Markdown toggle

    @Test func cmdETogglesMarkdownEdit() {
        let mdPane = Pane(id: Self.paneID1, type: .markdown, filePath: "/tmp/test.md")
        let ws = WorkspaceFeature.State(
            id: Self.wsID, name: "Test", slug: "test", color: .blue,
            panes: [mdPane], layout: .leaf(Self.paneID1),
            focusedPaneID: Self.paneID1, createdAt: Date(), lastAccessedAt: Date()
        )
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 14, modifierFlags: .command)
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.panes[id: Self.paneID1]?.isEditing == true)
    }

    @Test func cmdEIgnoredForShellPane() {
        let ws = Self.makeWorkspace()
        let (_, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 14, modifierFlags: .command)
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == false)
    }

    // MARK: - Reopen closed pane

    @Test func cmdShiftTReopensClosedPane() {
        let ws = Self.makeWorkspace()
        let (_, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 17, modifierFlags: [.command, .shift])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
    }

    // MARK: - Unhandled keys

    @Test func unhandledKeyReturnsFalse() {
        let ws = Self.makeWorkspace()
        let (_, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        // Random key with no binding (keyCode 0 = 'a', no modifiers)
        let event = keyEvent(keyCode: 0)
        #expect(monitor.handleKeyEvent(event) == false)
    }

    // MARK: - Custom keybindings

    @Test func customBindingRebindsSplitRight() {
        let ws = Self.makeWorkspace()
        // Rebind split_right to Ctrl+D (keyCode 2)
        let customBindings = KeyBindingMap.defaults.applying(overrides: [
            (KeyTrigger(keyCode: 2, modifiers: .command), .unbind),
            (KeyTrigger(keyCode: 2, modifiers: .control), .splitRight)
        ])
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID,
            keybindings: customBindings
        )

        // Ctrl+D should now split
        let ctrlD = keyEvent(keyCode: 2, modifierFlags: .control)
        #expect(monitor.handleKeyEvent(ctrlD) == true)
        #expect(store.workspaces[id: Self.wsID]!.panes.count == 2)
    }

    @Test func unboundDefaultPassesThrough() {
        let ws = Self.makeWorkspace()
        let customBindings = KeyBindingMap.defaults.applying(overrides: [
            (KeyTrigger(keyCode: 2, modifiers: .command), .unbind)
        ])
        let (_, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID,
            keybindings: customBindings
        )

        // Cmd+D should pass through (unbound)
        let cmdD = keyEvent(keyCode: 2, modifierFlags: .command)
        #expect(monitor.handleKeyEvent(cmdD) == false)
    }

    @Test func customBindingConditionalMarkdownToggle() {
        // Rebind toggle_markdown_edit to Cmd+M — should still only fire for markdown panes
        let customBindings = KeyBindingMap.defaults.applying(overrides: [
            (KeyTrigger(keyCode: 14, modifiers: .command), .unbind),
            (KeyTrigger(keyCode: 46, modifiers: .command), .toggleMarkdownEdit)
        ])

        // Shell pane: Cmd+M should NOT be consumed
        let shellWs = Self.makeWorkspace()
        let (_, shellMonitor) = makeStoreAndMonitor(
            workspaces: [shellWs],
            activeWorkspaceID: Self.wsID,
            keybindings: customBindings
        )
        let cmdM = keyEvent(keyCode: 46, modifierFlags: .command)
        #expect(shellMonitor.handleKeyEvent(cmdM) == false)

        // Markdown pane: Cmd+M SHOULD be consumed
        let mdPane = Pane(id: Self.paneID1, type: .markdown, filePath: "/tmp/test.md")
        let mdWs = WorkspaceFeature.State(
            id: Self.wsID, name: "Test", slug: "test", color: .blue,
            panes: [mdPane], layout: .leaf(Self.paneID1),
            focusedPaneID: Self.paneID1, createdAt: Date(), lastAccessedAt: Date()
        )
        let (mdStore, mdMonitor) = makeStoreAndMonitor(
            workspaces: [mdWs],
            activeWorkspaceID: Self.wsID,
            keybindings: customBindings
        )
        #expect(mdMonitor.handleKeyEvent(cmdM) == true)
        #expect(mdStore.workspaces[id: Self.wsID]?.panes[id: Self.paneID1]?.isEditing == true)
    }

    @Test func menuBarActionNotConsumedByMonitor() {
        let ws = Self.makeWorkspace()
        let (_, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        // Cmd+N (new_workspace) is a menu bar action — monitor should not consume
        let cmdN = keyEvent(keyCode: 45, modifierFlags: .command)
        #expect(monitor.handleKeyEvent(cmdN) == false)
    }
}
