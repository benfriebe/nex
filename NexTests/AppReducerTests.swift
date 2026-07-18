import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct AppReducerTests {
    // MARK: - Helpers

    private func makeStore(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [],
        activeWorkspaceID: UUID? = nil,
        repoRegistry: IdentifiedArrayOf<Repo> = [],
        pendingFileOpens: [String] = []
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.activeWorkspaceID = activeWorkspaceID
        appState.repoRegistry = repoRegistry
        appState.pendingFileOpens = pendingFileOpens
        // Mirror the backfill the reducer applies on load: when no
        // groups are in play, `topLevelOrder` is the workspaces list.
        // Without this, `visibleWorkspaceOrder` (used by range-select,
        // Cmd+N numbering, etc.) is empty in tests constructed
        // directly from state.
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

    private static let wsID1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let wsID2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private static let paneID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let paneID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private static func makeWorkspace(
        id: UUID,
        name: String,
        color: WorkspaceColor = .blue,
        paneID: UUID? = nil,
        lastAccessedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> WorkspaceFeature.State {
        let pid = paneID ?? UUID()
        return WorkspaceFeature.State(
            id: id, name: name, slug: name.lowercased(), color: color,
            panes: [Pane(id: pid)], layout: .leaf(pid),
            focusedPaneID: pid, createdAt: Date(), lastAccessedAt: lastAccessedAt
        )
    }

    // MARK: - openWebPanePath (⌘⇧O / menu / context-menu entry point)

    @Test func openWebPanePathAddsWebPaneAndFocusesURLBar() async {
        // All three GUI entry points from issue #206 (the ⌘⇧O binding,
        // the "New Web Pane" menu item, and the pane-header context
        // menu) converge on `.openWebPanePath(url: "", fromPaneID: nil)`.
        // Verify it opens a `.web` pane in the active workspace and
        // bumps the URL-bar focus token for the blank tab.
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "Test", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.openWebPanePath(url: "", fromPaneID: nil))
        // Drain the forwarded `.workspaces(.openWebPane(...))` action.
        await store.skipReceivedActions()

        let webPanes = store.state.workspaces[id: Self.wsID1]?
            .panes.filter { $0.type == .web } ?? []
        #expect(webPanes.count == 1)
        // Blank URL → the fresh pane's URL bar is focused (token bumped).
        if let webPaneID = webPanes.first?.id {
            #expect(store.state.webPaneURLFocusTokens[webPaneID] == 1)
        } else {
            Issue.record("Expected a web pane after openWebPanePath")
        }
    }

    @Test func openWebPanePathSplitsSourcePaneInGivenDirection() async {
        // The header globe button / context menu split off a SPECIFIC
        // pane (issue #206): `fromPaneID` is the split source and
        // `direction` picks right (.horizontal) vs down (.vertical).
        // ⇧-click the globe → a vertical split off that pane.
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "Test", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.openWebPanePath(
            url: "", fromPaneID: Self.paneID1, direction: .vertical
        ))
        await store.skipReceivedActions()

        let workspace = store.state.workspaces[id: Self.wsID1]
        let webPanes = workspace?.panes.filter { $0.type == .web } ?? []
        #expect(webPanes.count == 1)
        // The source pane was split vertically (down), not right.
        if case .split(let dir, _, _, _) = workspace?.layout {
            #expect(dir == .vertical)
        } else {
            Issue.record("Expected a vertical split layout after ⇧-click open")
        }
    }

    // MARK: - Open With: markdown file open + cold-launch queue (#197)

    @Test func openFileAtPathQueuesWhenNoWorkspaceYet() async {
        // Cold launch: Finder's "Open With" fires before the async state
        // load has created a workspace. The path is parked in
        // `pendingFileOpens` instead of being dropped.
        let store = makeStore() // no workspace; activeWorkspaceID == nil

        await store.send(.openFileAtPath("/tmp/notes.md", fromPaneID: nil)) { state in
            #expect(state.pendingFileOpens == ["/tmp/notes.md"])
        }
    }

    @Test func openFileAtPathRoutesImmediatelyWhenWorkspaceExists() async {
        // Already running: the path routes straight to `.openMarkdownFile`
        // and never touches the cold-launch queue.
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.openFileAtPath("/tmp/notes.md", fromPaneID: nil)) { state in
            #expect(state.pendingFileOpens.isEmpty)
        }
        await store.skipReceivedActions()

        let markdownPanes = store.state.workspaces[id: Self.wsID1]?
            .panes.filter { $0.type == .markdown } ?? []
        #expect(markdownPanes.count == 1)
        #expect(markdownPanes.first?.filePath == "/tmp/notes.md")
    }

    @Test func flushPendingFileOpensDrainsAndClearsQueue() async {
        // The drain replays every parked path AND empties the queue, so a
        // later `createWorkspace` can't resurrect stale opens as phantom
        // panes (openMarkdownFile has no dedup).
        // Seed pane id is deliberately outside the `.incrementing` UUID
        // range so the two freshly minted markdown pane ids (UUID(0),
        // UUID(1)) can't collide with it and get dropped by IdentifiedArray.
        let seedPane = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: seedPane)
        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1,
            pendingFileOpens: ["/tmp/a.md", "/tmp/b.md"]
        )

        await store.send(.flushPendingFileOpens) { state in
            #expect(state.pendingFileOpens.isEmpty)
        }
        // Both parked paths are replayed as `.openFileAtPath` (queued first),
        // then each routed to the active workspace as a new markdown pane.
        await store.receive(\.openFileAtPath)
        await store.receive(\.openFileAtPath)
        await store.receive(\.workspaces)
        await store.receive(\.workspaces)
        await store.skipReceivedActions()

        let markdownPanes = store.state.workspaces[id: Self.wsID1]?
            .panes.filter { $0.type == .markdown } ?? []
        #expect(markdownPanes.count == 2)
    }

    @Test func stateLoadedEmptyBranchDrainsPendingFileOpens() async {
        // End-to-end cold launch on a fresh install: a queued open survives
        // until `.stateLoaded` (empty DB) creates the Default workspace and
        // then drains the queue via `.flushPendingFileOpens`.
        let store = makeStore()

        await store.send(.openFileAtPath("/tmp/notes.md", fromPaneID: nil)) { state in
            #expect(state.pendingFileOpens == ["/tmp/notes.md"])
        }

        await store.send(.stateLoaded(
            [], groups: [], topLevelOrder: [], activeWorkspaceID: nil, repoRegistry: []
        ))
        // Default workspace is created first (sets activeWorkspaceID)...
        await store.receive(\.createWorkspace)
        // ...then the parked open is drained and the queue cleared.
        await store.receive(\.flushPendingFileOpens) { state in
            #expect(state.pendingFileOpens.isEmpty)
        }
    }

    // MARK: - createWorkspace

    @Test func createWorkspaceAddsWorkspaceAndActivates() async {
        let store = makeStore()

        await store.send(.createWorkspace(name: "Test", color: .green)) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces.first?.name == "Test")
            #expect(state.workspaces.first?.color == .green)
            #expect(state.activeWorkspaceID == state.workspaces.first?.id)
            #expect(state.isNewWorkspaceSheetPresented == false)
        }
    }

    @Test func createWorkspaceSetsSidebarScrollTarget() async {
        // Issue #187: a fresh workspace queues itself to be scrolled into
        // view; `clearSidebarScrollTarget` consumes the one-shot signal.
        let store = makeStore()

        await store.send(.createWorkspace(name: "Test", color: .green)) { state in
            let newID = state.workspaces.first?.id
            #expect(newID != nil)
            #expect(state.sidebarScrollTarget == .workspace(newID!))
        }
        await store.send(.clearSidebarScrollTarget) { state in
            #expect(state.sidebarScrollTarget == nil)
        }
    }

    @Test func createWorkspaceWithoutColorPicksNonRepeatingColor() async {
        // Seed with an existing workspace whose color is red, then create a new
        // workspace without specifying a color. The reducer should resolve the
        // default via nextRandomColor(), which must not return red.
        let existing = Self.makeWorkspace(id: Self.wsID1, name: "Existing", color: .red, paneID: Self.paneID1)
        let store = makeStore(workspaces: [existing], activeWorkspaceID: Self.wsID1)

        await store.send(.createWorkspace(name: "New"))

        #expect(store.state.workspaces.count == 2)
        let newColor = store.state.workspaces.last?.color
        #expect(newColor != nil)
        #expect(newColor != .red)
        #expect(WorkspaceColor.allCases.contains(newColor!))
    }

    @Test func createWorkspaceWithSingleRepoSetsWorkingDirectory() async {
        let repo = Repo(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            path: "/Users/test/myrepo",
            name: "myrepo"
        )
        let store = makeStore()

        await store.send(.createWorkspace(name: "Repo WS", color: .blue, repos: [repo])) { state in
            state.repoRegistry.append(repo)
            #expect(state.workspaces.count == 1)
            let ws = state.workspaces.first!
            #expect(ws.panes.first?.workingDirectory == "/Users/test/myrepo")
            #expect(ws.repoAssociations.count == 1)
            #expect(ws.repoAssociations.first?.repoID == repo.id)
        }
    }

    @Test func createWorkspaceWithGroupIDPlacesInGroupChildOrder() async {
        // Seed a group containing wsID1 (active). Creating a new workspace with
        // that group's ID should add it to the group's childOrder (not to
        // topLevelOrder). Default placement appends to the end of the group.
        let existing = Self.makeWorkspace(id: Self.wsID1, name: "Existing", paneID: Self.paneID1)
        let groupID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        let group = WorkspaceGroup(id: groupID, name: "Work", childOrder: [Self.wsID1])

        var appState = AppReducer.State()
        appState.workspaces = [existing]
        appState.groups = [group]
        appState.topLevelOrder = [.group(groupID)]
        appState.activeWorkspaceID = Self.wsID1

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

        await store.send(.createWorkspace(name: "New", groupID: groupID))

        let newID = store.state.workspaces.last!.id
        #expect(store.state.workspaces.count == 2)
        #expect(store.state.groups[id: groupID]?.childOrder == [Self.wsID1, newID])
        #expect(store.state.topLevelOrder == [.group(groupID)])
        #expect(store.state.activeWorkspaceID == newID)
    }

    @Test func createWorkspaceTopLevelDefaultAppendsToEndOfList() async {
        // Default (`newWorkspacePlacement == .endOfList`): a new top-level
        // workspace is appended to the bottom of the sidebar regardless of
        // which workspace is active.
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "C", paneID: UUID())
        let store = makeStore(workspaces: [ws1, ws2, ws3], activeWorkspaceID: Self.wsID2)

        await store.send(.createWorkspace(name: "New"))

        let newID = store.state.workspaces.last!.id
        #expect(store.state.topLevelOrder == [
            .workspace(Self.wsID1),
            .workspace(Self.wsID2),
            .workspace(wsID3),
            .workspace(newID)
        ])
    }

    @Test func createWorkspaceTopLevelNearSelectionInsertsAfterActive() async {
        // With `newWorkspacePlacement == .nearSelection`, a new top-level
        // workspace slots in immediately after the active workspace's
        // sidebar entry instead of appending to the bottom.
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "C", paneID: UUID())

        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.topLevelOrder = [
            .workspace(Self.wsID1),
            .workspace(Self.wsID2),
            .workspace(wsID3)
        ]
        appState.activeWorkspaceID = Self.wsID2
        appState.settings.newWorkspacePlacement = .nearSelection

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

        await store.send(.createWorkspace(name: "New"))

        let newID = store.state.workspaces.last!.id
        #expect(store.state.topLevelOrder == [
            .workspace(Self.wsID1),
            .workspace(Self.wsID2),
            .workspace(newID),
            .workspace(wsID3)
        ])
    }

    @Test func createWorkspaceInGroupDefaultAppendsToGroupEnd() async {
        // Default (`newWorkspacePlacement == .endOfList`): a new workspace
        // created into a group is appended to the end of its childOrder
        // regardless of which child is currently active.
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "C", paneID: UUID())
        let groupID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000003")!
        let group = WorkspaceGroup(id: groupID, name: "Work", childOrder: [Self.wsID1, Self.wsID2, wsID3])

        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.groups = [group]
        appState.topLevelOrder = [.group(groupID)]
        // Active is the middle child; default placement should still append.
        appState.activeWorkspaceID = Self.wsID2

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

        await store.send(.createWorkspace(name: "New", groupID: groupID))

        let newID = store.state.workspaces.last!.id
        #expect(store.state.groups[id: groupID]?.childOrder == [Self.wsID1, Self.wsID2, wsID3, newID])
    }

    @Test func createWorkspaceInGroupNearSelectionInsertsAfterActive() async {
        // With `newWorkspacePlacement == .nearSelection`, a new in-group
        // workspace is inserted directly after the active workspace's slot
        // in that group's childOrder instead of appending to the end.
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "C", paneID: UUID())
        let groupID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000004")!
        let group = WorkspaceGroup(id: groupID, name: "Work", childOrder: [Self.wsID1, Self.wsID2, wsID3])

        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.groups = [group]
        appState.topLevelOrder = [.group(groupID)]
        appState.activeWorkspaceID = Self.wsID2
        appState.settings.newWorkspacePlacement = .nearSelection

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

        await store.send(.createWorkspace(name: "New", groupID: groupID))

        let newID = store.state.workspaces.last!.id
        #expect(store.state.groups[id: groupID]?.childOrder == [Self.wsID1, Self.wsID2, newID, wsID3])
    }

    @Test func createWorkspaceWithGroupIDExpandsCollapsedGroup() async {
        // When inheriting into a collapsed group, the group must auto-expand so
        // the newly-active workspace isn't hidden in the sidebar. Mirrors the
        // auto-expand behavior on .setActiveWorkspace.
        let existing = Self.makeWorkspace(id: Self.wsID1, name: "Existing", paneID: Self.paneID1)
        let groupID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let group = WorkspaceGroup(id: groupID, name: "Work", isCollapsed: true, childOrder: [Self.wsID1])

        var appState = AppReducer.State()
        appState.workspaces = [existing]
        appState.groups = [group]
        appState.topLevelOrder = [.group(groupID)]
        appState.activeWorkspaceID = Self.wsID1

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

        await store.send(.createWorkspace(name: "New", groupID: groupID))

        #expect(store.state.groups[id: groupID]?.isCollapsed == false)
    }

    @Test func createWorkspaceWithUnknownGroupIDFallsBackToTopLevel() async {
        // Defensive path: if the supplied groupID doesn't exist (e.g. the group
        // was deleted between sheet presentation and create), fall back to
        // top-level append instead of silently dropping the workspace.
        let store = makeStore()
        let missingGroupID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

        await store.send(.createWorkspace(name: "Orphan", groupID: missingGroupID))

        let newID = store.state.workspaces.first!.id
        #expect(store.state.workspaces.count == 1)
        #expect(store.state.topLevelOrder == [.workspace(newID)])
        #expect(store.state.groups.isEmpty)
    }

    // MARK: - deleteWorkspace

    @Test func deleteActiveWorkspaceFocusesMostRecentlyUsed() async {
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "WS1", paneID: Self.paneID1,
            lastAccessedAt: Date(timeIntervalSince1970: 2000)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "WS2", paneID: Self.paneID2,
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces[id: Self.wsID1] == nil)
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    @Test func deleteActiveWorkspacePrefersMiddleIfMostRecent() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        // Order in list: ws1, ws2, ws3. But ws2 was the most recently focused
        // non-active workspace — history should pick it over ws1 or ws3.
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "WS1", paneID: Self.paneID1,
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )
        let ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "WS2", paneID: Self.paneID2,
            lastAccessedAt: Date(timeIntervalSince1970: 3000)
        )
        let ws3 = Self.makeWorkspace(
            id: wsID3, name: "WS3", paneID: UUID(),
            lastAccessedAt: Date(timeIntervalSince1970: 5000)
        )

        let store = makeStore(
            workspaces: [ws1, ws2, ws3],
            activeWorkspaceID: wsID3
        )

        await store.send(.deleteWorkspace(wsID3)) { state in
            #expect(state.workspaces.count == 2)
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    @Test func deleteWorkspaceLastOneSelectsNil() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "Only", paneID: Self.paneID1)

        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.workspaces.isEmpty)
            #expect(state.activeWorkspaceID == nil)
        }
    }

    /// Issue #231 wiring lock-in: deleting a workspace dispatches a
    /// graft `forceStop` (→ `graftService.stop`) for EVERY removed
    /// association, even when the reducer's graft mirror has no
    /// session for it — filtering by the mirror is how a live service
    /// session got orphaned in the first place.
    @Test func deleteWorkspaceStopsGraftForAssociationsWithEmptyMirror() async {
        var ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let assocID = UUID(uuidString: "10000000-0000-0000-0000-0000000000AA")!
        ws1.repoAssociations = [
            RepoAssociation(
                id: assocID,
                repoID: UUID(),
                worktreePath: "/tmp/wt",
                branchName: "feature/x"
            )
        ]
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID2
        )
        let stopRecorder = StopRecorder()
        store.dependencies.graftService = GraftService(
            start: { _ in
                GraftSession(
                    id: UUID(), worktreePath: "", parentRepoRoot: "",
                    branch: "", status: .starting, stashRef: nil, lastSync: nil
                )
            },
            stop: { id in stopRecorder.append(id) },
            activeSessions: { [] },
            updates: { AsyncStream { _ in } },
            detectOrphans: { _ in [] },
            recoverOrphan: { _ in },
            dismissOrphan: { _ in }
        )

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.workspaces[id: Self.wsID1] == nil)
        }
        await store.finish()
        #expect(stopRecorder.values == [assocID])
    }

    // MARK: - setActiveWorkspace

    @Test func setActiveWorkspaceUpdatesID() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.setActiveWorkspace(Self.wsID2)) { state in
            #expect(state.activeWorkspaceID == Self.wsID2)
            // Issue #187: navigating to a workspace scrolls it into view.
            #expect(state.sidebarScrollTarget == .workspace(Self.wsID2))
        }
    }

    @Test func switchToWorkspaceByIndexScrollsTargetIntoView() async {
        // ⌘1-9 routes through setActiveWorkspace, so the destination
        // workspace should be queued for scroll-into-view (issue #187).
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.switchToWorkspaceByIndex(1))
        await store.receive(.setActiveWorkspace(Self.wsID2)) { state in
            #expect(state.sidebarScrollTarget == .workspace(Self.wsID2))
        }
    }

    // MARK: - switchToWorkspaceByIndex

    @Test func switchToWorkspaceByIndexValid() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        await store.send(.switchToWorkspaceByIndex(1))
        await store.receive(.setActiveWorkspace(Self.wsID2)) { state in
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    @Test func switchToWorkspaceByIndexOutOfBounds() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS1")

        let store = makeStore(
            workspaces: [ws],
            activeWorkspaceID: Self.wsID1
        )

        // Out of bounds — should produce no effect
        await store.send(.switchToWorkspaceByIndex(5))
    }

    // MARK: - switchToNextWorkspace / switchToPreviousWorkspace

    @Test func switchToNextWorkspaceCycles() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID2
        )

        // At the end — should wrap to first
        await store.send(.switchToNextWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID1)) { state in
            #expect(state.activeWorkspaceID == Self.wsID1)
        }
    }

    @Test func switchToPreviousWorkspaceCycles() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        let store = makeStore(
            workspaces: [ws1, ws2],
            activeWorkspaceID: Self.wsID1
        )

        // At the beginning — should wrap to last
        await store.send(.switchToPreviousWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID2)) { state in
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    /// Regression: once `state.workspaces` insertion order diverges
    /// from the sidebar walk order (e.g. after a bulk top-level drag
    /// that only touches `topLevelOrder`), Cmd+N and next/previous
    /// should still activate the workspace the user sees at that
    /// position — not the stale insertion-order entry.
    @Test func switchActionsFollowSidebarOrderNotInsertionOrder() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2")

        // Insertion order is [ws1, ws2] but the sidebar shows [ws2, ws1]
        // (topLevelOrder reversed), mirroring what a bulk drag via
        // `.moveWorkspacesToGroup` would leave behind.
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.topLevelOrder = [.workspace(Self.wsID2), .workspace(Self.wsID1)]
        appState.activeWorkspaceID = Self.wsID2
        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // Cmd+1 should land on ws2 (first in the visible sidebar),
        // not ws1 (first in insertion order).
        await store.send(.switchToWorkspaceByIndex(0))
        await store.receive(.setActiveWorkspace(Self.wsID2))

        // Next from ws2 (visible index 0) should be ws1 (visible idx 1).
        await store.send(.switchToNextWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID1))

        // Previous from ws1 (visible index 1) should wrap back to ws2.
        await store.send(.switchToPreviousWorkspace)
        await store.receive(.setActiveWorkspace(Self.wsID2))
    }

    // MARK: - toggleSidebar

    @Test func toggleSidebarFlips() async {
        let store = makeStore()
        #expect(store.state.isSidebarVisible == true)

        await store.send(.toggleSidebar) { state in
            #expect(state.isSidebarVisible == false)
        }

        await store.send(.toggleSidebar) { state in
            #expect(state.isSidebarVisible == true)
        }
    }

    // MARK: - showNewWorkspaceSheet / dismissNewWorkspaceSheet

    @Test func showNewWorkspaceSheet() async {
        let store = makeStore()

        await store.send(.showNewWorkspaceSheet()) { state in
            state.isNewWorkspaceSheetPresented = true
        }
    }

    @Test func showNewWorkspaceSheetScopedToGroup() async {
        let groupID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let store = makeStore()

        await store.send(.showNewWorkspaceSheet(groupID: groupID)) { state in
            state.isNewWorkspaceSheetPresented = true
            state.pendingSheetGroupID = groupID
        }
    }

    @Test func dismissNewWorkspaceSheet() async {
        let groupID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        var appState = AppReducer.State()
        appState.isNewWorkspaceSheetPresented = true
        appState.pendingSheetGroupID = groupID

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.dismissNewWorkspaceSheet) { state in
            state.isNewWorkspaceSheetPresented = false
            state.pendingSheetGroupID = nil
        }
    }

    @Test func createWorkspaceClearsPendingSheetGroupID() async {
        // When the sheet is open scoped to a group and the user submits, the
        // pending preselection hint should be cleared alongside the sheet flag
        // so a subsequent generic open doesn't remember the previous group.
        let groupID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let group = WorkspaceGroup(id: groupID, name: "G", color: nil, icon: nil)
        var appState = AppReducer.State()
        appState.groups = [group]
        appState.topLevelOrder = [.group(groupID)]
        appState.isNewWorkspaceSheetPresented = true
        appState.pendingSheetGroupID = groupID

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

        await store.send(.createWorkspace(name: "New", groupID: groupID))

        #expect(store.state.isNewWorkspaceSheetPresented == false)
        #expect(store.state.pendingSheetGroupID == nil)
    }

    // MARK: - beginRenameActiveWorkspace / setRenamingWorkspaceID

    @Test func beginRenameActiveWorkspaceSetsID() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.beginRenameActiveWorkspace) { state in
            state.renamingWorkspaceID = Self.wsID1
        }
    }

    @Test func beginRenameActiveWorkspaceWithNoActiveIsNoOp() async {
        let store = makeStore()

        await store.send(.beginRenameActiveWorkspace) { state in
            #expect(state.renamingWorkspaceID == nil)
        }
    }

    @Test func deleteWorkspaceClearsPendingRename() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.renamingWorkspaceID = Self.wsID1

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

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.renamingWorkspaceID == nil)
        }
    }

    @Test func deleteOtherWorkspacePreservesPendingRename() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.renamingWorkspaceID = Self.wsID1

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

        await store.send(.deleteWorkspace(Self.wsID2)) { state in
            #expect(state.renamingWorkspaceID == Self.wsID1)
        }
    }

    @Test func setRenamingWorkspaceIDClears() async {
        var appState = AppReducer.State()
        appState.renamingWorkspaceID = Self.wsID1

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setRenamingWorkspaceID(nil)) { state in
            state.renamingWorkspaceID = nil
        }
    }

    // MARK: - toggleInspector

    @Test func toggleInspectorFlips() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS1")
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        #expect(store.state.isInspectorVisible == false)

        await store.send(.toggleInspector) { state in
            #expect(state.isInspectorVisible == true)
        }

        await store.send(.toggleInspector) { state in
            #expect(state.isInspectorVisible == false)
        }
    }

    // MARK: - stateLoaded

    @Test func stateLoadedRestoresState() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Loaded1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Loaded2", paneID: Self.paneID2)
        let repo = Repo(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
            path: "/tmp/repo",
            name: "repo"
        )

        let store = makeStore()

        await store.send(.stateLoaded(
            [ws1, ws2],
            groups: [],
            topLevelOrder: [],
            activeWorkspaceID: Self.wsID2,
            repoRegistry: [repo]
        )) { state in
            #expect(state.workspaces.count == 2)
            #expect(state.activeWorkspaceID == Self.wsID2)
            #expect(state.repoRegistry.count == 1)
            #expect(state.repoRegistry.first?.path == "/tmp/repo")
            // Empty topLevelOrder is backfilled from the flat workspaces list
            #expect(state.topLevelOrder == [.workspace(Self.wsID1), .workspace(Self.wsID2)])
            #expect(state.groups.isEmpty)
        }
    }

    @Test func stateLoadedEmptyCreatesDefault() async {
        let store = makeStore()

        await store.send(.stateLoaded([], groups: [], topLevelOrder: [], activeWorkspaceID: nil, repoRegistry: []))

        // Should fire createWorkspace with "Default" and a random color
        await store.receive(\.createWorkspace) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces.first?.name == "Default")
        }
    }

    @Test func stateLoadedClearsSessionIDs() async {
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.panes[id: Self.paneID1]?.agentSessionID = "session-xyz"
        ws.panes[id: Self.paneID1]?.agentKind = .codex
        ws.panes[id: Self.paneID1]?.status = .running

        let store = makeStore()

        await store.send(.stateLoaded(
            [ws],
            groups: [],
            topLevelOrder: [],
            activeWorkspaceID: Self.wsID1,
            repoRegistry: []
        )) { state in
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.agentSessionID == nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.status == .idle)
            // agentKind deliberately survives the clear: it's a last-known
            // display value, and the resume tuples captured before the
            // clear need it to compose `codex resume` (issue #101).
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.agentKind == .codex)
        }
    }

    @Test func stateLoadedResetsRunningStatusEvenWithoutClaudeSession() async {
        // A pane that was .running without a Claude session ID (e.g. a
        // non-Claude agent that emitted `nex event start`) used to keep
        // its status across restart and falsely trigger the quit dialog
        // on next launch. The reset is now unconditional (issue #129).
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.panes[id: Self.paneID1]?.status = .waitingForInput

        let store = makeStore()

        await store.send(.stateLoaded(
            [ws],
            groups: [],
            topLevelOrder: [],
            activeWorkspaceID: Self.wsID1,
            repoRegistry: []
        )) { state in
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.agentSessionID == nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1]?.status == .idle)
        }
    }

    @Test func stateLoadedHonoursPersistedTopLevelOrder() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B", paneID: Self.paneID2)
        let groupID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let group = WorkspaceGroup(
            id: groupID,
            name: "Monitors",
            isCollapsed: false,
            childOrder: [Self.wsID2]
        )
        let order: [SidebarID] = [.workspace(Self.wsID1), .group(groupID)]

        let store = makeStore()

        await store.send(.stateLoaded(
            [ws1, ws2],
            groups: [group],
            topLevelOrder: order,
            activeWorkspaceID: Self.wsID1,
            repoRegistry: []
        )) { state in
            #expect(state.topLevelOrder == order)
            #expect(state.groups.count == 1)
            #expect(state.groups[id: groupID]?.childOrder == [Self.wsID2])
            #expect(state.groupID(forWorkspace: Self.wsID2) == groupID)
            #expect(state.groupID(forWorkspace: Self.wsID1) == nil)
        }
    }

    // MARK: - gitStatusUpdated

    @Test func gitStatusUpdatedStoresStatus() async {
        let assocID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
        let store = makeStore()

        await store.send(.gitStatusUpdated(associationID: assocID, status: .dirty(changedFiles: 3))) { state in
            #expect(state.gitStatuses[assocID] == .dirty(changedFiles: 3))
        }
    }

    // MARK: - paneMoveToWorkspace

    @Test func movePaneToWorkspaceByName() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Target", paneID: Self.paneID2)

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Target", create: false
        ), reply: nil)) { state in
            // Source workspace has no panes
            #expect(state.workspaces[id: Self.wsID1]?.panes.count == 0)
            #expect(state.workspaces[id: Self.wsID1]?.layout.isEmpty == true)
            #expect(state.workspaces[id: Self.wsID1]?.focusedPaneID == nil)

            // Target workspace has both panes
            #expect(state.workspaces[id: Self.wsID2]?.panes.count == 2)
            #expect(state.workspaces[id: Self.wsID2]?.panes[id: Self.paneID1] != nil)
            #expect(state.workspaces[id: Self.wsID2]?.focusedPaneID == Self.paneID1)

            // Active workspace switched
            #expect(state.activeWorkspaceID == Self.wsID2)
        }
    }

    @Test func movePaneToWorkspaceWithCreate() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)

        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "NewWS", create: true
        ), reply: nil)) { state in
            // New workspace was created
            #expect(state.workspaces.count == 2)
            let newWS = state.workspaces.first(where: { $0.name == "NewWS" })
            #expect(newWS != nil)
            #expect(newWS?.panes[id: Self.paneID1] != nil)
            #expect(newWS?.layout == .leaf(Self.paneID1))
            #expect(newWS?.focusedPaneID == Self.paneID1)

            // Source is empty
            #expect(state.workspaces[id: Self.wsID1]?.panes.count == 0)

            // Issue #187: the freshly created destination scrolls into view.
            #expect(state.sidebarScrollTarget == .workspace(newWS!.id))
        }
    }

    @Test func movePaneToWorkspaceNotFoundWithoutCreate() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)

        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "NonExistent", create: false
        ), reply: nil))
        // No state change — pane stays in source
    }

    @Test func movePaneToSameWorkspaceNoOp() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)

        let store = makeStore(workspaces: [ws1], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Source", create: false
        ), reply: nil))
        // No state change — same workspace
    }

    @Test func moveLastPaneLeavesSourceEmpty() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Target", paneID: Self.paneID2)

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Target", create: false
        ), reply: nil)) { state in
            // Source workspace still exists but is empty
            #expect(state.workspaces[id: Self.wsID1] != nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes.isEmpty == true)
            #expect(state.workspaces[id: Self.wsID1]?.layout.isEmpty == true)
        }
    }

    @Test func movePaneToEmptyWorkspace() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        let ws2 = WorkspaceFeature.State(
            id: Self.wsID2, name: "Empty", slug: "empty", color: .green,
            panes: [], layout: .empty, focusedPaneID: nil,
            createdAt: Date(), lastAccessedAt: Date()
        )

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Empty", create: false
        ), reply: nil)) { state in
            // Pane becomes sole leaf in target
            #expect(state.workspaces[id: Self.wsID2]?.panes.count == 1)
            #expect(state.workspaces[id: Self.wsID2]?.layout == .leaf(Self.paneID1))
            #expect(state.workspaces[id: Self.wsID2]?.focusedPaneID == Self.paneID1)
        }
    }

    /// When moving the source workspace's currently-focused pane out,
    /// the source's new focus should walk its focus history (mirroring
    /// closePane), not fall back to the layout's first leaf.
    @Test func movePaneToWorkspaceUsesSourceFocusHistory() async {
        let extraPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        var ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        ws1.panes.append(Pane(id: Self.paneID2))
        ws1.panes.append(Pane(id: extraPaneID))
        // Layout: paneID1 | paneID2 | extraPaneID. allPaneIDs.first == paneID1.
        ws1.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(Self.paneID1),
            second: .split(
                .horizontal, ratio: 0.5,
                first: .leaf(Self.paneID2),
                second: .leaf(extraPaneID)
            )
        )
        // Focus walked paneID1 -> paneID2 -> extraPaneID, so stack
        // contains [paneID1, paneID2] with extraPaneID currently focused.
        ws1.focusedPaneID = extraPaneID
        ws1.focusHistory = [Self.paneID1, Self.paneID2]

        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Target", paneID: UUID())

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: extraPaneID, toWorkspace: "Target", create: false
        ), reply: nil)) { state in
            // Without focus history, source would fall back to paneID1
            // (layout's first leaf). With history, it pops paneID2.
            #expect(state.workspaces[id: Self.wsID1]?.focusedPaneID == Self.paneID2)
            #expect(state.workspaces[id: Self.wsID1]?.focusHistory == [Self.paneID1])
        }
    }

    /// Moving a pane into a target workspace should push the target's
    /// previous focus onto its history, so closing the moved pane in
    /// the target later returns focus to the prior target pane.
    @Test func movePaneToWorkspacePushesTargetFocusHistory() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "Source", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "Target", paneID: Self.paneID2)

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneMoveToWorkspace(
            paneID: Self.paneID1, toWorkspace: "Target", create: false
        ), reply: nil)) { state in
            #expect(state.workspaces[id: Self.wsID2]?.focusedPaneID == Self.paneID1)
            // The target's prior focus (paneID2) is on the history stack.
            #expect(state.workspaces[id: Self.wsID2]?.focusHistory == [Self.paneID2])
        }
    }

    // MARK: - refreshGitStatus

    @Test func refreshGitStatusQueriesAssociations() async {
        let assocID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
        let repoID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!

        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.repoAssociations.append(RepoAssociation(
            id: assocID, repoID: repoID, worktreePath: "/tmp/repo"
        ))

        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.refreshGitStatus)

        await store.receive(.gitStatusUpdated(associationID: assocID, status: .clean)) { state in
            #expect(state.gitStatuses[assocID] == .clean)
        }
    }

    // MARK: - configLoaded (TCP port)

    @Test func configLoadedSetsTCPPort() async {
        let store = makeStore()

        await store.send(.configLoaded(
            focusFollowsMouse: false,
            focusFollowsMouseDelay: 100,
            theme: nil,
            tcpPort: 19400,
            globalHotkey: nil,
            globalHotkeyHideOnRepress: true
        ))
        await store.receive(\.configHotkey.applyLoadedConfig) { state in
            #expect(state.configHotkey.tcpPort == 19400)
        }
    }

    @Test func configLoadedZeroTCPPortMeansDisabled() async {
        let store = makeStore()

        await store.send(.configLoaded(
            focusFollowsMouse: true,
            focusFollowsMouseDelay: 200,
            theme: nil,
            tcpPort: 0,
            globalHotkey: nil,
            globalHotkeyHideOnRepress: true
        ))
        await store.receive(\.configHotkey.applyLoadedConfig) { state in
            #expect(state.configHotkey.tcpPort == 0)
            #expect(state.configHotkey.focusFollowsMouse == true)
            #expect(state.configHotkey.focusFollowsMouseDelay == 200)
        }
    }

    // MARK: - Global Hotkey

    /// Records every `register(_:)` call so tests can assert the reducer
    /// is calling through to the hotkey service with the right trigger.
    private actor RecordingGlobalHotkeyService: GlobalHotkeyServicing {
        private var _calls: [KeyTrigger?] = []

        nonisolated func register(_ trigger: KeyTrigger?) async throws {
            await append(trigger)
        }

        private func append(_ trigger: KeyTrigger?) {
            _calls.append(trigger)
        }

        func calls() -> [KeyTrigger?] {
            _calls
        }
    }

    /// Simulates a Carbon rejection (e.g. `eventHotKeyExistsErr`) so the
    /// rollback path can be exercised in tests.
    private struct FailingGlobalHotkeyService: GlobalHotkeyServicing {
        struct RegistrationFailed: Error, CustomStringConvertible {
            var description: String { "simulated registration failure" }
        }

        func register(_: KeyTrigger?) async throws {
            throw RegistrationFailed()
        }
    }

    @Test func configLoadedStoresGlobalHotkeyAndCallsRegister() async {
        let recorder = RecordingGlobalHotkeyService()
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.globalHotkeyService = recorder
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let trigger = KeyTrigger(keyCode: 17, modifiers: [.command, .shift]) // ⌘⇧T
        await store.send(.configLoaded(
            focusFollowsMouse: false,
            focusFollowsMouseDelay: 100,
            theme: nil,
            tcpPort: 0,
            globalHotkey: trigger,
            globalHotkeyHideOnRepress: false
        ))
        await store.receive(\.configHotkey.applyLoadedConfig) { state in
            state.configHotkey.globalHotkey = trigger
            state.configHotkey.globalHotkeyHideOnRepress = false
        }
        await store.finish()
        #expect(await recorder.calls() == [trigger])
    }

    @Test func setGlobalHotkeyUpdatesStateAndRegisters() async {
        let recorder = RecordingGlobalHotkeyService()
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.globalHotkeyService = recorder
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let trigger = KeyTrigger(keyCode: 17, modifiers: [.command, .shift])
        await store.send(.configHotkey(.setGlobalHotkey(trigger))) { state in
            state.configHotkey.globalHotkey = trigger
            state.configHotkey.globalHotkeyRegistrationError = nil
        }
        await store.finish()
        #expect(await recorder.calls() == [trigger])
    }

    @Test func setGlobalHotkeyNilClearsState() async {
        var appState = AppReducer.State()
        appState.configHotkey.globalHotkey = KeyTrigger(keyCode: 17, modifiers: [.command, .shift])
        appState.configHotkey.globalHotkeyRegistrationError = "stale"

        let recorder = RecordingGlobalHotkeyService()
        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.globalHotkeyService = recorder
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.configHotkey(.setGlobalHotkey(nil))) { state in
            state.configHotkey.globalHotkey = nil
            state.configHotkey.globalHotkeyRegistrationError = nil
        }
        await store.finish()
        #expect(await recorder.calls() == [KeyTrigger?.none])
    }

    @Test func setGlobalHotkeyHideOnRepressUpdatesState() async {
        let store = makeStore()

        await store.send(.configHotkey(.setGlobalHotkeyHideOnRepress(false))) { state in
            state.configHotkey.globalHotkeyHideOnRepress = false
        }
    }

    @Test func globalHotkeyRegistrationFailedSetsError() async {
        let store = makeStore()

        await store.send(.configHotkey(.globalHotkeyRegistrationFailed(reason: "eventHotKeyExistsErr"))) { state in
            state.configHotkey.globalHotkeyRegistrationError = "eventHotKeyExistsErr"
        }
    }

    @Test func setGlobalHotkeyRollsBackOnRegistrationFailure() async {
        // Seed with a previously-working hotkey.
        let previous = KeyTrigger(keyCode: 17, modifiers: [.command, .shift]) // ⌘⇧T
        let attempted = KeyTrigger(keyCode: 2, modifiers: .command) // ⌘D (collides, say)

        var appState = AppReducer.State()
        appState.configHotkey.globalHotkey = previous

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.globalHotkeyService = FailingGlobalHotkeyService()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // Optimistic update to the attempted trigger.
        await store.send(.configHotkey(.setGlobalHotkey(attempted))) { state in
            state.configHotkey.globalHotkey = attempted
            state.configHotkey.globalHotkeyRegistrationError = nil
        }
        // Rollback action fires and restores `previous`.
        await store.receive(
            .configHotkey(.globalHotkeyRegistrationRejected(
                revertTo: previous,
                reason: "simulated registration failure"
            ))
        ) { state in
            state.configHotkey.globalHotkey = previous
            state.configHotkey.globalHotkeyRegistrationError = "simulated registration failure"
        }
    }

    @Test func globalHotkeyConflictWithInAppIsComputed() {
        var state = ConfigHotkeyFeature.State()
        state.keybindings = .defaults
        state.globalHotkey = KeyTrigger(keyCode: 2, modifiers: .command) // ⌘D → splitRight
        #expect(state.globalHotkeyConflictWithInApp == .action(.splitRight))
    }

    @Test func globalHotkeyNoConflictWhenUnbound() {
        var state = ConfigHotkeyFeature.State()
        state.keybindings = .defaults
        // ⌃⌥L — not in defaults.
        state.globalHotkey = KeyTrigger(keyCode: 37, modifiers: [.control, .option])
        #expect(state.globalHotkeyConflictWithInApp == nil)
    }

    @Test func globalHotkeyConflictNilWhenNoHotkey() {
        var state = ConfigHotkeyFeature.State()
        state.keybindings = .defaults
        state.globalHotkey = nil
        #expect(state.globalHotkeyConflictWithInApp == nil)
    }

    // MARK: - setTCPPort

    @Test func setTCPPortUpdatesState() async {
        let store = makeStore()

        await store.send(.configHotkey(.setTCPPort(19400))) { state in
            #expect(state.configHotkey.tcpPort == 19400)
        }
    }

    @Test func setTCPPortClampsToValidRange() async {
        let store = makeStore()

        await store.send(.configHotkey(.setTCPPort(99999))) { state in
            #expect(state.configHotkey.tcpPort == 65535)
        }
    }

    @Test func setTCPPortNegativeClampsToZero() async {
        let store = makeStore()

        await store.send(.configHotkey(.setTCPPort(-1))) { state in
            #expect(state.configHotkey.tcpPort == 0)
        }
    }

    @Test func setTCPPortClearsError() async {
        var appState = AppReducer.State()
        appState.configHotkey.tcpPortError = "Port 19400 is unavailable"

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.configHotkey(.setTCPPort(19401))) { state in
            #expect(state.configHotkey.tcpPortError == nil)
            #expect(state.configHotkey.tcpPort == 19401)
        }
    }

    @Test func setTCPPortToZeroDisables() async {
        var appState = AppReducer.State()
        appState.configHotkey.tcpPort = 19400

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.configHotkey(.setTCPPort(0))) { state in
            #expect(state.configHotkey.tcpPort == 0)
        }
    }

    // MARK: - tcpPortStartFailed

    @Test func tcpPortStartFailedSetsError() async {
        let store = makeStore()

        await store.send(.configHotkey(.setTCPPort(19400))) { state in
            state.configHotkey.tcpPort = 19400
        }

        await store.send(.configHotkey(.tcpPortStartFailed(19400))) { state in
            #expect(state.configHotkey.tcpPortError == "Port 19400 is unavailable")
        }
    }

    @Test func tcpPortStartFailedPreservesPort() async {
        let store = makeStore()

        await store.send(.configHotkey(.setTCPPort(8080))) { state in
            state.configHotkey.tcpPort = 8080
        }

        await store.send(.configHotkey(.tcpPortStartFailed(8080))) { state in
            #expect(state.configHotkey.tcpPortError == "Port 8080 is unavailable")
            #expect(state.configHotkey.tcpPort == 8080)
        }
    }

    // MARK: - Multi-select workspaces

    @Test func toggleWorkspaceSelectionAddsAndRemoves() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.toggleWorkspaceSelection(Self.wsID1)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1])
            #expect(state.lastSelectionAnchor == Self.wsID1)
        }
        await store.send(.toggleWorkspaceSelection(Self.wsID2)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, Self.wsID2])
            #expect(state.lastSelectionAnchor == Self.wsID2)
        }
        await store.send(.toggleWorkspaceSelection(Self.wsID1)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID2])
        }
    }

    @Test func rangeSelectWorkspaceSelectsInclusiveRange() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())

        let store = makeStore(workspaces: [ws1, ws2, ws3], activeWorkspaceID: Self.wsID1)

        // Anchor at ws1 (active), shift-click ws3 picks all three
        await store.send(.rangeSelectWorkspace(wsID3)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, Self.wsID2, wsID3])
            #expect(state.lastSelectionAnchor == wsID3)
        }
    }

    /// Regression: when workspaces are reorganised into groups, the
    /// shift-range must still cover the visible sidebar run — not the
    /// (now-divergent) `state.workspaces` insertion order.
    @Test func rangeSelectSpansVisibleOrderAcrossGroups() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let wsID4 = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let groupID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())
        let ws4 = Self.makeWorkspace(id: wsID4, name: "WS4", paneID: UUID())

        var state = AppReducer.State()
        state.workspaces = [ws1, ws2, ws3, ws4]
        // Visible order in sidebar: ws1, ws3, ws4, ws2 (ws3 + ws4 are
        // inside the group; ws1 and ws2 are top-level).
        state.groups = [WorkspaceGroup(id: groupID, name: "G", childOrder: [wsID3, wsID4])]
        state.topLevelOrder = [
            .workspace(Self.wsID1),
            .group(groupID),
            .workspace(Self.wsID2)
        ]
        state.activeWorkspaceID = Self.wsID1

        let store = TestStore(initialState: state) {
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

        // Anchor = ws1 (active). Shift-click ws4 must cover ws1, ws3,
        // ws4 (the three visible rows between them) — NOT ws1, ws2,
        // ws3, ws4 as the old insertion-order logic would have picked.
        await store.send(.rangeSelectWorkspace(wsID4)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, wsID3, wsID4])
            #expect(state.lastSelectionAnchor == wsID4)
        }
    }

    /// Regression: Cmd+N, the row's ⌘N badge, next/previous cycling and
    /// shift-range all read `visibleWorkspaceOrder`. Workspaces inside a
    /// collapsed group aren't on screen, so they must not contribute to
    /// the order — otherwise ⌘N numbering skips values, Cmd-] cycles to
    /// invisible workspaces, and shift-range selects rows the user
    /// cannot see.
    @Test func visibleWorkspaceOrderExcludesCollapsedGroupChildren() {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let wsID4 = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let groupID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())
        let ws4 = Self.makeWorkspace(id: wsID4, name: "WS4", paneID: UUID())

        var state = AppReducer.State()
        state.workspaces = [ws1, ws2, ws3, ws4]
        state.groups = [
            WorkspaceGroup(id: groupID, name: "G", isCollapsed: true, childOrder: [wsID3, wsID4])
        ]
        state.topLevelOrder = [
            .workspace(Self.wsID1),
            .group(groupID),
            .workspace(Self.wsID2)
        ]

        #expect(state.visibleWorkspaceOrder == [Self.wsID1, Self.wsID2])

        state.groups[id: groupID]?.isCollapsed = false
        #expect(state.visibleWorkspaceOrder == [Self.wsID1, wsID3, wsID4, Self.wsID2])
    }

    /// Cmd+N must map to the N-th *visible* workspace. With a collapsed
    /// group between ws1 and ws2, ⌘2 should activate ws2 — not ws3 (the
    /// first child of the collapsed group).
    @Test func switchToWorkspaceByIndexSkipsCollapsedGroupChildren() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let groupID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())

        var state = AppReducer.State()
        state.workspaces = [ws1, ws2, ws3]
        state.groups = [
            WorkspaceGroup(id: groupID, name: "G", isCollapsed: true, childOrder: [wsID3])
        ]
        state.topLevelOrder = [
            .workspace(Self.wsID1),
            .group(groupID),
            .workspace(Self.wsID2)
        ]
        state.activeWorkspaceID = Self.wsID1

        let store = TestStore(initialState: state) {
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

        // Index 1 is ws2 (visible), not ws3 (hidden inside collapsed group).
        await store.send(.switchToWorkspaceByIndex(1))
        await store.receive(\.setActiveWorkspace) { state in
            state.activeWorkspaceID = Self.wsID2
        }
    }

    @Test func selectAllWorkspacesFillsSelection() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID())
        let store = makeStore(workspaces: [ws1, ws2, ws3], activeWorkspaceID: Self.wsID1)

        await store.send(.selectAllWorkspaces) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID1, Self.wsID2, wsID3])
            #expect(state.lastSelectionAnchor == wsID3)
        }
    }

    @Test func clearWorkspaceSelectionEmptiesSet() async {
        var appState = AppReducer.State()
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]
        appState.lastSelectionAnchor = Self.wsID2

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.clearWorkspaceSelection) { state in
            #expect(state.selectedWorkspaceIDs.isEmpty)
            #expect(state.lastSelectionAnchor == nil)
        }
    }

    @Test func setBulkColorAppliesToAllSelected() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", color: .red, paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", color: .blue, paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setBulkColor(.green)) { state in
            #expect(state.workspaces[id: Self.wsID1]?.color == .green)
            #expect(state.workspaces[id: Self.wsID2]?.color == .green)
        }
    }

    @Test func setBulkLabelAppliesToAllSelectedWithoutDuplicating() async {
        var ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        ws1.labels = ["urgent"] // already carries it — must not be duplicated
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setBulkLabel(label: "urgent", apply: true)) { state in
            #expect(state.workspaces[id: Self.wsID1]?.labels == ["urgent"])
            #expect(state.workspaces[id: Self.wsID2]?.labels == ["urgent"])
        }
    }

    @Test func setBulkLabelRemovesFromAllSelected() async {
        var ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        ws1.labels = ["urgent", "keep"]
        var ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        ws2.labels = ["urgent"]
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setBulkLabel(label: "urgent", apply: false)) { state in
            #expect(state.workspaces[id: Self.wsID1]?.labels == ["keep"])
            #expect(state.workspaces[id: Self.wsID2]?.labels == [])
        }
    }

    @Test func setBulkLabelIgnoresBlankLabel() async {
        var ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        ws1.labels = ["urgent"]
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // Whitespace-only label normalizes to empty and is a no-op.
        await store.send(.setBulkLabel(label: "   ", apply: true))
    }

    @Test func requestBulkDeletePresentsConfirmation() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.requestBulkDelete) { state in
            #expect(state.bulkDeleteConfirmationIDs == [Self.wsID1])
        }
    }

    @Test func requestBulkDeleteBlockedWhenSelectionCoversAll() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.requestBulkDelete) { state in
            #expect(state.bulkDeleteConfirmationIDs == nil)
        }
    }

    @Test func confirmBulkDeleteRemovesWorkspaces() async {
        let wsID3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1,
                                     lastAccessedAt: Date(timeIntervalSince1970: 1000))
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2,
                                     lastAccessedAt: Date(timeIntervalSince1970: 2000))
        let ws3 = Self.makeWorkspace(id: wsID3, name: "WS3", paneID: UUID(),
                                     lastAccessedAt: Date(timeIntervalSince1970: 3000))
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2, ws3]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, wsID3]
        appState.lastSelectionAnchor = wsID3
        appState.bulkDeleteConfirmationIDs = [Self.wsID1, wsID3]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.confirmBulkDelete) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces[id: Self.wsID2] != nil)
            #expect(state.activeWorkspaceID == Self.wsID2)
            #expect(state.bulkDeleteConfirmationIDs == nil)
            #expect(state.selectedWorkspaceIDs.isEmpty)
            #expect(state.lastSelectionAnchor == nil)
        }
    }

    @Test func confirmBulkDeleteGuardsAgainstDeletingAll() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.bulkDeleteConfirmationIDs = [Self.wsID1, Self.wsID2]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.confirmBulkDelete) { state in
            #expect(state.workspaces.count == 2)
            #expect(state.bulkDeleteConfirmationIDs == nil)
        }
    }

    @Test func deleteWorkspaceClearsSelectionEntry() async {
        let ws1 = Self.makeWorkspace(id: Self.wsID1, name: "WS1", paneID: Self.paneID1)
        let ws2 = Self.makeWorkspace(id: Self.wsID2, name: "WS2", paneID: Self.paneID2)
        var appState = AppReducer.State()
        appState.workspaces = [ws1, ws2]
        appState.activeWorkspaceID = Self.wsID1
        appState.selectedWorkspaceIDs = [Self.wsID1, Self.wsID2]
        appState.lastSelectionAnchor = Self.wsID1

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.deleteWorkspace(Self.wsID1)) { state in
            #expect(state.selectedWorkspaceIDs == [Self.wsID2])
            #expect(state.lastSelectionAnchor == nil)
        }
    }

    // MARK: - paneClose --target

    /// `--target <label>` outside a Nex pane (no `pane_id`) requires
    /// `--workspace` for explicit scope (issue #92). Without it the
    /// reducer rejects the request rather than guessing.
    @Test func closePaneByTargetLabelWithoutOrigin() async {
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.panes[id: Self.paneID1]?.label = "worker"
        ws.panes.append(Pane(id: Self.paneID2, label: "other"))
        ws.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(Self.paneID1), second: .leaf(Self.paneID2)
        )

        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: "worker", workspace: "WS"),
            reply: nil
        ))
        await store.receive(.workspaces(.element(
            id: Self.wsID1, action: .closePane(Self.paneID1)
        ))) { state in
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1] == nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID2] != nil)
        }
    }

    /// Bare label outside a Nex pane is rejected by the reducer.
    /// Reply is nil (legacy fire-and-forget) so the close is silently
    /// dropped — no `.closePane` is dispatched.
    @Test func closePaneByTargetAmbiguousLabelNoOps() async {
        var ws1 = Self.makeWorkspace(id: Self.wsID1, name: "A", paneID: Self.paneID1)
        ws1.panes[id: Self.paneID1]?.label = "worker"
        var ws2 = Self.makeWorkspace(id: Self.wsID2, name: "B", paneID: Self.paneID2)
        ws2.panes[id: Self.paneID2]?.label = "worker"

        let store = makeStore(workspaces: [ws1, ws2], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneClose(paneID: nil, target: "worker", workspace: nil), reply: nil))
        // No `.closePane` is dispatched — both panes survive.
        #expect(store.state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1] != nil)
        #expect(store.state.workspaces[id: Self.wsID2]?.panes[id: Self.paneID2] != nil)
    }

    /// Target doesn't match any UUID or label — reducer no-ops.
    @Test func closePaneByTargetUnresolvedNoOps() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .paneClose(paneID: Self.paneID1, target: "missing", workspace: nil),
            reply: nil
        ))
        #expect(store.state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1] != nil)
    }

    /// When both `pane_id` and `target` appear on the wire, the
    /// reducer prefers `target`. The CLI only emits one in practice,
    /// but the decoder preserves both and the contract documents the
    /// precedence.
    @Test func closePanePrefersTargetOverPaneID() async {
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "WS", paneID: Self.paneID1)
        ws.panes[id: Self.paneID1]?.label = "origin"
        ws.panes.append(Pane(id: Self.paneID2, label: "worker"))
        ws.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(Self.paneID1), second: .leaf(Self.paneID2)
        )

        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(.paneClose(
            paneID: Self.paneID1, target: "worker", workspace: nil
        ), reply: nil))
        await store.receive(.workspaces(.element(
            id: Self.wsID1, action: .closePane(Self.paneID2)
        ))) { state in
            // paneID2 (target "worker") closed; paneID1 (pane_id) survives.
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID1] != nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes[id: Self.paneID2] == nil)
        }
    }

    /// Closing the last pane via `--target` empties the workspace but
    /// leaves the workspace itself in place. The socket path diverges
    /// from the keybinding path (`NexCommands.handleClosePane` deletes
    /// the workspace) — automation shouldn't silently vaporise a
    /// workspace.
    @Test func closeLastPaneByTargetLeavesWorkspaceEmpty() async {
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "Solo", paneID: Self.paneID1)
        ws.panes[id: Self.paneID1]?.label = "only"
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .paneClose(paneID: nil, target: "only", workspace: "Solo"),
            reply: nil
        ))
        await store.receive(.workspaces(.element(
            id: Self.wsID1, action: .closePane(Self.paneID1)
        ))) { state in
            #expect(state.workspaces[id: Self.wsID1] != nil)
            #expect(state.workspaces[id: Self.wsID1]?.panes.isEmpty == true)
            #expect(state.workspaces[id: Self.wsID1]?.layout.isEmpty == true)
            #expect(state.workspaces[id: Self.wsID1]?.focusedPaneID == nil)
        }
    }

    // MARK: - openFile socket handoff

    /// `--here` (reuse=true) with a resolvable source pane must hand
    /// off a non-nil `reusePaneID` to the workspace action — a bug
    /// that always passed `nil` here would silently fall back to the
    /// split behaviour and would not be caught by the wire-parsing
    /// or workspace-feature tests in isolation.
    @Test func openFileWithReusePassesReusePaneID() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "W", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .openFile(path: "/tmp/plan.md", paneID: Self.paneID1, reuse: true),
            reply: nil
        ))
        await store.receive(.workspaces(.element(
            id: Self.wsID1,
            action: .openMarkdownFile(filePath: "/tmp/plan.md", reusePaneID: Self.paneID1)
        )))
    }

    @Test func openFileWithoutReuseSendsNilReusePaneID() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "W", paneID: Self.paneID1)
        let store = makeStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .openFile(path: "/tmp/plan.md", paneID: Self.paneID1, reuse: false),
            reply: nil
        ))
        await store.receive(.workspaces(.element(
            id: Self.wsID1,
            action: .openMarkdownFile(filePath: "/tmp/plan.md", reusePaneID: nil)
        )))
    }

    // MARK: - Parked panes + workspace deletion

    /// Deleting a workspace must tear down surfaces for *parked* panes
    /// too. They're not in `layout.allPaneIDs`, so the original loop
    /// (pre-parked-panes) would have leaked their PTYs.
    @Test func deleteWorkspaceDestroysParkedPaneSurfaces() async {
        let visibleID = UUID(uuidString: "00000000-0000-0000-0000-000000100001")!
        let parkedID = UUID(uuidString: "00000000-0000-0000-0000-000000100002")!

        var ws = Self.makeWorkspace(id: Self.wsID1, name: "W", paneID: visibleID)
        ws.parkedPanes = [Pane(id: parkedID, type: .shell)]

        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: visibleID, workingDirectory: "/tmp")
        surfaceManager.createSurface(paneID: parkedID, workingDirectory: "/tmp")
        #expect(surfaceManager.activeSurfaceCount == 2)

        var appState = AppReducer.State()
        appState.workspaces = [ws]
        appState.activeWorkspaceID = Self.wsID1
        appState.topLevelOrder = [.workspace(Self.wsID1)]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.deleteWorkspace(Self.wsID1))
        await store.finish()

        #expect(surfaceManager.activeSurfaceCount == 0)
    }

    /// End-to-end: a parked pane's PTY can exit on its own (SIGHUP,
    /// background job, etc.). The surface callback fires
    /// `.surfaceProcessExited`. AppReducer must route this to the
    /// workspace (which lives in the `parkedPanes` lane, not `panes`)
    /// so the parked-eviction branch in `WorkspaceFeature` runs.
    /// Before this fix the event was dropped and the parked entry
    /// leaked.
    @Test func parkedShellSurfaceExitReachesWorkspaceAndEvicts() async {
        let visibleID = UUID(uuidString: "00000000-0000-0000-0000-0000BA5EBA11")!
        let parkedID = UUID(uuidString: "00000000-0000-0000-0000-0000DEADBEEF")!
        let markdownID = UUID(uuidString: "00000000-0000-0000-0000-000012345678")!

        var ws = Self.makeWorkspace(id: Self.wsID1, name: "W", paneID: visibleID)
        // Simulate a `--here` overlay: shell parked, markdown linked.
        var markdownPane = Pane(id: markdownID, type: .markdown, filePath: "/tmp/x.md")
        markdownPane.parkedSourcePaneID = parkedID
        ws.panes.append(markdownPane)
        ws.parkedPanes = [Pane(id: parkedID, type: .shell)]

        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: visibleID, workingDirectory: "/tmp")
        surfaceManager.createSurface(paneID: parkedID, workingDirectory: "/tmp")
        #expect(surfaceManager.activeSurfaceCount == 2)

        var appState = AppReducer.State()
        appState.workspaces = [ws]
        appState.activeWorkspaceID = Self.wsID1
        appState.topLevelOrder = [.workspace(Self.wsID1)]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.surfaceProcessExited(paneID: parkedID))
        await store.receive(.workspaces(.element(
            id: Self.wsID1,
            action: .paneProcessTerminated(paneID: parkedID)
        )))
        await store.finish()

        let wsState = store.state.workspaces[id: Self.wsID1]
        #expect(wsState?.parkedPanes[id: parkedID] == nil)
        // Markdown pane's link cleared so its close takes the normal path.
        #expect(wsState?.panes[id: markdownID]?.parkedSourcePaneID == nil)
        #expect(surfaceManager.surface(for: parkedID) == nil)
        #expect(surfaceManager.surface(for: visibleID) != nil)
    }

    /// Agent lifecycle events (e.g. claude exits in a parked shell)
    /// must also reach the workspace so the parked pane's status
    /// tracking stays consistent. When we unpark later, the restored
    /// terminal's badge should reflect reality.
    @Test func parkedAgentStoppedUpdatesParkedPaneStatus() async {
        let visibleID = UUID(uuidString: "00000000-0000-0000-0000-000022222222")!
        let parkedID = UUID(uuidString: "00000000-0000-0000-0000-000033333333")!

        var parkedPane = Pane(id: parkedID, type: .shell)
        parkedPane.status = .running
        var ws = Self.makeWorkspace(id: Self.wsID1, name: "W", paneID: visibleID)
        ws.parkedPanes = [parkedPane]

        var appState = AppReducer.State()
        appState.workspaces = [ws]
        appState.activeWorkspaceID = Self.wsID1
        appState.topLevelOrder = [.workspace(Self.wsID1)]

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = ImmediateClock()
            $0.notificationService = .testValue
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.socketMessage(.agentStopped(paneID: parkedID, backgroundTaskCount: 0), reply: nil))
        await store.receive(.workspaces(.element(
            id: Self.wsID1,
            action: .agentStopped(paneID: parkedID, backgroundTaskCount: 0)
        )))
        await store.finish()

        let parked = store.state.workspaces[id: Self.wsID1]?.parkedPanes[id: parkedID]
        #expect(parked?.status == .waitingForInput)
    }
}

private final class StopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [UUID] = []
    func append(_ id: UUID) {
        lock.withLock { _values.append(id) }
    }

    var values: [UUID] { lock.withLock { _values } }
}
