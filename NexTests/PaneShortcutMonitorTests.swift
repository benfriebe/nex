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
        appState.configHotkey.keybindings = keybindings
        // Mirror the reducer's load-time backfill — navigation actions
        // read `visibleWorkspaceOrder`, which is empty without this.
        appState.topLevelOrder = workspaces.map { .workspace($0.id) }

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

    // MARK: - Web pane priority layer (issue #229)

    /// Two-pane workspace where one pane is a web pane. The leaf order
    /// (first/second) drives focus-prev/next traversal, so callers place
    /// the web pane in the leaf position the test needs.
    private static func makeWebAndShellWorkspace(
        firstPaneID: UUID,
        secondPaneID: UUID,
        webPaneID: UUID,
        focusedPaneID: UUID
    ) -> WorkspaceFeature.State {
        WorkspaceFeature.State(
            id: wsID, name: "Test", slug: "test", color: .blue,
            panes: [
                Pane(id: firstPaneID, type: firstPaneID == webPaneID ? .web : .shell),
                Pane(id: secondPaneID, type: secondPaneID == webPaneID ? .web : .shell)
            ],
            layout: .split(.horizontal, ratio: 0.5, first: .leaf(firstPaneID), second: .leaf(secondPaneID)),
            focusedPaneID: focusedPaneID, createdAt: Date(), lastAccessedAt: Date()
        )
    }

    @Test func cmdOpenBracketInWebPaneFocusesPreviousPane() {
        // Issue #229: ⌘[ used to be swallowed by the web priority layer
        // (back). It now falls through to focus-previous even inside a
        // web pane. Web pane is the focused second leaf; ⌘[ moves to the
        // first (shell) leaf.
        let ws = Self.makeWebAndShellWorkspace(
            firstPaneID: Self.paneID1, secondPaneID: Self.paneID2,
            webPaneID: Self.paneID2, focusedPaneID: Self.paneID2
        )
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws], activeWorkspaceID: Self.wsID
        )

        let handled = monitor.handleKeyEvent(keyEvent(keyCode: 33, modifierFlags: .command))

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID1)
    }

    @Test func cmdCloseBracketInWebPaneFocusesNextPane() {
        // Web pane is the focused first leaf; ⌘] moves to the second
        // (shell) leaf instead of triggering forward.
        let ws = Self.makeWebAndShellWorkspace(
            firstPaneID: Self.paneID1, secondPaneID: Self.paneID2,
            webPaneID: Self.paneID1, focusedPaneID: Self.paneID1
        )
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws], activeWorkspaceID: Self.wsID
        )

        let handled = monitor.handleKeyEvent(keyEvent(keyCode: 30, modifierFlags: .command))

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID2)
    }

    @Test func cmdLeftArrowInWebPaneIsConsumedForBack() {
        // ⌘← is the new back binding: the priority layer consumes it and
        // does NOT change pane focus.
        let ws = Self.makeWebAndShellWorkspace(
            firstPaneID: Self.paneID1, secondPaneID: Self.paneID2,
            webPaneID: Self.paneID2, focusedPaneID: Self.paneID2
        )
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws], activeWorkspaceID: Self.wsID
        )

        let handled = monitor.handleKeyEvent(
            keyEvent(keyCode: 123, modifierFlags: [.command, .numericPad, .function])
        )

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID2)
    }

    @Test func cmdRightArrowInWebPaneIsConsumedForForward() {
        // ⌘→ is the new forward binding: consumed, focus unchanged.
        let ws = Self.makeWebAndShellWorkspace(
            firstPaneID: Self.paneID1, secondPaneID: Self.paneID2,
            webPaneID: Self.paneID1, focusedPaneID: Self.paneID1
        )
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws], activeWorkspaceID: Self.wsID
        )

        let handled = monitor.handleKeyEvent(
            keyEvent(keyCode: 124, modifierFlags: [.command, .numericPad, .function])
        )

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID1)
    }

    @Test func cmdArrowInShellPaneIsNotConsumed() {
        // The web back/forward binding is web-pane-only. In a shell pane
        // plain ⌘← / ⌘→ have no default binding, so the monitor must
        // defer (return false) and leave line-navigation to the terminal
        // — no regression for non-web panes.
        let ws = Self.makeTwoPaneWorkspace() // both shell, focus paneID1
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws], activeWorkspaceID: Self.wsID
        )

        let handledLeft = monitor.handleKeyEvent(
            keyEvent(keyCode: 123, modifierFlags: [.command, .numericPad, .function])
        )
        let handledRight = monitor.handleKeyEvent(
            keyEvent(keyCode: 124, modifierFlags: [.command, .numericPad, .function])
        )

        #expect(handledLeft == false)
        #expect(handledRight == false)
        #expect(store.workspaces[id: Self.wsID]?.focusedPaneID == Self.paneID1)
    }

    // MARK: - Open web pane (menu bar action)

    @Test func cmdShiftOIsNotConsumedByMonitor() {
        // ⌘⇧O opens a web pane (issue #206), but `openWebPane` is a
        // menu bar action — SwiftUI Commands owns its dispatch. The
        // NSEvent monitor must defer (return false) so the shortcut
        // fires exactly once and never double-dispatches.
        let ws = Self.makeWorkspace()
        let (_, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 31, modifierFlags: [.command, .shift])
        #expect(monitor.handleKeyEvent(event) == false)
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

    /// Regression test for issue #127: pressing ⌘W a second time after it
    /// deleted the only workspace (leaving no active workspace) must still
    /// be consumed — otherwise it falls through to AppKit's default
    /// "Close Window" and takes the app's only window with it.
    @Test func cmdWAfterLastWorkspaceDeletedIsStillConsumed() {
        let ws = Self.makeWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 13, modifierFlags: .command)
        #expect(monitor.handleKeyEvent(event) == true)
        #expect(store.activeWorkspaceID == nil)

        // The follow-up press, with no active workspace, must also be
        // consumed rather than falling through.
        #expect(monitor.handleKeyEvent(event) == true)
    }

    @Test func cmdWWithNoWorkspacesAtAllIsConsumed() {
        let (_, monitor) = makeStoreAndMonitor()
        let event = keyEvent(keyCode: 13, modifierFlags: .command)
        #expect(monitor.handleKeyEvent(event) == true)
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

    // MARK: - Rename workspace

    @Test func cmdShiftRBeginsRenameOfActiveWorkspace() {
        let ws = Self.makeWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 15, modifierFlags: [.command, .shift])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.renamingWorkspaceID == Self.wsID)
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

    // MARK: - Scratchpad

    @Test func cmdShiftNCreatesScratchpad() {
        let ws = Self.makeWorkspace()
        let (store, monitor) = makeStoreAndMonitor(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID
        )

        let event = keyEvent(keyCode: 45, modifierFlags: [.command, .shift])
        let handled = monitor.handleKeyEvent(event)

        #expect(handled == true)
        #expect(store.workspaces[id: Self.wsID]!.panes.count == 2)
        #expect(store.workspaces[id: Self.wsID]!.panes.last?.type == .scratchpad)
    }

    // MARK: - Secondary-window guard (issue #251)

    // Regression + reproduction for issue #251: pane shortcuts intermittently
    // stopped working (Cmd+W closed the whole window, Cmd+D no-op) because the
    // guard identified "the main window" positionally via
    // `NSApp.windows.first(where:)`, whose ordering AppKit does not guarantee.
    // These exercise the decision directly with real window identities.

    @Test func doesNotDeferWhenNoKeyWindow() {
        // No key window (the state in unit tests) — never defer.
        #expect(
            PaneShortcutMonitor.shouldDeferToSecondaryWindow(
                keyWindow: nil, primary: nil, mainWindowCandidate: nil
            ) == false
        )
    }

    @Test func doesNotDeferWhenKeyWindowIsPrimary() {
        let main = NSWindow()
        // The main window is key and is the registered primary — consume shortcuts.
        #expect(
            PaneShortcutMonitor.shouldDeferToSecondaryWindow(
                keyWindow: main, primary: main, mainWindowCandidate: nil
            ) == false
        )
    }

    @Test func defersWhenSecondaryWindowIsKey() {
        let main = NSWindow()
        let settings = NSWindow()
        // Settings/Help is key — defer so its own Cmd+W etc. still work.
        #expect(
            PaneShortcutMonitor.shouldDeferToSecondaryWindow(
                keyWindow: settings, primary: main, mainWindowCandidate: main
            ) == true
        )
    }

    @Test func doesNotDeferWhenPrimarySetDespiteMisorderedCandidate() {
        let main = NSWindow()
        let stray = NSWindow()
        // The exact issue #251 trigger: the focused main window is key, but a
        // stray visible window sorts ahead in `NSApp.windows`, so the positional
        // candidate resolves to `stray`. With the authoritative primary set, we
        // must still recognise `main` as the main window and NOT defer.
        #expect(
            PaneShortcutMonitor.shouldDeferToSecondaryWindow(
                keyWindow: main, primary: main, mainWindowCandidate: stray
            ) == false
        )
    }

    @Test func fallsBackToPositionalCandidateBeforePrimaryClaimed() {
        let main = NSWindow()
        let stray = NSWindow()
        // Before the registry claims a primary (`primary == nil`), the old
        // positional heuristic still applies: when the candidate matches the
        // key window we consume; when a stray sorts ahead we defer. The second
        // case is precisely the fragile pre-fix behaviour that #251 hit — now
        // confined to the brief pre-registration window.
        #expect(
            PaneShortcutMonitor.shouldDeferToSecondaryWindow(
                keyWindow: main, primary: nil, mainWindowCandidate: main
            ) == false
        )
        #expect(
            PaneShortcutMonitor.shouldDeferToSecondaryWindow(
                keyWindow: main, primary: nil, mainWindowCandidate: stray
            ) == true
        )
    }
}
