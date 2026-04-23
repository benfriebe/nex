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
        activeWorkspaceID: UUID? = nil
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.activeWorkspaceID = activeWorkspaceID

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
}
