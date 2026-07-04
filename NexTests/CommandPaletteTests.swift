import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct CommandPaletteTests {
    // MARK: - Helpers

    private static let wsID1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let wsID2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private static let paneID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let paneID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let paneID3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private static func makeWorkspace(
        id: UUID,
        name: String,
        color: WorkspaceColor = .blue,
        panes: [Pane],
        layout: PaneLayout,
        focusedPaneID: UUID? = nil
    ) -> WorkspaceFeature.State {
        WorkspaceFeature.State(
            id: id, name: name, slug: name.lowercased(), color: color,
            panes: IdentifiedArray(uniqueElements: panes), layout: layout,
            focusedPaneID: focusedPaneID ?? panes.first?.id,
            createdAt: Date(), lastAccessedAt: Date()
        )
    }

    private func makeStore(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [],
        activeWorkspaceID: UUID? = nil,
        surfaceManager: SurfaceManager = SurfaceManager(),
        clock: any Clock<Duration> = ImmediateClock()
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.activeWorkspaceID = activeWorkspaceID

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = clock
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    // MARK: - Toggle

    @Test func toggleOpensAndResets() async {
        let store = makeStore()

        await store.send(.toggleCommandPalette) { state in
            state.isCommandPaletteVisible = true
            state.commandPaletteQuery = ""
            state.commandPaletteSelectedIndex = 0
        }

        await store.send(.toggleCommandPalette) { state in
            state.isCommandPaletteVisible = false
        }
    }

    @Test func toggleResetsQueryAndSelection() async {
        var appState = AppReducer.State()
        appState.commandPaletteQuery = "old"
        appState.commandPaletteSelectedIndex = 3
        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleCommandPalette) { state in
            state.isCommandPaletteVisible = true
            state.commandPaletteQuery = ""
            state.commandPaletteSelectedIndex = 0
        }
    }

    @Test func dismissClears() async {
        var appState = AppReducer.State()
        appState.isCommandPaletteVisible = true
        appState.commandPaletteQuery = "test"
        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.dismissCommandPalette) { state in
            state.isCommandPaletteVisible = false
            state.commandPaletteQuery = ""
        }
    }

    // MARK: - Query Filtering

    @Test func queryFilterResetsSelection() async {
        var appState = AppReducer.State()
        appState.commandPaletteSelectedIndex = 2
        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.commandPaletteQueryChanged("test")) { state in
            state.commandPaletteQuery = "test"
            state.commandPaletteSelectedIndex = 0
        }
    }

    @Test func itemsIncludeWorkspacesAndPanes() {
        let pane1 = Pane(id: Self.paneID1, workingDirectory: "/Users/test/code")
        let pane2 = Pane(id: Self.paneID2, workingDirectory: "/Users/test/docs")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "Dev",
            panes: [pane1, pane2],
            layout: .split(.horizontal, ratio: 0.5,
                           first: .leaf(Self.paneID1), second: .leaf(Self.paneID2))
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        // 1 workspace + 2 panes = 3 items
        #expect(state.commandPaletteItems.count == 3)
        #expect(state.commandPaletteItems[0].paneID == nil) // workspace item
        #expect(state.commandPaletteItems[1].paneID == Self.paneID1)
        #expect(state.commandPaletteItems[2].paneID == Self.paneID2)
    }

    @Test func queryFiltersItems() {
        let pane1 = Pane(id: Self.paneID1, label: "server", workingDirectory: "/tmp")
        let pane2 = Pane(id: Self.paneID2, label: "client", workingDirectory: "/tmp")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "MyProject",
            panes: [pane1, pane2],
            layout: .split(.horizontal, ratio: 0.5,
                           first: .leaf(Self.paneID1), second: .leaf(Self.paneID2))
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        state.commandPaletteQuery = "server"
        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].paneID == Self.paneID1)
    }

    @Test func queryWithMultipleTermsMatchesAll() {
        let pane1 = Pane(id: Self.paneID1, label: "pane-for-me", workingDirectory: "/tmp")
        let pane2 = Pane(id: Self.paneID2, label: "pane-for-you", workingDirectory: "/tmp")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "MyProject",
            panes: [pane1, pane2],
            layout: .split(.horizontal, ratio: 0.5,
                           first: .leaf(Self.paneID1), second: .leaf(Self.paneID2))
        )

        var state = AppReducer.State()
        state.workspaces = [ws]

        // Single term matches both panes + workspace (subtitle "2 panes" contains "pane")
        state.commandPaletteQuery = "pane-for"
        #expect(state.commandPaletteItems.count == 2)

        // Two terms narrows to one
        state.commandPaletteQuery = "pane me"
        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].paneID == Self.paneID1)
    }

    @Test func queryMatchesAcrossTitleAndSubtitle() {
        let pane1 = Pane(id: Self.paneID1, label: "server", workingDirectory: "/tmp")
        let pane2 = Pane(id: Self.paneID2, label: "server", workingDirectory: "/tmp")
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "Alpha",
            panes: [pane1], layout: .leaf(Self.paneID1)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "Beta",
            panes: [pane2], layout: .leaf(Self.paneID2)
        )

        var state = AppReducer.State()
        state.workspaces = [ws1, ws2]

        // "server" matches both panes
        state.commandPaletteQuery = "server"
        #expect(state.commandPaletteItems.count == 2)

        // "server alpha" narrows to the pane in workspace Alpha
        state.commandPaletteQuery = "server alpha"
        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].workspaceID == Self.wsID1)
    }

    @Test func emptyQueryReturnsAll() {
        let pane = Pane(id: Self.paneID1)
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "WS",
            panes: [pane], layout: .leaf(Self.paneID1)
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        state.commandPaletteQuery = ""
        #expect(state.commandPaletteItems.count == 2) // 1 workspace + 1 pane
    }

    // MARK: - Scope Prefixes (w: / p:)

    /// Fixture where a pane label collides with the workspace name term so
    /// scope tests can prove cross-scope exclusion (i.e. `w:loy` returns the
    /// "Loyalty" workspace and NOT the pane labeled "loyal-server").
    private static func collidingNameWorkspaces() -> [WorkspaceFeature.State] {
        let pane1 = Pane(id: Self.paneID1, label: "loyal-server", workingDirectory: "/tmp")
        let pane2 = Pane(id: Self.paneID2, label: "client", workingDirectory: "/tmp")
        let pane3 = Pane(id: Self.paneID3, label: "default-shell", workingDirectory: "/tmp")
        let ws1 = makeWorkspace(
            id: Self.wsID1, name: "Loyalty",
            panes: [pane1, pane2],
            layout: .split(.horizontal, ratio: 0.5,
                           first: .leaf(Self.paneID1), second: .leaf(Self.paneID2))
        )
        let ws2 = makeWorkspace(
            id: Self.wsID2, name: "Default",
            panes: [pane3], layout: .leaf(Self.paneID3)
        )
        return [ws1, ws2]
    }

    @Test func workspacePrefixScopesToWorkspacesOnly() {
        var state = AppReducer.State()
        state.workspaces = IdentifiedArray(uniqueElements: Self.collidingNameWorkspaces())
        state.commandPaletteQuery = "w:"

        let items = state.commandPaletteItems
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.paneID == nil })
    }

    @Test func workspacePrefixWithTermExcludesMatchingPanes() {
        // Without the scope, "loy" matches both the "Loyalty" workspace AND
        // the pane "loyal-server" (and arguably "client" via workspaceName).
        // The `w:` prefix must drop everything but the workspace.
        var state = AppReducer.State()
        state.workspaces = IdentifiedArray(uniqueElements: Self.collidingNameWorkspaces())

        // Sanity: bare term matches both kinds.
        state.commandPaletteQuery = "loy"
        #expect(state.commandPaletteItems.contains { $0.paneID == Self.paneID1 })

        // With the prefix, only the workspace remains.
        state.commandPaletteQuery = "w:loy"
        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].paneID == nil)
        #expect(items[0].workspaceID == Self.wsID1)
    }

    @Test func panePrefixScopesToPanesOnly() {
        var state = AppReducer.State()
        state.workspaces = IdentifiedArray(uniqueElements: Self.collidingNameWorkspaces())
        state.commandPaletteQuery = "p:"

        let items = state.commandPaletteItems
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.paneID != nil })
    }

    @Test func panePrefixWithTermExcludesMatchingWorkspaces() {
        // Without the scope, "default" matches the "Default" workspace AND
        // the pane "default-shell". The `p:` prefix must drop the workspace.
        var state = AppReducer.State()
        state.workspaces = IdentifiedArray(uniqueElements: Self.collidingNameWorkspaces())

        state.commandPaletteQuery = "default"
        #expect(state.commandPaletteItems.contains { $0.paneID == nil && $0.workspaceID == Self.wsID2 })

        state.commandPaletteQuery = "p:default"
        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].paneID == Self.paneID3)
    }

    @Test func prefixIsCaseInsensitive() {
        var state = AppReducer.State()
        state.workspaces = IdentifiedArray(uniqueElements: Self.collidingNameWorkspaces())
        state.commandPaletteQuery = "W:LOY"

        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].workspaceID == Self.wsID1)
    }

    @Test func prefixToleratesLeadingWhitespace() {
        // Pasted queries or accidental leading spaces should still trigger
        // the prefix, since the user clearly meant the scope.
        var state = AppReducer.State()
        state.workspaces = IdentifiedArray(uniqueElements: Self.collidingNameWorkspaces())
        state.commandPaletteQuery = "  w:loy"

        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].paneID == nil)
        #expect(items[0].workspaceID == Self.wsID1)
    }

    @Test func prefixWithTrailingWhitespaceReturnsScopedAll() {
        var state = AppReducer.State()
        state.workspaces = IdentifiedArray(uniqueElements: Self.collidingNameWorkspaces())
        state.commandPaletteQuery = "w:   "

        let items = state.commandPaletteItems
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.paneID == nil })
    }

    @Test func prefixDoesNotApplyMidQuery() {
        // The literal string "w:" appearing mid-query is not a prefix.
        let pane1 = Pane(id: Self.paneID1, label: "w:report", workingDirectory: "/tmp")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "Dev",
            panes: [pane1], layout: .leaf(Self.paneID1)
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        state.commandPaletteQuery = "report w:"
        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].paneID == Self.paneID1)
    }

    // MARK: - Navigation

    @Test func selectNextClampsToEnd() async {
        let pane = Pane(id: Self.paneID1)
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "WS",
            panes: [pane], layout: .leaf(Self.paneID1)
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        // 2 items (workspace + pane), start at 0
        await store.send(.commandPaletteSelectNext) { state in
            state.commandPaletteSelectedIndex = 1
        }
        // Already at end, should stay at 1
        await store.send(.commandPaletteSelectNext)
        #expect(store.state.commandPaletteSelectedIndex == 1)
    }

    @Test func selectPreviousClampsToZero() async {
        let store = makeStore()

        await store.send(.commandPaletteSelectPrevious)
        #expect(store.state.commandPaletteSelectedIndex == 0)
    }

    @Test func selectIndexClampsToValidRange() async {
        let pane = Pane(id: Self.paneID1)
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "WS",
            panes: [pane], layout: .leaf(Self.paneID1)
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        // 2 items (workspace + pane)
        await store.send(.commandPaletteSelectIndex(1)) { state in
            state.commandPaletteSelectedIndex = 1
        }
        // Out of range clamps to last
        await store.send(.commandPaletteSelectIndex(99)) { state in
            state.commandPaletteSelectedIndex = 1
        }
        // Negative clamps to 0
        await store.send(.commandPaletteSelectIndex(-1)) { state in
            state.commandPaletteSelectedIndex = 0
        }
    }

    // MARK: - Item Content

    @Test func paneWithLabelAndTitleShowsBoth() {
        let pane = Pane(id: Self.paneID1, label: "api", title: "vim main.go", workingDirectory: "/tmp")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "Dev",
            panes: [pane], layout: .leaf(Self.paneID1)
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        let paneItem = state.commandPaletteItems[1]
        #expect(paneItem.title == "api")
        #expect(paneItem.subtitle == "vim main.go")
    }

    @Test func paneWithLabelOnlyShowsPath() {
        let pane = Pane(id: Self.paneID1, label: "api", workingDirectory: "/tmp/project")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "Dev",
            panes: [pane], layout: .leaf(Self.paneID1)
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        let paneItem = state.commandPaletteItems[1]
        #expect(paneItem.title == "api")
        #expect(paneItem.subtitle == "/tmp/project")
    }

    @Test func scratchpadPaneAppearsWithIconAndTitle() {
        let pane = Pane(id: Self.paneID1, type: .scratchpad, title: "Scratchpad")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "MyProject",
            panes: [pane], layout: .leaf(Self.paneID1)
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        let paneItem = state.commandPaletteItems[1]
        #expect(paneItem.paneID == Self.paneID1)
        #expect(paneItem.title == "Scratchpad")
        #expect(paneItem.icon == "note.text")
        #expect(paneItem.workspaceName == "MyProject")
    }

    @Test func paneItemsHaveWorkspaceName() {
        let pane = Pane(id: Self.paneID1, workingDirectory: "/tmp")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "MyProject",
            panes: [pane], layout: .leaf(Self.paneID1)
        )

        var state = AppReducer.State()
        state.workspaces = [ws]
        let paneItem = state.commandPaletteItems[1]
        #expect(paneItem.workspaceName == "MyProject")
    }

    @Test func labeledPaneSearchableByPath() {
        let pane1 = Pane(id: Self.paneID1, label: "api", workingDirectory: "/code/frontend")
        let pane2 = Pane(id: Self.paneID2, label: "api", workingDirectory: "/code/backend")
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "Dev",
            panes: [pane1, pane2],
            layout: .split(.horizontal, ratio: 0.5,
                           first: .leaf(Self.paneID1), second: .leaf(Self.paneID2))
        )

        var state = AppReducer.State()
        state.workspaces = [ws]

        // Both match by label
        state.commandPaletteQuery = "api"
        #expect(state.commandPaletteItems.count == 2)

        // Narrow by path
        state.commandPaletteQuery = "api backend"
        let items = state.commandPaletteItems
        #expect(items.count == 1)
        #expect(items[0].paneID == Self.paneID2)
    }

    // MARK: - Confirm

    @Test func confirmWorkspaceSwitchesWorkspace() async {
        let pane1 = Pane(id: Self.paneID1)
        let pane2 = Pane(id: Self.paneID2)
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "First",
            panes: [pane1], layout: .leaf(Self.paneID1)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "Second",
            panes: [pane2], layout: .leaf(Self.paneID2)
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        // Open palette, select workspace "Second" (index 2: ws1, pane1, ws2, pane2)
        await store.send(.toggleCommandPalette)
        await store.send(.commandPaletteSelectNext) // index 1 = pane1
        await store.send(.commandPaletteSelectNext) // index 2 = ws2
        await store.send(.commandPaletteConfirm)

        #expect(store.state.isCommandPaletteVisible == false)
        #expect(store.state.activeWorkspaceID == Self.wsID2)
        // Issue #187: the jumped-to workspace scrolls into view.
        #expect(store.state.sidebarScrollTarget == .workspace(Self.wsID2))
    }

    @Test func confirmPaneFocusesPaneAndSwitchesWorkspace() async {
        let pane1 = Pane(id: Self.paneID1)
        let pane2 = Pane(id: Self.paneID2)
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "First",
            panes: [pane1], layout: .leaf(Self.paneID1)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "Second",
            panes: [pane2], layout: .leaf(Self.paneID2)
        )
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        // Open palette, select pane2 (index 3: ws1, pane1, ws2, pane2)
        await store.send(.toggleCommandPalette)
        await store.send(.commandPaletteSelectNext) // 1
        await store.send(.commandPaletteSelectNext) // 2
        await store.send(.commandPaletteSelectNext) // 3
        await store.send(.commandPaletteConfirm)

        #expect(store.state.isCommandPaletteVisible == false)
        #expect(store.state.activeWorkspaceID == Self.wsID2)
    }

    @Test func confirmPaneInSameWorkspaceDoesNotSwitchWorkspace() async {
        let pane1 = Pane(id: Self.paneID1)
        let pane2 = Pane(id: Self.paneID2)
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "WS",
            panes: [pane1, pane2],
            layout: .split(.horizontal, ratio: 0.5,
                           first: .leaf(Self.paneID1), second: .leaf(Self.paneID2)),
            focusedPaneID: Self.paneID1
        )
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        // Select pane2 (index 2: ws, pane1, pane2)
        await store.send(.toggleCommandPalette)
        await store.send(.commandPaletteSelectNext) // 1
        await store.send(.commandPaletteSelectNext) // 2
        await store.send(.commandPaletteConfirm)

        #expect(store.state.isCommandPaletteVisible == false)
        #expect(store.state.activeWorkspaceID == Self.wsID1)
    }

    @Test func confirmWithNoItemsDismisses() async {
        var appState = AppReducer.State()
        appState.isCommandPaletteVisible = true
        appState.commandPaletteQuery = "nonexistent"
        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.commandPaletteConfirm) { state in
            state.isCommandPaletteVisible = false
        }
    }

    // MARK: - Focus handoff on close

    @Test func confirmPaneFocusesDestinationSurface() async {
        let manager = SurfaceManager()
        let pane1 = Pane(id: Self.paneID1)
        let pane2 = Pane(id: Self.paneID2)
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "WS",
            panes: [pane1, pane2],
            layout: .split(.horizontal, ratio: 0.5,
                           first: .leaf(Self.paneID1), second: .leaf(Self.paneID2)),
            focusedPaneID: Self.paneID1
        )
        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1,
            surfaceManager: manager
        )

        await store.send(.toggleCommandPalette)
        await store.send(.commandPaletteSelectNext) // 1 — pane1
        await store.send(.commandPaletteSelectNext) // 2 — pane2
        await store.send(.commandPaletteConfirm)
        await store.finish()

        #expect(manager.focusCalls == [Self.paneID2])
    }

    @Test func confirmWorkspaceFocusesItsActivePane() async {
        let manager = SurfaceManager()
        let pane1 = Pane(id: Self.paneID1)
        let pane2 = Pane(id: Self.paneID2)
        let pane3 = Pane(id: Self.paneID3)
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "First",
            panes: [pane1], layout: .leaf(Self.paneID1)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "Second",
            panes: [pane2, pane3],
            layout: .split(.vertical, ratio: 0.5,
                           first: .leaf(Self.paneID2), second: .leaf(Self.paneID3)),
            focusedPaneID: Self.paneID3
        )
        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1,
            surfaceManager: manager
        )

        // index 2 selects ws2 (no explicit paneID)
        await store.send(.toggleCommandPalette)
        await store.send(.commandPaletteSelectNext)
        await store.send(.commandPaletteSelectNext)
        await store.send(.commandPaletteConfirm)
        await store.finish()

        #expect(manager.focusCalls == [Self.paneID3])
    }

    @Test func dismissFocusesActiveWorkspacePane() async {
        let manager = SurfaceManager()
        let pane1 = Pane(id: Self.paneID1)
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "WS",
            panes: [pane1], layout: .leaf(Self.paneID1),
            focusedPaneID: Self.paneID1
        )
        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1,
            surfaceManager: manager
        )

        await store.send(.toggleCommandPalette)
        await store.send(.dismissCommandPalette)
        await store.finish()

        #expect(manager.focusCalls == [Self.paneID1])
    }

    @Test func reopeningCancelsPendingFocus() async {
        let manager = SurfaceManager()
        let clock = TestClock()
        let pane1 = Pane(id: Self.paneID1)
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "WS",
            panes: [pane1], layout: .leaf(Self.paneID1),
            focusedPaneID: Self.paneID1
        )
        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1,
            surfaceManager: manager,
            clock: clock
        )

        // Open → dismiss: schedules a delayed focus.
        await store.send(.toggleCommandPalette)
        await store.send(.dismissCommandPalette)
        // Reopen before the handoff delay elapses — the pending focus
        // must be cancelled so it can't steal focus from the new palette.
        await store.send(.toggleCommandPalette)
        await clock.advance(by: AppReducer.paletteFocusHandoffDelay * 2)
        await store.finish()

        #expect(manager.focusCalls.isEmpty)
    }
}
