import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

struct WorkspaceColorSelectionTests {
    private static func makeWorkspace(color: WorkspaceColor) -> WorkspaceFeature.State {
        let id = UUID()
        let paneID = UUID()
        return WorkspaceFeature.State(
            id: id,
            name: "WS",
            slug: "ws-\(id.uuidString.prefix(8).lowercased())",
            color: color,
            panes: [Pane(id: paneID)],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(),
            lastAccessedAt: Date()
        )
    }

    @Test func nextRandomColorOnEmptyCollectionReturnsAnyColor() {
        let workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = []
        let color = workspaces.nextRandomColor()
        #expect(WorkspaceColor.allCases.contains(color))
    }

    @Test func nextRandomColorNeverMatchesLastWorkspaceColor() {
        for excluded in WorkspaceColor.allCases {
            let workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [
                Self.makeWorkspace(color: .blue),
                Self.makeWorkspace(color: excluded)
            ]
            for _ in 0 ..< 200 {
                let picked = workspaces.nextRandomColor()
                #expect(picked != excluded)
                #expect(WorkspaceColor.allCases.contains(picked))
            }
        }
    }

    @Test func nextRandomColorReturnsColorFromRemainingPalette() {
        let workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [
            Self.makeWorkspace(color: .red)
        ]
        let remaining = WorkspaceColor.allCases.filter { $0 != .red }
        for _ in 0 ..< 200 {
            let picked = workspaces.nextRandomColor()
            #expect(remaining.contains(picked))
        }
    }
}
