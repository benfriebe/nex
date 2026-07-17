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

    @Test func splitPaneAtPathDefaultsHorizontal() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let originalPaneID = workspace.panes.first!.id
        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newPaneID)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPaneAtPath("/tmp/foo")) { state in
            #expect(state.panes.count == 2)
            #expect(state.panes[id: newPaneID]?.workingDirectory == "/tmp/foo")
            if case .split(let dir, _, .leaf(let first), .leaf(let second)) = state.layout {
                #expect(dir == .horizontal)
                #expect(first == originalPaneID)
                #expect(second == newPaneID)
            } else {
                Issue.record("Expected horizontal split layout")
            }
        }
    }

    @Test func splitPaneAtPathRespectsVerticalDirection() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let originalPaneID = workspace.panes.first!.id
        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newPaneID)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPaneAtPath("/tmp/bar", direction: .vertical)) { state in
            #expect(state.panes.count == 2)
            #expect(state.panes[id: newPaneID]?.workingDirectory == "/tmp/bar")
            if case .split(let dir, _, .leaf(let first), .leaf(let second)) = state.layout {
                #expect(dir == .vertical)
                #expect(first == originalPaneID)
                #expect(second == newPaneID)
            } else {
                Issue.record("Expected vertical split layout")
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
                    agentSessionID: nil
                )
            ]
            state.panes.remove(id: secondPaneID)
            state.layout = .leaf(firstPaneID)
            state.focusedPaneID = firstPaneID
        }
    }

    // MARK: - Focus history (issue #56)

    /// Reproduces the exact scenario from issue #56: A and B in a
    /// split, focus walks A → B → A → B, close B → focus returns
    /// to A even though tree-traversal order would have picked A
    /// anyway here (the chain test below pins the non-trivial case).
    @Test func closePaneRestoresPreviousFocus() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneA = workspace.panes.first!.id
        let paneB = UUID()
        workspace.panes.append(Pane(id: paneB))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(paneA),
            second: .leaf(paneB)
        )

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.focusPane(paneB))
        await store.send(.focusPane(paneA))
        await store.send(.focusPane(paneB))

        #expect(store.state.focusedPaneID == paneB)
        // History: A pushed, then B pushed (when re-focusing A),
        // then A pushed again (when focusing B). Dedup means
        // history is [B, A] at this point.
        #expect(store.state.focusHistory == [paneB, paneA])

        await store.send(.closePane(paneB))
        #expect(store.state.focusedPaneID == paneA)
    }

    /// Three panes in focus order A → B → C. Closing C returns
    /// to B; closing B returns to A. Without the focus stack, the
    /// fallback would be `allPaneIDs.first` which depends on tree
    /// shape, not user history.
    @Test func closePaneFollowsHistoryChain() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneA = workspace.panes.first!.id
        let paneB = UUID()
        let paneC = UUID()
        workspace.panes.append(Pane(id: paneB))
        workspace.panes.append(Pane(id: paneC))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(paneA),
            second: .split(
                .horizontal, ratio: 0.5,
                first: .leaf(paneB),
                second: .leaf(paneC)
            )
        )

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.focusPane(paneB))
        await store.send(.focusPane(paneC))

        await store.send(.closePane(paneC))
        #expect(store.state.focusedPaneID == paneB)

        await store.send(.closePane(paneB))
        #expect(store.state.focusedPaneID == paneA)
    }

    /// When `focusHistory` is empty (e.g., focus was set directly
    /// without going through the reducer), close falls back to the
    /// existing `allPaneIDs.first` traversal. Pins the contract.
    @Test func closePaneFallsBackToFirstWhenHistoryEmpty() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneA = workspace.panes.first!.id
        let paneB = UUID()
        let paneC = UUID()
        workspace.panes.append(Pane(id: paneB))
        workspace.panes.append(Pane(id: paneC))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(paneA),
            second: .split(
                .horizontal, ratio: 0.5,
                first: .leaf(paneB),
                second: .leaf(paneC)
            )
        )
        // Direct assignment, no setFocus — history stays empty.
        workspace.focusedPaneID = paneB

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closePane(paneB))
        // Fallback: layout traversal yields paneA before paneC.
        #expect(store.state.focusedPaneID == paneA)
        #expect(store.state.focusHistory.isEmpty)
    }

    /// Closing a non-focused pane removes it from the history so
    /// later pops can't return it. Without the scrub, `popFocus...`
    /// would still skip it (the pane is gone), but we'd waste a
    /// slot and obscure intent.
    @Test func closeNonFocusedPaneRemovesItFromHistory() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneA = workspace.panes.first!.id
        let paneB = UUID()
        let paneC = UUID()
        workspace.panes.append(Pane(id: paneB))
        workspace.panes.append(Pane(id: paneC))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(paneA),
            second: .split(
                .horizontal, ratio: 0.5,
                first: .leaf(paneB),
                second: .leaf(paneC)
            )
        )

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // Focus order A → B → C. History at end: [A, B], focused on C.
        await store.send(.focusPane(paneB))
        await store.send(.focusPane(paneC))
        #expect(store.state.focusHistory == [paneA, paneB])

        // Close B (not focused). B leaves history.
        await store.send(.closePane(paneB))
        #expect(store.state.focusedPaneID == paneC)
        #expect(store.state.focusHistory == [paneA])

        // Close C → A, not B (B was scrubbed).
        await store.send(.closePane(paneC))
        #expect(store.state.focusedPaneID == paneA)
    }

    /// `paneProcessTerminated` for a shell pane forwards to
    /// `closePane`, so the focus stack should drive its refocus too.
    @Test func paneProcessTerminatedRestoresPreviousFocus() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneA = workspace.panes.first!.id
        let paneB = UUID()
        workspace.panes.append(Pane(id: paneB))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(paneA),
            second: .leaf(paneB)
        )

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.focusPane(paneB))
        await store.send(.paneProcessTerminated(paneID: paneB))
        await store.receive(\.closePane)

        #expect(store.state.focusedPaneID == paneA)
    }

    /// A workspace restored from persistence starts with an empty
    /// `focusHistory` (it's per-session, not persisted). Closing
    /// the restored pane should fall back to layout traversal
    /// without crashing or chasing stale UUIDs.
    @Test func restoredWorkspaceStartsWithEmptyHistory() async {
        let paneA = UUID()
        let paneB = UUID()
        let workspace = WorkspaceFeature.State(
            id: UUID(),
            name: "Restored",
            slug: "restored",
            color: .blue,
            panes: [Pane(id: paneA), Pane(id: paneB)],
            layout: .split(
                .horizontal, ratio: 0.5,
                first: .leaf(paneA),
                second: .leaf(paneB)
            ),
            focusedPaneID: paneB,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )
        #expect(workspace.focusHistory.isEmpty)

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closePane(paneB))
        #expect(store.state.focusedPaneID == paneA)
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
            state.focusHistory = [firstID]
        }

        await store.send(.focusNextPane) { state in
            state.focusedPaneID = firstID
            state.focusHistory = [firstID, secondID]
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

    @Test func resetMarkdownFontSizeRestoresDefault() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = UUID()
        workspace.panes.append(Pane(
            id: paneID,
            type: .markdown,
            filePath: "/tmp/note.md",
            markdownFontSize: 22
        ))

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.resetMarkdownFontSize(paneID)) { state in
            state.panes[id: paneID]?.markdownFontSize = Pane.defaultMarkdownFontSize
        }
    }

    @Test func resetMarkdownFontSizeIgnoresNonMarkdownPane() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = UUID()
        workspace.panes.append(Pane(id: paneID, type: .shell, markdownFontSize: 22))

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // No state mutation expected — guard rejects shell panes.
        await store.send(.resetMarkdownFontSize(paneID))
    }

    @Test func resetMarkdownFontSizeIgnoresEditingPane() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = UUID()
        workspace.panes.append(Pane(
            id: paneID,
            type: .markdown,
            filePath: "/tmp/note.md",
            isEditing: true,
            markdownFontSize: 22
        ))

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // No mutation: edit-mode panes use the editor's own zoom.
        await store.send(.resetMarkdownFontSize(paneID))
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

        await store.send(.agentStopped(paneID: paneID, backgroundTaskCount: 0)) { state in
            state.panes[id: paneID]?.status = .waitingForInput
        }
    }

    @Test func agentStoppedWithBackgroundWorkStaysRunning() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        // Simulate a live turn: the pane is already running with a clock.
        let started = Date(timeIntervalSince1970: 1000)
        workspace.panes[id: paneID]?.status = .running
        workspace.panes[id: paneID]?.agentStartedAt = started

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        // Turn ends but two background units are still in flight → the pane
        // must NOT flip to waiting; it stays running and records the count,
        // and the elapsed clock is untouched (issues #215, #220).
        await store.send(.agentStopped(paneID: paneID, backgroundTaskCount: 2)) { state in
            state.panes[id: paneID]?.backgroundTaskCount = 2
        }

        // Next Stop with an empty snapshot is the authoritative "awaiting
        // input" transition.
        await store.send(.agentStopped(paneID: paneID, backgroundTaskCount: 0)) { state in
            state.panes[id: paneID]?.status = .waitingForInput
            state.panes[id: paneID]?.backgroundTaskCount = 0
        }
    }

    @Test func agentStartedClearsBackgroundTaskCount() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.status = .running
        workspace.panes[id: paneID]?.backgroundTaskCount = 3

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 2000))
        }

        // A fresh turn supersedes the previous turn's background snapshot.
        await store.send(.agentStarted(paneID: paneID)) { state in
            state.panes[id: paneID]?.backgroundTaskCount = 0
            state.panes[id: paneID]?.agentKind = .claude
        }
    }

    @Test func agentStartedStoresCodexAgentKind() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.status = .idle

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 2000))
        }

        await store.send(.agentStarted(paneID: paneID, agent: .codex)) { state in
            state.panes[id: paneID]?.status = .running
            state.panes[id: paneID]?.agentStartedAt = Date(timeIntervalSince1970: 2000)
            state.panes[id: paneID]?.agentKind = .codex
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

    @Test func agentErrorClearsBackgroundTaskCount() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.status = .running
        workspace.panes[id: paneID]?.backgroundTaskCount = 4

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.agentError(paneID: paneID)) { state in
            state.panes[id: paneID]?.status = .waitingForInput
            state.panes[id: paneID]?.backgroundTaskCount = 0
        }
    }

    @Test func setPaneStatusClearsBackgroundTaskCount() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.status = .running
        workspace.panes[id: paneID]?.backgroundTaskCount = 2

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 3000))
        }

        // Manual override to "awaiting input" must not leave a stale count
        // lingering in the header / pane-list.
        await store.send(.setPaneStatus(paneID: paneID, status: .waitingForInput)) { state in
            state.panes[id: paneID]?.status = .waitingForInput
            state.panes[id: paneID]?.backgroundTaskCount = 0
        }
    }

    @Test func sessionStartedClearsBackgroundTaskCount() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.status = .running
        workspace.panes[id: paneID]?.backgroundTaskCount = 3

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        // A fresh session bounds a stuck `.running`: even if the final empty
        // Stop was dropped, the count can't pin the pane past a new session.
        await store.send(.sessionStarted(paneID: paneID, sessionID: "sess-new")) { state in
            state.panes[id: paneID]?.agentSessionID = "sess-new"
            state.panes[id: paneID]?.agentKind = .claude
            state.panes[id: paneID]?.backgroundTaskCount = 0
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
            $0.panes[id: paneID]?.agentSessionID = "abc-123"
            $0.panes[id: paneID]?.agentKind = .claude
        }
    }

    @Test func sessionStartedStoresCodexAgentKind() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.sessionStarted(paneID: paneID, sessionID: "codex-1", agent: .codex)) {
            $0.panes[id: paneID]?.agentSessionID = "codex-1"
            $0.panes[id: paneID]?.agentKind = .codex
        }
    }

    @Test func sessionEndedKeepsAgentKind() async {
        // agentKind is a last-known display value — dropping the session
        // id must not blank the badge's label source.
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.agentSessionID = "codex-1"
        workspace.panes[id: paneID]?.agentKind = .codex

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.sessionEnded(paneID: paneID, sessionID: "codex-1")) {
            $0.panes[id: paneID]?.agentSessionID = nil
        }
    }

    @Test func sessionEndedClearsMatchingSessionID() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        workspace.panes[id: paneID]?.agentSessionID = "abc-123"

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.sessionEnded(paneID: paneID, sessionID: "abc-123")) {
            $0.panes[id: paneID]?.agentSessionID = nil
        }
    }

    @Test func sessionEndedKeepsMismatchedSessionID() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id
        // A live session id different from the one that just ended:
        // `/clear` and compact fire SessionEnd(old) + SessionStart(new),
        // so a stale end must not clobber the current session.
        workspace.panes[id: paneID]?.agentSessionID = "new-session"

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        // No state change expected — the ending id no longer matches.
        await store.send(.sessionEnded(paneID: paneID, sessionID: "old-session"))
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
            agentSessionID: "session-abc"
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
                    agentSessionID: "session-abc"
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
                agentSessionID: nil
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

    @Test func closeReopenRoundTripsAgentKind() async {
        // The snapshot must carry agentKind so reopen resumes a codex
        // pane with `codex resume` and the pane keeps its badge label
        // (review of #101).
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstPaneID = workspace.panes.first!.id
        let secondPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        var codexPane = Pane(id: secondPaneID, workingDirectory: "/tmp/codex")
        codexPane.agentSessionID = "codex-sess-1"
        codexPane.agentKind = .codex
        workspace.panes.append(codexPane)
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstPaneID),
            second: .leaf(secondPaneID)
        )
        workspace.focusedPaneID = secondPaneID

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .constant(newPaneID)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closePane(secondPaneID))
        #expect(store.state.recentlyClosedPanes.last?.agentKind == .codex)
        #expect(store.state.recentlyClosedPanes.last?.agentSessionID == "codex-sess-1")

        await store.send(.reopenClosedPane)
        #expect(store.state.panes[id: newPaneID]?.agentKind == .codex)
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

    // MARK: - Zoom Pane

    @Test func toggleZoomExpandsAndRestores() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        let originalLayout = PaneLayout.split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.layout = originalLayout
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        // Zoom in
        await store.send(.toggleZoomPane) { state in
            state.savedLayout = originalLayout
            state.zoomedPaneID = firstID
            state.layout = .leaf(firstID)
        }

        // Zoom out
        await store.send(.toggleZoomPane) { state in
            state.savedLayout = nil
            state.zoomedPaneID = nil
            state.layout = originalLayout
        }
    }

    @Test func zoomSinglePaneIsNoop() async {
        let workspace = WorkspaceFeature.State(name: "Test")

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.toggleZoomPane)
        // State unchanged — single pane already fills workspace
    }

    @Test func closePaneWhileZoomedRestoresLayout() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        let originalLayout = PaneLayout.split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.layout = .leaf(firstID)
        workspace.savedLayout = originalLayout
        workspace.zoomedPaneID = firstID
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.closePane(firstID)) { state in
            // Zoom state cleared, layout restored then pane removed
            state.savedLayout = nil
            state.zoomedPaneID = nil
            state.recentlyClosedPanes = [
                ClosedPaneSnapshot(
                    workingDirectory: state.panes[id: firstID]!.workingDirectory,
                    label: nil,
                    type: .shell,
                    agentSessionID: nil
                )
            ]
            state.panes.remove(id: firstID)
            state.layout = .leaf(secondID)
            state.focusedPaneID = secondID
        }
    }

    @Test func splitWhileZoomedExitsZoom() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        let originalLayout = PaneLayout.split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.layout = .leaf(firstID)
        workspace.savedLayout = originalLayout
        workspace.zoomedPaneID = firstID
        workspace.focusedPaneID = firstID

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newPaneID)
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPane(direction: .horizontal, sourcePaneID: firstID)) { state in
            // Zoom state cleared
            state.savedLayout = nil
            state.zoomedPaneID = nil
            // Split happened on the restored layout
            state.panes.append(Pane(id: newPaneID, workingDirectory: state.panes[id: firstID]!.workingDirectory))
            state.focusedPaneID = newPaneID
            state.layout = .split(
                .horizontal,
                ratio: 0.5,
                first: .split(
                    .horizontal,
                    ratio: 0.5,
                    first: .leaf(firstID),
                    second: .leaf(newPaneID)
                ),
                second: .leaf(secondID)
            )
        }
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

    // MARK: - Scratchpad

    @Test func createScratchpadSplitsFromFocused() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let originalPaneID = workspace.panes.first!.id
        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newPaneID)
        }

        await store.send(.createScratchpad) { state in
            let newPane = Pane(
                id: newPaneID,
                type: .scratchpad,
                title: "Scratchpad",
                workingDirectory: NSHomeDirectory(),
                isEditing: true,
                createdAt: Date(timeIntervalSince1970: 1000),
                lastActivityAt: Date(timeIntervalSince1970: 1000)
            )
            state.panes.append(newPane)
            state.layout = .split(
                .horizontal,
                ratio: 0.5,
                first: .leaf(originalPaneID),
                second: .leaf(newPaneID)
            )
            state.focusedPaneID = newPaneID
            state.focusHistory = [originalPaneID]
        }
    }

    @Test func scratchpadContentChangedUpdatesState() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let paneID = UUID()
        workspace.panes.append(Pane(
            id: paneID,
            type: .scratchpad,
            isEditing: true
        ))

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.scratchpadContentChanged(paneID: paneID, content: "hello world")) { state in
            state.panes[id: paneID]?.scratchpadContent = "hello world"
        }
    }

    @Test func closeScratchpadCapturesContent() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstPaneID = workspace.panes.first!.id

        let scratchID = UUID()
        let scratchPane = Pane(
            id: scratchID,
            type: .scratchpad,
            isEditing: true,
            scratchpadContent: "saved notes"
        )
        workspace.panes.append(scratchPane)
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstPaneID),
            second: .leaf(scratchID)
        )
        workspace.focusedPaneID = scratchID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.closePane(scratchID)) { state in
            state.recentlyClosedPanes = [
                ClosedPaneSnapshot(
                    workingDirectory: NSHomeDirectory(),
                    type: .scratchpad,
                    scratchpadContent: "saved notes"
                )
            ]
            state.panes.remove(id: scratchID)
            state.layout = .leaf(firstPaneID)
            state.focusedPaneID = firstPaneID
        }
    }

    @Test func reopenScratchpadRestoresContent() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstPaneID = workspace.panes.first!.id
        workspace.recentlyClosedPanes = [
            ClosedPaneSnapshot(
                workingDirectory: NSHomeDirectory(),
                type: .scratchpad,
                scratchpadContent: "restored notes"
            )
        ]

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!

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
                type: .scratchpad,
                workingDirectory: NSHomeDirectory(),
                isEditing: true,
                scratchpadContent: "restored notes"
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

    // MARK: - Layout Cycling

    @Test func cycleLayoutWithSinglePaneIsNoop() async {
        let workspace = WorkspaceFeature.State(name: "Test")

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.cycleLayout)
        // State unchanged — single pane
    }

    @Test func cycleLayoutAppliesFirstLayout() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.cycleLayout) { state in
            // First layout is evenHorizontal — with focused pane first
            state.layout = PredefinedLayout.evenHorizontal.buildLayout(for: [firstID, secondID])
            state.currentLayoutIndex = 0
        }
    }

    @Test func cycleLayoutCyclesThroughAll() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        let layoutCount = PredefinedLayout.allCases.count

        // Cycle through all layouts
        for i in 0 ..< layoutCount {
            await store.send(.cycleLayout)
            #expect(store.state.currentLayoutIndex == i)
        }

        // Wraps back to 0
        await store.send(.cycleLayout)
        #expect(store.state.currentLayoutIndex == 0)
    }

    @Test func cycleLayoutPreservesFocus() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = secondID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.cycleLayout)
        #expect(store.state.focusedPaneID == secondID)
    }

    @Test func selectLayoutAppliesCorrectLayout() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.selectLayout(.tiled)) { state in
            state.layout = PredefinedLayout.tiled.buildLayout(for: [firstID, secondID])
            state.currentLayoutIndex = PredefinedLayout.allCases.firstIndex(of: .tiled)!
        }
    }

    @Test func splitPaneResetsLayoutIndex() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID
        workspace.currentLayoutIndex = 2

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newPaneID)
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPane(direction: .horizontal, sourcePaneID: firstID))
        #expect(store.state.currentLayoutIndex == nil)
    }

    @Test func closePaneResetsLayoutIndex() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID
        workspace.currentLayoutIndex = 1

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closePane(secondID))
        #expect(store.state.currentLayoutIndex == nil)
    }

    // MARK: - Move Pane in Direction

    @Test func movePaneRightSwapsWithNeighbor() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.movePaneInDirection(.right)) { state in
            state.layout = .split(
                .horizontal, ratio: 0.5,
                first: .leaf(secondID),
                second: .leaf(firstID)
            )
            state.currentLayoutIndex = nil
        }
    }

    @Test func movePaneNoNeighborIsNoOp() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = secondID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.movePaneInDirection(.right))
        // No change — secondID has no right neighbor
    }

    @Test func movePaneSinglePaneIsNoOp() async {
        let workspace = WorkspaceFeature.State(name: "Test")

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.movePaneInDirection(.left))
    }

    @Test func movePaneWhileZoomedIsNoOp() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .leaf(firstID)
        workspace.savedLayout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.zoomedPaneID = firstID
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.movePaneInDirection(.right))
        // No change — zoomed
    }

    @Test func movePaneResetsLayoutIndex() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        workspace.layout = .split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = firstID
        workspace.currentLayoutIndex = 2

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.movePaneInDirection(.right)) { state in
            state.layout = .split(
                .horizontal, ratio: 0.5,
                first: .leaf(secondID),
                second: .leaf(firstID)
            )
            state.currentLayoutIndex = nil
        }
    }

    // MARK: - Markdown edit mode with $EDITOR

    private func stubbedEditorService(command: String?) -> EditorService {
        EditorService(
            resolveEditor: { command == nil ? nil : "nvim" },
            buildCommand: { _ in command },
            warmUp: {}
        )
    }

    @Test func toggleMarkdownEditLaunchesExternalEditorWhenResolvable() async {
        // Workspace with a single markdown pane that has a file path.
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(
                id: paneID,
                type: .markdown,
                workingDirectory: "/tmp",
                filePath: "/tmp/plan.md"
            )
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID

        let editorCommand = "/bin/zsh -l -c \"nvim '/tmp/plan.md'\""

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.editorService = stubbedEditorService(command: editorCommand)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleMarkdownEdit(paneID)) { state in
            state.panes[id: paneID]?.isEditing = true
            state.panes[id: paneID]?.externalEditorCommand = editorCommand
        }
    }

    @Test func toggleMarkdownEditFallsBackToBuiltinWhenEditorUnresolved() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(
                id: paneID,
                type: .markdown,
                workingDirectory: "/tmp",
                filePath: "/tmp/plan.md"
            )
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.editorService = stubbedEditorService(command: nil)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleMarkdownEdit(paneID)) { state in
            state.panes[id: paneID]?.isEditing = true
            state.panes[id: paneID]?.externalEditorCommand = nil
        }
    }

    @Test func toggleMarkdownEditWithoutFilePathUsesBuiltin() async {
        // A markdown pane opened without a file path (edge case — shouldn't
        // normally happen, but the reducer must not crash or launch an editor
        // on a phantom path).
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(
                id: paneID,
                type: .markdown,
                workingDirectory: "/tmp",
                filePath: nil
            )
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.editorService = stubbedEditorService(command: "nvim ''")
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleMarkdownEdit(paneID)) { state in
            state.panes[id: paneID]?.isEditing = true
            state.panes[id: paneID]?.externalEditorCommand = nil
        }
    }

    @Test func toggleSearchOpensForMarkdownPaneInViewMode() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(id: paneID, type: .markdown, workingDirectory: "/tmp", filePath: "/tmp/x.md")
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID

        let store = TestStore(initialState: workspace) { WorkspaceFeature() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.toggleSearch) { state in
            state.searchingPaneID = paneID
            state.searchNeedle = ""
            state.searchTotal = nil
            state.searchSelected = nil
        }
    }

    @Test func toggleSearchIgnoredOnMarkdownPaneInEditMode() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(
                id: paneID,
                type: .markdown,
                workingDirectory: "/tmp",
                filePath: "/tmp/x.md",
                isEditing: true
            )
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID

        let store = TestStore(initialState: workspace) { WorkspaceFeature() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.toggleSearch)
        // No state change asserted: state.searchingPaneID stays nil.
    }

    @Test func toggleSearchOpensForWebPane() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [Pane(id: paneID, type: .web, workingDirectory: "/tmp")]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID
        workspace.webPanes = [
            paneID: WebPaneState(
                tabs: [WebTab(id: UUID(), url: "https://example.com")],
                activeTabID: nil,
                isPrivate: false
            )
        ]

        let store = TestStore(initialState: workspace) { WorkspaceFeature() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleSearch) { state in
            state.searchingPaneID = paneID
            state.searchNeedle = ""
            state.searchTotal = nil
            state.searchSelected = nil
        }
    }

    @Test func searchCloseClearsStateForWebPane() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [Pane(id: paneID, type: .web, workingDirectory: "/tmp")]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID
        workspace.webPanes = [
            paneID: WebPaneState(
                tabs: [WebTab(id: UUID(), url: "https://example.com")],
                activeTabID: nil,
                isPrivate: false
            )
        ]
        workspace.searchingPaneID = paneID
        workspace.searchNeedle = "foo"
        workspace.searchTotal = 3
        workspace.searchSelected = 1

        let store = TestStore(initialState: workspace) { WorkspaceFeature() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.searchClose) { state in
            state.searchingPaneID = nil
            state.searchNeedle = ""
            state.searchTotal = nil
            state.searchSelected = nil
        }
    }

    @Test func webPaneTabSwitchWhileSearchingPreservesSearchState() async {
        let paneID = UUID()
        let tabA = UUID()
        let tabB = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [Pane(id: paneID, type: .web, workingDirectory: "/tmp")]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID
        workspace.webPanes = [
            paneID: WebPaneState(
                tabs: [WebTab(id: tabA, url: "https://a.example"), WebTab(id: tabB, url: "https://b.example")],
                activeTabID: tabA,
                isPrivate: false
            )
        ]
        workspace.searchingPaneID = paneID
        workspace.searchNeedle = "foo"

        let store = TestStore(initialState: workspace) { WorkspaceFeature() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // Switching the active tab retargets find (no coordinator in
        // tests, so the effect is a no-op) without dropping the bar.
        await store.send(.webPaneTabSelect(paneID: paneID, tabID: tabB)) { state in
            state.webPanes[paneID]?.activeTabID = tabB
        }
        #expect(store.state.searchingPaneID == paneID)
        #expect(store.state.searchNeedle == "foo")
    }

    @Test func toggleMarkdownEditDismissesActiveSearch() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(id: paneID, type: .markdown, workingDirectory: "/tmp", filePath: nil)
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID
        workspace.searchingPaneID = paneID
        workspace.searchNeedle = "foo"
        workspace.searchTotal = 3
        workspace.searchSelected = 1

        let store = TestStore(initialState: workspace) { WorkspaceFeature() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.editorService = stubbedEditorService(command: "nvim ''")
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleMarkdownEdit(paneID)) { state in
            state.panes[id: paneID]?.isEditing = true
            state.searchingPaneID = nil
            state.searchNeedle = ""
            state.searchTotal = nil
            state.searchSelected = nil
        }
    }

    @Test func toggleMarkdownEditExitingExternalModeClearsCommand() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(
                id: paneID,
                type: .markdown,
                workingDirectory: "/tmp",
                filePath: "/tmp/plan.md",
                isEditing: true,
                externalEditorCommand: "nvim /tmp/plan.md"
            )
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.editorService = .testValue
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleMarkdownEdit(paneID)) { state in
            state.panes[id: paneID]?.isEditing = false
            state.panes[id: paneID]?.externalEditorCommand = nil
        }
    }

    @Test func paneProcessTerminatedOnExternalEditorFlipsBackToViewMode() async {
        let paneID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(
                id: paneID,
                type: .markdown,
                workingDirectory: "/tmp",
                filePath: "/tmp/plan.md",
                isEditing: true,
                externalEditorCommand: "nvim /tmp/plan.md"
            )
        ]
        workspace.layout = .leaf(paneID)
        workspace.focusedPaneID = paneID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.editorService = .testValue
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.paneProcessTerminated(paneID: paneID)) { state in
            state.panes[id: paneID]?.isEditing = false
            state.panes[id: paneID]?.externalEditorCommand = nil
        }

        // The pane must NOT have been removed by a forwarded closePane.
        #expect(store.state.panes[id: paneID] != nil)
    }

    @Test func closePaneDestroysSurfaceForExternalEditorMarkdown() async {
        // Regression guard: closing a markdown pane while its external editor
        // is running must tear down the backing ghostty surface, not leak it.
        let editingID = UUID()
        let siblingID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(
                id: editingID,
                type: .markdown,
                workingDirectory: "/tmp",
                filePath: "/tmp/plan.md",
                isEditing: true,
                externalEditorCommand: "nvim /tmp/plan.md"
            ),
            Pane(id: siblingID, type: .shell)
        ]
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(editingID),
            second: .leaf(siblingID)
        )
        workspace.focusedPaneID = editingID

        // Pre-populate SurfaceManager to mirror production state: when the
        // pane entered external edit mode the reducer would have created a
        // surface bound to its UUID. In tests GhosttyApp.shared.app is nil,
        // so SurfaceView's init bails out before calling ghostty C APIs, but
        // the SurfaceManager entry is still created — exactly what we need
        // to observe whether destroySurface runs.
        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: editingID, workingDirectory: "/tmp")
        #expect(surfaceManager.activeSurfaceCount == 1)

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.editorService = .testValue
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closePane(editingID))
        await store.finish()

        #expect(store.state.panes[id: editingID] == nil)
        #expect(surfaceManager.activeSurfaceCount == 0)
    }

    @Test func paneProcessTerminatedOnShellPaneStillClosesIt() async {
        // Regression guard: the markdown-editor special case must not affect
        // the existing shell-pane behaviour.
        let firstID = UUID()
        let secondID = UUID()
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.panes = [
            Pane(id: firstID, type: .shell),
            Pane(id: secondID, type: .shell)
        ]
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.focusedPaneID = secondID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.editorService = .testValue
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.paneProcessTerminated(paneID: secondID))
        // Let the forwarded closePane action run.
        await store.receive(\.closePane)
        #expect(store.state.panes[id: secondID] == nil)
    }

    @Test func cycleLayoutUnzoomsFirst() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let secondID = UUID()
        workspace.panes.append(Pane(id: secondID))
        let originalLayout = PaneLayout.split(
            .horizontal, ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(secondID)
        )
        workspace.layout = .leaf(firstID) // zoomed
        workspace.savedLayout = originalLayout
        workspace.zoomedPaneID = firstID
        workspace.focusedPaneID = firstID

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }

        await store.send(.cycleLayout) { state in
            state.savedLayout = nil
            state.zoomedPaneID = nil
            // Layout should be the first predefined layout
            state.layout = PredefinedLayout.evenHorizontal.buildLayout(for: [firstID, secondID])
            state.currentLayoutIndex = 0
        }
    }

    // MARK: - openMarkdownFile --here (reuse)

    @Test func openMarkdownFileReusesPaneInPlace() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let sourceID = workspace.panes.first!.id
        let siblingID = UUID()
        workspace.panes.append(Pane(id: siblingID))
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(sourceID),
            second: .leaf(siblingID)
        )
        workspace.focusedPaneID = sourceID
        let sourceCwd = workspace.panes[id: sourceID]!.workingDirectory

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000ABCDEF")!
        let fixedNow = Date(timeIntervalSince1970: 1000)

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(fixedNow)
            $0.uuid = .constant(newPaneID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openMarkdownFile(filePath: "/tmp/plan.md", reusePaneID: sourceID)) { state in
            // Source moved to parked lane (alive but off-layout), not removed.
            #expect(state.panes[id: sourceID] == nil)
            #expect(state.parkedPanes[id: sourceID] != nil)
            #expect(state.parkedPanes[id: sourceID]?.workingDirectory == sourceCwd)
            let created = state.panes[id: newPaneID]
            #expect(created?.type == .markdown)
            #expect(created?.filePath == "/tmp/plan.md")
            #expect(created?.label == "plan.md")
            // New markdown pane links back to the parked source so close
            // knows to restore it.
            #expect(created?.parkedSourcePaneID == sourceID)
            #expect(state.focusedPaneID == newPaneID)
            #expect(state.currentLayoutIndex == nil)
            // Layout: sibling is preserved, source leaf swapped for newPaneID.
            if case .split(let dir, let ratio, .leaf(let first), .leaf(let second)) = state.layout {
                #expect(dir == .horizontal)
                #expect(ratio == 0.5)
                #expect(first == newPaneID)
                #expect(second == siblingID)
            } else {
                Issue.record("Expected horizontal split with source leaf replaced by new pane")
            }
            // Park is a dismiss-not-close: no recentlyClosedPanes snapshot.
            #expect(state.recentlyClosedPanes.isEmpty)
        }
    }

    @Test func openMarkdownFileReuseWhenOnlyPane() async {
        var workspace = WorkspaceFeature.State(name: "Solo")
        let sourceID = workspace.panes.first!.id
        workspace.layout = .leaf(sourceID)
        workspace.focusedPaneID = sourceID

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000111111")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 2000))
            $0.uuid = .constant(newPaneID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openMarkdownFile(filePath: "/tmp/notes.md", reusePaneID: sourceID)) { state in
            #expect(state.panes[id: sourceID] == nil)
            #expect(state.panes.count == 1)
            #expect(state.parkedPanes.count == 1)
            #expect(state.parkedPanes[id: sourceID] != nil)
            #expect(state.panes[id: newPaneID]?.parkedSourcePaneID == sourceID)
            #expect(state.layout == .leaf(newPaneID))
            #expect(state.focusedPaneID == newPaneID)
        }
    }

    @Test func openMarkdownFileReusePreservesBackingSurfaceForShell() async {
        // Correctness claim: reusing a shell pane must NOT tear down
        // its backing ghostty surface. The PTY stays alive while the
        // pane is parked, ready for closePane to unpark it back into
        // the layout with all state (scrollback, prompt, jobs) intact.
        var workspace = WorkspaceFeature.State(name: "Test")
        let sourceID = workspace.panes.first!.id
        let siblingID = UUID()
        workspace.panes.append(Pane(id: siblingID, type: .shell))
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(sourceID),
            second: .leaf(siblingID)
        )
        workspace.focusedPaneID = sourceID

        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: sourceID, workingDirectory: "/tmp")
        #expect(surfaceManager.activeSurfaceCount == 1)
        let originalSurface = surfaceManager.surface(for: sourceID)

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000333333")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.date = .constant(Date(timeIntervalSince1970: 4000))
            $0.uuid = .constant(newPaneID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openMarkdownFile(filePath: "/tmp/plan.md", reusePaneID: sourceID))
        await store.finish()

        // Source is parked (still alive), surface untouched.
        #expect(store.state.panes[id: sourceID] == nil)
        #expect(store.state.parkedPanes[id: sourceID] != nil)
        #expect(surfaceManager.activeSurfaceCount == 1)
        #expect(surfaceManager.surface(for: sourceID) === originalSurface)
    }

    @Test func openMarkdownFileReuseClearsZoomAndSearchState() async {
        var workspace = WorkspaceFeature.State(name: "Zoomed")
        let sourceID = workspace.panes.first!.id
        let siblingID = UUID()
        workspace.panes.append(Pane(id: siblingID))
        let fullLayout: PaneLayout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(sourceID),
            second: .leaf(siblingID)
        )
        workspace.layout = .leaf(sourceID) // zoomed layout
        workspace.savedLayout = fullLayout
        workspace.zoomedPaneID = sourceID
        workspace.focusedPaneID = sourceID
        workspace.searchingPaneID = sourceID
        workspace.searchNeedle = "foo"
        workspace.searchTotal = 3
        workspace.searchSelected = 1

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000222222")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 3000))
            $0.uuid = .constant(newPaneID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openMarkdownFile(filePath: "/tmp/x.md", reusePaneID: sourceID)) { state in
            // Zoom restored to full layout, then source swapped for new pane.
            #expect(state.savedLayout == nil)
            #expect(state.zoomedPaneID == nil)
            if case .split(_, _, .leaf(let first), .leaf(let second)) = state.layout {
                #expect(first == newPaneID)
                #expect(second == siblingID)
            } else {
                Issue.record("Expected restored layout with source leaf replaced")
            }
            // Search state cleared because source was the searching pane.
            #expect(state.searchingPaneID == nil)
            #expect(state.searchNeedle == "")
            #expect(state.searchTotal == nil)
            #expect(state.searchSelected == nil)
            #expect(state.focusedPaneID == newPaneID)
            // Source parked for later restore.
            #expect(state.parkedPanes[id: sourceID] != nil)
        }
    }

    // MARK: - Close markdown pane → unpark source (--here round-trip)

    @Test func closeMarkdownUnparksSource() async {
        // Round-trip: shell → `--here` markdown → close markdown.
        // The shell's surface (PTY) must be the SAME object before and
        // after — that's the whole point of the feature.
        var workspace = WorkspaceFeature.State(name: "Test")
        let shellID = workspace.panes.first!.id
        let siblingID = UUID()
        workspace.panes.append(Pane(id: siblingID, type: .shell))
        workspace.layout = .split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(shellID),
            second: .leaf(siblingID)
        )
        workspace.focusedPaneID = shellID

        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: shellID, workingDirectory: "/tmp")
        let originalSurface = surfaceManager.surface(for: shellID)
        #expect(originalSurface != nil)

        let markdownID = UUID(uuidString: "00000000-0000-0000-0000-0000000FFFFF")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.date = .constant(Date(timeIntervalSince1970: 5000))
            $0.uuid = .constant(markdownID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openMarkdownFile(filePath: "/tmp/plan.md", reusePaneID: shellID))
        await store.finish()
        #expect(store.state.parkedPanes[id: shellID] != nil)

        await store.send(.closePane(markdownID))
        await store.finish()

        // Shell back in the visible pane set; markdown gone; layout
        // restored to shell + sibling; focus on shell.
        #expect(store.state.panes[id: shellID] != nil)
        #expect(store.state.panes[id: markdownID] == nil)
        #expect(store.state.parkedPanes[id: shellID] == nil)
        #expect(store.state.focusedPaneID == shellID)
        if case .split(_, _, .leaf(let first), .leaf(let second)) = store.state.layout {
            #expect(first == shellID)
            #expect(second == siblingID)
        } else {
            Issue.record("Expected layout restored with shell + sibling split")
        }
        // Surface identity: same SurfaceView instance, PTY untouched.
        #expect(surfaceManager.surface(for: shellID) === originalSurface)
        #expect(surfaceManager.activeSurfaceCount == 1)
    }

    @Test func closeMarkdownWithExternalEditorTearsDownOnlyOwnSurface() async {
        // While the source is parked, the markdown pane itself can
        // have entered external-editor mode (its own PTY). On close
        // we tear down the markdown's surface but leave the parked
        // shell's surface alone.
        var workspace = WorkspaceFeature.State(name: "Test")
        let shellID = workspace.panes.first!.id
        workspace.layout = .leaf(shellID)
        workspace.focusedPaneID = shellID

        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: shellID, workingDirectory: "/tmp")
        let shellSurface = surfaceManager.surface(for: shellID)

        let markdownID = UUID(uuidString: "00000000-0000-0000-0000-00000000EEEE")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.date = .constant(Date(timeIntervalSince1970: 5000))
            $0.uuid = .constant(markdownID)
            $0.gitService.getCurrentBranch = { _ in nil }
            // Resolvable editor so toggleMarkdownEdit flips to
            // external-editor mode and createSurface(paneID: markdownID)
            // runs through the real path.
            $0.editorService.buildCommand = { path in "nvim \(path)" }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // 1. --here parks shell, creates markdown pane.
        await store.send(.openMarkdownFile(filePath: "/tmp/plan.md", reusePaneID: shellID))
        await store.finish()

        // 2. Markdown enters external editor mode → second surface.
        await store.send(.toggleMarkdownEdit(markdownID))
        await store.finish()
        #expect(store.state.panes[id: markdownID]?.isUsingExternalEditor == true)
        #expect(surfaceManager.activeSurfaceCount == 2)

        // 3. Close markdown. Unpark branch runs; markdown's own
        // surface is destroyed but shell's stays alive.
        await store.send(.closePane(markdownID))
        await store.finish()

        #expect(surfaceManager.surface(for: markdownID) == nil)
        #expect(surfaceManager.surface(for: shellID) === shellSurface)
        #expect(surfaceManager.activeSurfaceCount == 1)
        #expect(store.state.panes[id: shellID] != nil)
        #expect(store.state.parkedPanes[id: shellID] == nil)
    }

    @Test func chainedReuseUnwindsOneLevel() async {
        // shell → --here → mdA; from mdA → --here → mdB.
        // Close mdB: mdA comes back (still linked to shell).
        // Close mdA: shell comes back.
        var workspace = WorkspaceFeature.State(name: "Chain")
        let shellID = workspace.panes.first!.id
        workspace.layout = .leaf(shellID)
        workspace.focusedPaneID = shellID

        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: shellID, workingDirectory: "/tmp")
        let shellSurface = surfaceManager.surface(for: shellID)

        let mdAID = UUID(uuidString: "00000000-0000-0000-0000-000000AAAAAA")!
        let mdBID = UUID(uuidString: "00000000-0000-0000-0000-000000BBBBBB")!

        // First `--here`: shellID → mdAID
        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.date = .constant(Date(timeIntervalSince1970: 5000))
            $0.uuid = .constant(mdAID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openMarkdownFile(filePath: "/tmp/A.md", reusePaneID: shellID))
        await store.finish()
        #expect(store.state.parkedPanes[id: shellID] != nil)
        #expect(store.state.panes[id: mdAID]?.parkedSourcePaneID == shellID)

        // Second `--here`: mdAID → mdBID. Swap the uuid dep.
        store.dependencies.uuid = .constant(mdBID)
        await store.send(.openMarkdownFile(filePath: "/tmp/B.md", reusePaneID: mdAID))
        await store.finish()
        // shell still parked (deeper); mdA parked on top.
        #expect(store.state.parkedPanes[id: shellID] != nil)
        #expect(store.state.parkedPanes[id: mdAID] != nil)
        #expect(store.state.panes[id: mdBID]?.parkedSourcePaneID == mdAID)
        // Critical chain invariant: parked mdA keeps its link to shell.
        #expect(store.state.parkedPanes[id: mdAID]?.parkedSourcePaneID == shellID)

        // Close B → mdA restored, still linked to shell.
        await store.send(.closePane(mdBID))
        await store.finish()
        #expect(store.state.panes[id: mdAID] != nil)
        #expect(store.state.panes[id: mdAID]?.parkedSourcePaneID == shellID)
        #expect(store.state.parkedPanes[id: mdAID] == nil)
        #expect(store.state.parkedPanes[id: shellID] != nil)
        #expect(store.state.focusedPaneID == mdAID)

        // Close A → shell restored.
        await store.send(.closePane(mdAID))
        await store.finish()
        #expect(store.state.panes[id: shellID] != nil)
        #expect(store.state.parkedPanes.isEmpty)
        #expect(store.state.focusedPaneID == shellID)

        // Shell's surface is the same all the way through.
        #expect(surfaceManager.surface(for: shellID) === shellSurface)
    }

    @Test func parkedShellTerminationEvictsAndUnlinks() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let shellID = workspace.panes.first!.id
        workspace.layout = .leaf(shellID)
        workspace.focusedPaneID = shellID

        let surfaceManager = SurfaceManager()
        surfaceManager.createSurface(paneID: shellID, workingDirectory: "/tmp")

        let markdownID = UUID(uuidString: "00000000-0000-0000-0000-00000000CCCC")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.date = .constant(Date(timeIntervalSince1970: 5000))
            $0.uuid = .constant(markdownID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openMarkdownFile(filePath: "/tmp/plan.md", reusePaneID: shellID))
        await store.finish()
        #expect(store.state.parkedPanes[id: shellID] != nil)

        // Parked shell's process dies unexpectedly.
        await store.send(.paneProcessTerminated(paneID: shellID))
        await store.finish()

        // Parked lane emptied; markdown's link cleared so a subsequent
        // close takes the normal path.
        #expect(store.state.parkedPanes[id: shellID] == nil)
        #expect(store.state.panes[id: markdownID]?.parkedSourcePaneID == nil)
        #expect(surfaceManager.activeSurfaceCount == 0)
    }

    // MARK: - openDiffPane

    @Test func openDiffPaneSplitsAndCreatesDiffPane() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        let sourceID = workspace.panes.first!.id
        workspace.layout = .leaf(sourceID)
        workspace.focusedPaneID = sourceID

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000DDDDDD")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 3000))
            $0.uuid = .constant(newPaneID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openDiffPane(repoPath: "/tmp/repo", targetPath: nil)) { state in
            let created = state.panes[id: newPaneID]
            #expect(created?.type == .diff)
            #expect(created?.workingDirectory == "/tmp/repo")
            #expect(created?.filePath == nil)
            #expect(created?.label == "repo")
            #expect(state.focusedPaneID == newPaneID)
            // Layout split: source on one side, new diff pane on the other.
            if case .split(_, _, .leaf(let first), .leaf(let second)) = state.layout {
                #expect((first == sourceID && second == newPaneID)
                    || (first == newPaneID && second == sourceID))
            } else {
                Issue.record("Expected split layout after openDiffPane")
            }
        }
    }

    @Test func reopenClosedDiffPaneDoesNotCreateSurface() async {
        // Diff panes have no PTY — reopening one must not spin up a shell
        // surface behind the WKWebView.
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        workspace.recentlyClosedPanes = [
            ClosedPaneSnapshot(
                workingDirectory: "/tmp/repo",
                label: "repo",
                type: .diff,
                filePath: nil,
                agentSessionID: nil
            )
        ]

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000DDDD01")!
        let surfaceManager = SurfaceManager()

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = surfaceManager
            $0.uuid = .constant(newPaneID)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reopenClosedPane) { state in
            #expect(state.recentlyClosedPanes.isEmpty)
            #expect(state.panes[id: newPaneID]?.type == .diff)
            #expect(state.panes[id: newPaneID]?.workingDirectory == "/tmp/repo")
            #expect(state.focusedPaneID == newPaneID)
            // Layout split horizontally with the original pane.
            if case .split(_, _, .leaf(let first), .leaf(let second)) = state.layout {
                #expect(first == firstID)
                #expect(second == newPaneID)
            } else {
                Issue.record("Expected split layout after reopening diff pane")
            }
        }
        await store.finish()

        // Critical: no surface was created for the diff pane.
        #expect(surfaceManager.activeSurfaceCount == 0)
    }

    @Test func openDiffPaneUnzoomsBeforeSplitting() async {
        // Opening a diff while a pane is zoomed must restore the saved layout
        // first; otherwise the diff pane gets spliced into the temporary
        // single-pane layout and disappears on the next unzoom.
        var workspace = WorkspaceFeature.State(name: "Test")
        let firstID = workspace.panes.first!.id
        let zoomedID = UUID()
        workspace.panes.append(Pane(id: zoomedID))
        let originalLayout = PaneLayout.split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .leaf(zoomedID)
        )
        workspace.layout = .leaf(zoomedID) // zoomed in
        workspace.savedLayout = originalLayout // remembered for restore
        workspace.zoomedPaneID = zoomedID
        workspace.focusedPaneID = zoomedID

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000DDDD02")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 5000))
            $0.uuid = .constant(newPaneID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openDiffPane(repoPath: "/tmp/repo", targetPath: nil)) { state in
            // Zoom state cleared before splitting.
            #expect(state.savedLayout == nil)
            #expect(state.zoomedPaneID == nil)
            // Layout was rebuilt from the originalLayout, then split off the
            // focused (zoomed) pane — so the original sibling is preserved.
            #expect(state.panes[id: newPaneID]?.type == .diff)
            #expect(state.panes[id: firstID] != nil)
            #expect(state.panes[id: zoomedID] != nil)
            #expect(state.focusedPaneID == newPaneID)
            // Diff pane must be reachable in the live layout (not orphaned).
            #expect(state.layout.contains(paneID: newPaneID))
            #expect(state.layout.contains(paneID: firstID))
        }
    }

    @Test func openDiffPaneWithTargetPathUsesTargetAsLabel() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.focusedPaneID = workspace.panes.first?.id

        let newPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000EEEEE")!

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 4000))
            $0.uuid = .constant(newPaneID)
            $0.gitService.getCurrentBranch = { _ in nil }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openDiffPane(
            repoPath: "/tmp/repo",
            targetPath: "/tmp/repo/Sources/Foo.swift"
        )) { state in
            let created = state.panes[id: newPaneID]
            #expect(created?.type == .diff)
            #expect(created?.workingDirectory == "/tmp/repo")
            #expect(created?.filePath == "/tmp/repo/Sources/Foo.swift")
            #expect(created?.label == "Foo.swift")
            #expect(created?.title == "diff: Foo.swift")
        }
    }

    // MARK: - Labels

    @Test func addLabelAppendsAndDedupes() async {
        let workspace = WorkspaceFeature.State(name: "Labelled")
        let store = TestStore(initialState: workspace) { WorkspaceFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addLabel("backend")) { state in
            #expect(state.labels == ["backend"])
        }
        await store.send(.addLabel("priority")) { state in
            #expect(state.labels == ["backend", "priority"])
        }
        // Duplicate: no change.
        await store.send(.addLabel("backend"))
        #expect(store.state.labels == ["backend", "priority"])
    }

    @Test func addLabelTrimsAndRejectsEmpty() async {
        let workspace = WorkspaceFeature.State(name: "Labelled")
        let store = TestStore(initialState: workspace) { WorkspaceFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addLabel("  blocked  ")) { state in
            #expect(state.labels == ["blocked"])
        }
        await store.send(.addLabel("   "))
        #expect(store.state.labels == ["blocked"])
        await store.send(.addLabel(""))
        #expect(store.state.labels == ["blocked"])
    }

    @Test func removeLabelDropsMatch() async {
        var workspace = WorkspaceFeature.State(name: "Labelled")
        workspace.labels = ["a", "b", "c"]
        let store = TestStore(initialState: workspace) { WorkspaceFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.removeLabel("b")) { state in
            #expect(state.labels == ["a", "c"])
        }
        // Removing a missing label is a no-op.
        await store.send(.removeLabel("z"))
        #expect(store.state.labels == ["a", "c"])
    }

    @Test func setLabelsReplacesAndDedupes() async {
        var workspace = WorkspaceFeature.State(name: "Labelled")
        workspace.labels = ["old"]
        let store = TestStore(initialState: workspace) { WorkspaceFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setLabels(["one", " two ", "one", "", "three"])) { state in
            #expect(state.labels == ["one", "two", "three"])
        }
    }

    @Test func setLabelsWithAllEmptyClearsAllLabels() async {
        var workspace = WorkspaceFeature.State(name: "Labelled")
        workspace.labels = ["alpha", "beta"]
        let store = TestStore(initialState: workspace) { WorkspaceFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setLabels(["", "  ", "\n"])) { state in
            #expect(state.labels == [])
        }
    }

    @Test func addLabelClampsLengthToMax() async {
        let workspace = WorkspaceFeature.State(name: "Labelled")
        let store = TestStore(initialState: workspace) { WorkspaceFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let oversized = String(repeating: "x", count: 500)
        await store.send(.addLabel(oversized)) { state in
            #expect(state.labels.count == 1)
            #expect(state.labels.first?.count == WorkspaceFeature.maxLabelLength)
        }
    }

    @Test func addLabelTreatsCaseAsDistinct() async {
        let workspace = WorkspaceFeature.State(name: "Labelled")
        let store = TestStore(initialState: workspace) { WorkspaceFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addLabel("Backend")) { state in
            #expect(state.labels == ["Backend"])
        }
        await store.send(.addLabel("backend")) { state in
            #expect(state.labels == ["Backend", "backend"])
        }
    }

    /// Issue #117: `pane create --workspace <empty> --name … --path …`
    /// lays out the first pane via `.createPane`. That action must honour
    /// the caller-supplied id, label and working directory so the pane the
    /// reply acked actually carries them (finding 2).
    @Test func createPaneAppliesInjectedIdLabelAndDirectory() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let newID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newID)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.createPane(
            newPaneID: newID, label: "first", workingDirectory: "/tmp/wd117"
        )) { state in
            #expect(state.panes[id: newID]?.label == "first")
            #expect(state.panes[id: newID]?.workingDirectory == "/tmp/wd117")
            #expect(state.layout == .leaf(newID))
        }
    }

    /// Issue #117: bare `.createPane()` (GUI / new-workspace path) keeps
    /// its default working directory and no label — defaults unchanged.
    @Test func createPaneDefaultsUnchanged() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let newID = UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(newID)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.createPane()) { state in
            #expect(state.panes[id: newID]?.label == nil)
            #expect(state.panes[id: newID]?.workingDirectory == NSHomeDirectory())
        }
    }

    // MARK: - setPaneStatus (issue #183)

    /// The pane context menu's manual status override updates `Pane.status`.
    @Test func setPaneStatusUpdatesStatus() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setPaneStatus(paneID: paneID, status: .waitingForInput)) { state in
            #expect(state.panes[id: paneID]?.status == .waitingForInput)
        }
        await store.send(.setPaneStatus(paneID: paneID, status: .idle)) { state in
            #expect(state.panes[id: paneID]?.status == .idle)
        }
    }

    /// Manually marking a pane `.running` starts the elapsed clock so the
    /// "claude · mm:ss" badge ticks from the moment of the override.
    @Test func setPaneStatusToRunningStartsClock() async {
        let now = Date(timeIntervalSince1970: 5000)
        let workspace = WorkspaceFeature.State(name: "Test")
        let paneID = workspace.panes.first!.id

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(now)
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setPaneStatus(paneID: paneID, status: .running)) { state in
            #expect(state.panes[id: paneID]?.status == .running)
            #expect(state.panes[id: paneID]?.agentStartedAt == now)
        }
    }

    /// A repeated `.running` override doesn't reset the elapsed clock — only a
    /// fresh non-running → running transition stamps `agentStartedAt`.
    @Test func setPaneStatusRunningPreservesExistingClock() async {
        let firstStart = Date(timeIntervalSince1970: 5000)
        var pane = Pane(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!)
        pane.status = .running
        pane.agentStartedAt = firstStart
        let workspace = WorkspaceFeature.State(
            id: UUID(uuidString: "10000000-0000-0000-0000-0000000000aa")!,
            name: "Test", slug: "test", color: .blue,
            panes: [pane], layout: .leaf(pane.id),
            focusedPaneID: pane.id, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 9999))
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setPaneStatus(paneID: pane.id, status: .running)) { state in
            #expect(state.panes[id: pane.id]?.agentStartedAt == firstStart)
        }
    }

    /// The `.shell` gate is defended in the reducer, not just the view — so a
    /// stray dispatch (e.g. a future CLI verb) targeting a markdown / diff /
    /// web pane is a no-op rather than mutating a pane that never renders
    /// status.
    @Test func setPaneStatusOnNonShellPaneIsNoOp() async {
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
        let pane = Pane(id: paneID, type: .markdown)
        let workspace = WorkspaceFeature.State(
            id: UUID(uuidString: "10000000-0000-0000-0000-0000000000bb")!,
            name: "Test", slug: "test", color: .blue,
            panes: [pane], layout: .leaf(paneID),
            focusedPaneID: paneID, createdAt: Date(), lastAccessedAt: Date()
        )

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        // The reducer guards on pane type, so status stays idle.
        await store.send(.setPaneStatus(paneID: paneID, status: .running))
        #expect(store.state.panes[id: paneID]?.status == .idle)
        #expect(store.state.panes[id: paneID]?.agentStartedAt == nil)
    }
}
