import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Unit tests for the workspace-scoped synchronise-input feature
/// added in issue #121. We assert reducer behaviour (state transitions
/// + SurfaceManager pushes) here; the actual libghostty mirroring is
/// covered by the cua VM validator.
@MainActor
struct SyncInputTests {
    @Test func toggleSyncInputActivatesAndIncludesAllPanes() async {
        let firstPaneID = UUID(uuidString: "00000000-0000-0000-0000-00000000aaaa")!
        let secondPaneID = UUID(uuidString: "00000000-0000-0000-0000-00000000bbbb")!
        var workspace = WorkspaceFeature.State(id: UUID(), name: "Sync")
        // Replace the auto-created pane with two predictable ones.
        workspace.panes = [Pane(id: firstPaneID), Pane(id: secondPaneID)]
        workspace.layout = .split(.horizontal, ratio: 0.5,
                                  first: .leaf(firstPaneID), second: .leaf(secondPaneID))
        workspace.focusedPaneID = firstPaneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleSyncInput) { state in
            #expect(state.isSyncInputActive)
            #expect(state.syncedPaneIDs == Set([firstPaneID, secondPaneID]))
        }
    }

    @Test func toggleSyncInputOffClearsExclusions() async {
        let paneA = UUID(uuidString: "00000000-0000-0000-0000-00000000cccc")!
        let paneB = UUID(uuidString: "00000000-0000-0000-0000-00000000dddd")!
        var workspace = WorkspaceFeature.State(id: UUID(), name: "Sync")
        workspace.panes = [Pane(id: paneA), Pane(id: paneB)]
        workspace.layout = .split(.horizontal, ratio: 0.5,
                                  first: .leaf(paneA), second: .leaf(paneB))
        workspace.focusedPaneID = paneA
        workspace.isSyncInputActive = true
        workspace.syncInputExcluded = [paneB]

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleSyncInput) { state in
            #expect(state.isSyncInputActive == false)
            #expect(state.syncInputExcluded.isEmpty)
            #expect(state.syncedPaneIDs.isEmpty)
        }
    }

    @Test func setSyncInputExcludedRemovesPaneFromSyncedSet() async {
        let paneA = UUID(uuidString: "00000000-0000-0000-0000-00000000eeee")!
        let paneB = UUID(uuidString: "00000000-0000-0000-0000-00000000ffff")!
        var workspace = WorkspaceFeature.State(id: UUID(), name: "Sync")
        workspace.panes = [Pane(id: paneA), Pane(id: paneB)]
        workspace.layout = .split(.horizontal, ratio: 0.5,
                                  first: .leaf(paneA), second: .leaf(paneB))
        workspace.focusedPaneID = paneA
        workspace.isSyncInputActive = true

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setSyncInputExcluded(paneID: paneB, excluded: true)) { state in
            #expect(state.syncInputExcluded == Set([paneB]))
            // syncedPaneIDs returns [] when fewer than 2 panes would
            // participate — excluding the only sibling collapses to
            // a no-op group, which is the right answer for broadcast.
            #expect(state.syncedPaneIDs.isEmpty)
        }
    }

    @Test func newSplitPaneAutoJoinsSyncGroup() async {
        let originalPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000001111")!
        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000002222")!
        var workspace = WorkspaceFeature.State(id: UUID(), name: "Sync")
        workspace.panes = [Pane(id: originalPaneID), Pane(id: newPaneID)]
        workspace.layout = .leaf(originalPaneID)
        workspace.focusedPaneID = originalPaneID
        workspace.isSyncInputActive = true
        // syncedPaneIDs only kicks in with >=2 panes — start with the
        // original solo and assert the split brings the count to 2.
        let initialWorkspace = WorkspaceFeature.State(
            id: workspace.id,
            name: "Sync",
            slug: "sync",
            color: .blue,
            panes: [Pane(id: originalPaneID)],
            layout: .leaf(originalPaneID),
            focusedPaneID: originalPaneID,
            createdAt: Date(timeIntervalSince1970: 0),
            lastAccessedAt: Date(timeIntervalSince1970: 0)
        )
        var seededWorkspace = initialWorkspace
        seededWorkspace.isSyncInputActive = true

        let store = TestStore(initialState: seededWorkspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newPaneID)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPane(direction: .horizontal, sourcePaneID: originalPaneID)) { state in
            #expect(state.panes.count == 2)
            #expect(state.isSyncInputActive)
            // Both panes now in the sync set — issue #121 promises
            // new panes opened mid-sync auto-join the group.
            #expect(state.syncedPaneIDs == Set([originalPaneID, newPaneID]))
        }
    }

    @Test func surfaceManagerSetSyncGroupReplacesPrevious() {
        let mgr = SurfaceManager()
        let workspaceID = UUID()
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()

        mgr.setSyncGroup(workspaceID: workspaceID, paneIDs: [paneA, paneB])
        #expect(mgr.isSyncing(paneID: paneA))
        #expect(mgr.isSyncing(paneID: paneB))
        #expect(!mgr.isSyncing(paneID: paneC))

        mgr.setSyncGroup(workspaceID: workspaceID, paneIDs: [paneA, paneC])
        #expect(mgr.isSyncing(paneID: paneA))
        #expect(!mgr.isSyncing(paneID: paneB))
        #expect(mgr.isSyncing(paneID: paneC))

        mgr.setSyncGroup(workspaceID: workspaceID, paneIDs: [])
        #expect(!mgr.isSyncing(paneID: paneA))
        #expect(!mgr.isSyncing(paneID: paneC))
    }

    @Test func surfaceManagerKeepsWorkspaceGroupsIsolated() {
        let mgr = SurfaceManager()
        let workspace1 = UUID()
        let workspace2 = UUID()
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()
        let paneD = UUID()

        mgr.setSyncGroup(workspaceID: workspace1, paneIDs: [paneA, paneB])
        mgr.setSyncGroup(workspaceID: workspace2, paneIDs: [paneC, paneD])

        // The real cross-workspace boundary check: a key from paneA
        // resolves to siblings strictly within workspace1's group,
        // and paneC's siblings strictly within workspace2's group.
        #expect(mgr.syncTargetIDs(sourcePaneID: paneA) == Set([paneB]))
        #expect(mgr.syncTargetIDs(sourcePaneID: paneB) == Set([paneA]))
        #expect(mgr.syncTargetIDs(sourcePaneID: paneC) == Set([paneD]))
        #expect(mgr.syncTargetIDs(sourcePaneID: paneD) == Set([paneC]))
        // Source is always excluded from its own target set, even if
        // someone constructed a degenerate single-pane group.
        #expect(!mgr.syncTargetIDs(sourcePaneID: paneA).contains(paneA))

        // Clearing workspace1 leaves workspace2's group intact.
        mgr.setSyncGroup(workspaceID: workspace1, paneIDs: [])
        #expect(mgr.syncTargetIDs(sourcePaneID: paneA).isEmpty)
        #expect(mgr.syncTargetIDs(sourcePaneID: paneC) == Set([paneD]))
    }
}
