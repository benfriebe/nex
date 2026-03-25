import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct WorkspaceFeatureTests {
    @Test func splitPaneCreatesNewPane() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let originalPaneID = workspace.panes.first!.id
        let originalCwd = workspace.panes.first!.workingDirectory
        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newPaneID)
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPane(direction: .horizontal, sourcePaneID: originalPaneID)) { state in
            // Verify structural changes
            #expect(state.panes.count == 2)
            #expect(state.focusedPaneID == newPaneID)
            if case .split(let dir, let ratio, .leaf(let first), .leaf(let second)) = state.layout {
                #expect(dir == .horizontal)
                #expect(ratio == 0.5)
                #expect(first == originalPaneID)
                #expect(second == newPaneID)
            } else {
                Issue.record("Expected horizontal split layout")
            }
        }
    }

    @Test func closePaneRemovesAndPromotesSibling() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstPaneID = workspace.panes.first!.id

        let secondPaneID = UUID()
        workspace.panes.append(Pane(id: secondPaneID))
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstPaneID),
            second: .leaf(secondPaneID)
        )
        workspace.focusedPaneID = secondPaneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.closePane(secondPaneID)) { state in
            state.recentlyClosedPanes = [
                ClosedPaneSnapshot(
                    workingDirectory: state.panes[id: secondPaneID]!.workingDirectory,
                    label: nil,
                    type: .shell,
                    claudeSessionID: nil
                )
            ]
            state.panes.remove(id: secondPaneID)
            state.layout = .leaf(firstPaneID)
            state.focusedPaneID = firstPaneID
        }
    }

    @Test func focusNextCycles() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.focusNextPane) { state in
            state.focusedPaneID = secondID
        }

        await store.send(.focusNextPane) { state in
            state.focusedPaneID = firstID
        }
    }

    @Test func rename() async {
        let store = TestStore(initialState: WorkspaceFeature.State(name: "Old")) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.rename("New")) { state in
            state.name = "New"
            state.slug = WorkspaceFeature.State.makeSlug(from: "New", id: state.id)
        }
    }

    @Test func setColor() async {
        let store = TestStore(initialState: WorkspaceFeature.State(name: "Test", color: .blue)) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.setColor(.red)) { state in
            state.color = .red
        }
    }

    @Test func addRepoAssociation() async {
        let store = TestStore(initialState: WorkspaceFeature.State(name: "Test")) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        let assocID = UUID()
        let repoID = UUID()
        let assoc = RepoAssociation(
            id: assocID,
            repoID: repoID,
            worktreePath: "/path/to/worktree",
            branchName: "feature/test"
        )

        await store.send(.addRepoAssociation(assoc)) { state in
            state.repoAssociations.append(assoc)
        }
    }

    @Test func removeRepoAssociation() async {
        let assocID = UUID()
        let repoID = UUID()
        let assoc = RepoAssociation(
            id: assocID,
            repoID: repoID,
            worktreePath: "/path/to/worktree"
        )

        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.repoAssociations.append(assoc)

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.removeRepoAssociation(assocID)) { state in
            state.repoAssociations = []
        }
    }

    // MARK: - Agent Status

    @Test func agentStoppedSetsPaneToWaiting() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.agentStopped(paneID: paneID)) { state in
            state.panes[id: paneID]?.status = .waitingForInput
        }
    }

    @Test func agentErrorSetsPaneToWaiting() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.agentError(paneID: paneID)) { state in
            state.panes[id: paneID]?.status = .waitingForInput
        }
    }

    @Test func clearPaneStatusResetsToIdle() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.status = .waitingForInput

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.clearPaneStatus(paneID)) { state in
            state.panes[id: paneID]?.status = .idle
        }
    }

    @Test func sessionStartedStoresSessionID() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.sessionStarted(paneID: paneID, sessionID: "abc-123")) {
            $0.panes[id: paneID]?.claudeSessionID = "abc-123"
        }
    }

    // MARK: - Undo Close Pane

    @Test func closeCapturesSnapshot() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstPaneID = workspace.panes.first!.id

        let secondPaneID = UUID()
        let secondPane = Pane(
            id: secondPaneID,
            label: "my-label",
            workingDirectory: "/tmp/test",
            claudeSessionID: "session-abc"
        )
        workspace.panes.append(secondPane)
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstPaneID),
            second: .leaf(secondPaneID)
        )
        workspace.focusedPaneID = secondPaneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.closePane(secondPaneID)) { state in
            state.recentlyClosedPanes = [
                ClosedPaneSnapshot(
                    workingDirectory: "/tmp/test",
                    label: "my-label",
                    type: .shell,
                    claudeSessionID: "session-abc"
                )
            ]
            state.panes.remove(id: secondPaneID)
            state.layout = .leaf(firstPaneID)
            state.focusedPaneID = firstPaneID
        }
    }

    @Test func reopenRestoresPane() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstPaneID = workspace.panes.first!.id
        workspace.recentlyClosedPanes = [
            ClosedPaneSnapshot(
                workingDirectory: "/tmp/restored",
                label: "restored-label",
                type: .shell,
                claudeSessionID: nil
            )
        ]

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .constant(newPaneID)
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reopenClosedPane) { state in
            state.recentlyClosedPanes = []
            state.panes.append(Pane(
                id: newPaneID,
                label: "restored-label",
                workingDirectory: "/tmp/restored"
            ))
            state.layout = .split(
                .horizontal,
                ratio: 0.5,
                first: .leaf(firstPaneID),
                second: .leaf(newPaneID)
            )
            state.focusedPaneID = newPaneID
        }
    }

    @Test func reopenEmptyStackIsNoop() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.reopenClosedPane)
        // State unchanged — no assertion closure needed
    }

    @Test func closedPaneStackCapsAt10() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let basePaneID = workspace.panes.first!.id

        // Create 11 extra panes and close them all
        var paneIDs: [UUID] = []
        for i in 0 ..< 11 {
            let id = UUID()
            paneIDs.append(id)
            workspace.panes.append(Pane(
                id: id,
                workingDirectory: "/tmp/dir\(i)"
            ))
        }
        // Build a layout with all panes — just a flat chain of splits
        var layout: PaneLayout = .leaf(basePaneID)
        for id in paneIDs {
            let (newLayout, _) = layout.splitting(
                paneID: basePaneID,
                direction: .horizontal,
                newPaneID: id
            )
            layout = newLayout
        }
        workspace.layout = layout
        workspace.focusedPaneID = basePaneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        for id in paneIDs {
            await store.send(.closePane(id))
        }

        #expect(store.state.recentlyClosedPanes.count == 10)
        // Oldest entry (dir0) should have been evicted
        #expect(store.state.recentlyClosedPanes.first?.workingDirectory == "/tmp/dir1")
        #expect(store.state.recentlyClosedPanes.last?.workingDirectory == "/tmp/dir10")
    }
}
