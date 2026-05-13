import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct QuitConfirmationTests {
    private static let wsID1 = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private static let wsID2 = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    private static func workspace(
        id: UUID,
        paneStatuses: [PaneStatus],
        paneTypes: [PaneType]? = nil
    ) -> WorkspaceFeature.State {
        let panes = paneStatuses.enumerated().map { index, status in
            Pane(
                id: UUID(),
                type: paneTypes?[index] ?? .shell,
                status: status
            )
        }
        let layout: PaneLayout = panes.first.map { .leaf($0.id) } ?? .empty
        return WorkspaceFeature.State(
            id: id,
            name: "ws-\(id.uuidString.prefix(4))",
            slug: "ws",
            color: .blue,
            panes: IdentifiedArray(uniqueElements: panes),
            layout: layout,
            focusedPaneID: panes.first?.id,
            createdAt: Date(timeIntervalSince1970: 0),
            lastAccessedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func emptyStateHasNoActiveAgents() {
        let state = AppReducer.State()
        #expect(state.activeAgentSummary == .zero)
        #expect(state.activeAgentSummary.isEmpty)
    }

    @Test func idleOnlyWorkspaceHasNoActiveAgents() {
        var state = AppReducer.State()
        state.workspaces = [Self.workspace(id: Self.wsID1, paneStatuses: [.idle, .idle])]
        #expect(state.activeAgentSummary == .zero)
    }

    @Test func runningPaneCountsAsActive() {
        var state = AppReducer.State()
        state.workspaces = [Self.workspace(id: Self.wsID1, paneStatuses: [.running])]
        let summary = state.activeAgentSummary
        #expect(summary.agentCount == 1)
        #expect(summary.workspaceCount == 1)
    }

    @Test func waitingForInputCountsAsActive() {
        var state = AppReducer.State()
        state.workspaces = [Self.workspace(id: Self.wsID1, paneStatuses: [.waitingForInput])]
        let summary = state.activeAgentSummary
        #expect(summary.agentCount == 1)
        #expect(summary.workspaceCount == 1)
    }

    @Test func mixedStatusOnlyCountsNonIdle() {
        var state = AppReducer.State()
        state.workspaces = [
            Self.workspace(id: Self.wsID1, paneStatuses: [.idle, .running, .waitingForInput, .idle])
        ]
        let summary = state.activeAgentSummary
        #expect(summary.agentCount == 2)
        #expect(summary.workspaceCount == 1)
    }

    @Test func workspaceWithoutActivePanesIsExcludedFromCount() {
        var state = AppReducer.State()
        state.workspaces = [
            Self.workspace(id: Self.wsID1, paneStatuses: [.running, .idle]),
            Self.workspace(id: Self.wsID2, paneStatuses: [.idle, .idle])
        ]
        let summary = state.activeAgentSummary
        #expect(summary.agentCount == 1)
        #expect(summary.workspaceCount == 1)
    }

    @Test func multipleWorkspacesWithActivePanesSumCorrectly() {
        var state = AppReducer.State()
        state.workspaces = [
            Self.workspace(id: Self.wsID1, paneStatuses: [.running, .running]),
            Self.workspace(id: Self.wsID2, paneStatuses: [.waitingForInput])
        ]
        let summary = state.activeAgentSummary
        #expect(summary.agentCount == 3)
        #expect(summary.workspaceCount == 2)
    }

    @Test func messageMatchesPluralization() {
        let single = ActivitySummary(agentCount: 1, workspaceCount: 1)
        let multiple = ActivitySummary(agentCount: 3, workspaceCount: 2)
        #expect(QuitGate.message(for: single).contains("1 active agent across 1 workspace"))
        #expect(QuitGate.message(for: multiple).contains("3 active agents across 2 workspaces"))
    }

    @Test func messageHandlesEmptySummary() {
        // The dialog fires unconditionally when the user has the
        // setting enabled; for the no-active-agent case the body
        // falls back to a generic "are you sure" prompt.
        let summary = ActivitySummary.zero
        #expect(QuitGate.message(for: summary) == "Are you sure you want to quit Nex?")
    }

    @Test func parkedPanesAreCountedAlongsideVisiblePanes() {
        var workspace = Self.workspace(id: Self.wsID1, paneStatuses: [.running])
        workspace.parkedPanes = IdentifiedArray(uniqueElements: [
            Pane(id: UUID(), type: .shell, status: .waitingForInput)
        ])
        var state = AppReducer.State()
        state.workspaces = [workspace]
        let summary = state.activeAgentSummary
        #expect(summary.agentCount == 2)
        #expect(summary.workspaceCount == 1)
    }

    @Test func parkedPaneAloneIsEnoughToTriggerDialog() {
        var workspace = Self.workspace(id: Self.wsID1, paneStatuses: [.idle])
        workspace.parkedPanes = IdentifiedArray(uniqueElements: [
            Pane(id: UUID(), type: .shell, status: .running)
        ])
        var state = AppReducer.State()
        state.workspaces = [workspace]
        let summary = state.activeAgentSummary
        #expect(summary.agentCount == 1)
        #expect(summary.workspaceCount == 1)
        #expect(!summary.isEmpty)
    }
}
