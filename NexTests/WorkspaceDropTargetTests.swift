import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Unit tests for the pure DropTarget resolver used by Phase 4 drag-and-drop.
/// Uses synthetic row heights + geometry so tests don't depend on SwiftUI
/// layout, only on the walk-and-resolve algorithm in WorkspaceDropTarget.swift.
@MainActor
struct WorkspaceDropTargetTests {
    private static let wsA = UUID(uuidString: "50000000-0000-0000-0000-00000000000A")!
    private static let wsB = UUID(uuidString: "50000000-0000-0000-0000-00000000000B")!
    private static let wsC = UUID(uuidString: "50000000-0000-0000-0000-00000000000C")!
    private static let wsD = UUID(uuidString: "50000000-0000-0000-0000-00000000000D")!
    private static let groupG = UUID(uuidString: "50000000-0000-0000-0000-0000000000E1")!
    private static let groupH = UUID(uuidString: "50000000-0000-0000-0000-0000000000E2")!

    /// Uniform row height for easy arithmetic. `yTop = index * rowH + startY`.
    private static let rowH: CGFloat = 20
    private static let startY: CGFloat = 4

    private static func makeWorkspace(id: UUID) -> WorkspaceFeature.State {
        let paneID = UUID()
        return WorkspaceFeature.State(
            id: id,
            name: "ws",
            slug: "ws",
            color: .blue,
            panes: [Pane(id: paneID)],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private func heights(for ids: [SidebarID]) -> [SidebarID: CGFloat] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.rowH) })
    }

    // MARK: - Top-level only

    /// Three top-level workspaces, drag A. Cursor over top half of B → drop
    /// before B at post-remove topLevel index 0.
    @Test func topLevelDropBeforeNextRow() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let c = Self.makeWorkspace(id: Self.wsC)
        let workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [a, b, c]
        let topLevelOrder: [SidebarID] = [.workspace(Self.wsA), .workspace(Self.wsB), .workspace(Self.wsC)]
        let rowHeights = heights(for: topLevelOrder)

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [],
            workspaces: workspaces,
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // Source A is skipped; zones = [B at post-index 0, C at post-index 1].
        // Layout (yTop after startY=4): A at 4, B at 24, C at 44.
        // Cursor at 28 = B's top half (mid = 24 + 20/2 = 34).
        let target = resolveDropTarget(zones: zones, cursorY: 28)
        #expect(target == .topLevel(index: 0))
    }

    @Test func topLevelDropAfterRow() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let c = Self.makeWorkspace(id: Self.wsC)
        let topLevelOrder: [SidebarID] = [.workspace(Self.wsA), .workspace(Self.wsB), .workspace(Self.wsC)]
        let rowHeights = heights(for: topLevelOrder)

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [],
            workspaces: [a, b, c],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // Cursor at 40 = B's bottom half → drop after B → post-remove index 1.
        let target = resolveDropTarget(zones: zones, cursorY: 40)
        #expect(target == .topLevel(index: 1))
    }

    /// Cursor inside the gap where the source was → nil (no-op drop).
    @Test func cursorOverSourceGapYieldsNil() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let topLevelOrder: [SidebarID] = [.workspace(Self.wsA), .workspace(Self.wsB)]
        let rowHeights = heights(for: topLevelOrder)

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [],
            workspaces: [a, b],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // A was at y 4..24. With A as source, that slot has no zone.
        // Cursor at 10 falls in the gap.
        let target = resolveDropTarget(zones: zones, cursorY: 10)
        #expect(target == nil)
    }

    // MARK: - Groups

    /// Group header: top half → drop before group (at top level), bottom half
    /// → drop onto group. Use a scenario where the source is AFTER the group
    /// so that "drop before group" differs from the source's current slot.
    @Test func groupHeaderTopHalfDropsBefore() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let group = WorkspaceGroup(id: Self.groupG, name: "G", isCollapsed: true, childOrder: [])
        let topLevelOrder: [SidebarID] = [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsB)
        ]
        let rowHeights = heights(for: [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsB)
        ])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a, b],
            rowHeights: rowHeights,
            draggedID: Self.wsB,
            startY: Self.startY
        )
        // Source B is skipped (at end). Post-remove indices: A=0, G=1.
        // Ys: A 4..24, G 24..44, B 44..64 (skipped).
        // Cursor at 28 = top half of G header → drop before G at post-idx 1.
        let target = resolveDropTarget(zones: zones, cursorY: 28)
        #expect(target == .topLevel(index: 1))
    }

    @Test func groupHeaderBottomHalfDropsOnto() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let group = WorkspaceGroup(id: Self.groupG, name: "G", isCollapsed: true, childOrder: [])
        let topLevelOrder: [SidebarID] = [.workspace(Self.wsA), .group(Self.groupG)]
        let rowHeights = heights(for: [.workspace(Self.wsA), .group(Self.groupG)])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // Bottom half (cursor at 40): onto group.
        let target = resolveDropTarget(zones: zones, cursorY: 40)
        #expect(target == .ontoGroupHeader(groupID: Self.groupG))
    }

    /// Expanded empty group placeholder → intoGroup at index 0.
    @Test func emptyGroupPlaceholderDropsIntoGroup() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let group = WorkspaceGroup(id: Self.groupG, name: "G", isCollapsed: false, childOrder: [])
        let topLevelOrder: [SidebarID] = [.workspace(Self.wsA), .group(Self.groupG)]
        let rowHeights = heights(for: [.workspace(Self.wsA), .group(Self.groupG)])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY,
            emptyPlaceholderHeight: 28
        )
        // A (4..24 skipped), header (24..44), empty placeholder (44..72).
        // Cursor at 50 — inside the placeholder.
        let target = resolveDropTarget(zones: zones, cursorY: 50)
        #expect(target == .intoGroup(groupID: Self.groupG, index: 0))
    }

    /// Expanded group with children: dropping between children uses
    /// post-remove child indices.
    @Test func groupChildDropBetweenReorders() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let c = Self.makeWorkspace(id: Self.wsC)
        let group = WorkspaceGroup(
            id: Self.groupG,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsA, Self.wsB, Self.wsC]
        )
        let topLevelOrder: [SidebarID] = [.group(Self.groupG)]
        let rowHeights = heights(for: [
            .group(Self.groupG),
            .workspace(Self.wsA),
            .workspace(Self.wsB),
            .workspace(Self.wsC)
        ])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a, b, c],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // Layout with A as source:
        // header 4..24, A 24..44 (skipped, yTop advances), B 44..64 (childIdx 0),
        // C 64..84 (childIdx 1).
        // Cursor at 50 = top half of B → intoGroup(G, 0).
        let topHalf = resolveDropTarget(zones: zones, cursorY: 50)
        #expect(topHalf == .intoGroup(groupID: Self.groupG, index: 0))

        // Cursor at 60 = bottom half of B → intoGroup(G, 1).
        let bottomHalf = resolveDropTarget(zones: zones, cursorY: 60)
        #expect(bottomHalf == .intoGroup(groupID: Self.groupG, index: 1))
    }

    /// Source in group, dragging to top level.
    @Test func dragFromGroupToTopLevel() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let c = Self.makeWorkspace(id: Self.wsC)
        let group = WorkspaceGroup(
            id: Self.groupG,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsB]
        )
        // Layout: A (top), G header, B (inside G), C (top after G).
        let topLevelOrder: [SidebarID] = [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsC)
        ]
        let rowHeights = heights(for: [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsB),
            .workspace(Self.wsC)
        ])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a, b, c],
            rowHeights: rowHeights,
            draggedID: Self.wsB,
            startY: Self.startY
        )
        // Ys: A 4..24 (top-idx 0), header 24..44 (top-idx 1), B 44..64 skipped,
        // C 64..84 (top-idx 2).
        // Cursor over top half of A (10) → drop before A → topLevel(0).
        let beforeA = resolveDropTarget(zones: zones, cursorY: 10)
        #expect(beforeA == .topLevel(index: 0))

        // Cursor over bottom half of C (80) → drop after C → topLevel(3).
        let afterC = resolveDropTarget(zones: zones, cursorY: 80)
        #expect(afterC == .topLevel(index: 3))
    }

    /// Cursor above the first zone (inside the source's own gap) → nil,
    /// so the same-container live-reorder doesn't flicker back to start.
    /// Cursor below the last zone → drop at end, so users can drop
    /// AFTER the final top-level entry (especially a group, which
    /// otherwise has no row below it to target).
    @Test func cursorBelowZonesFallsThroughToEnd() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let topLevelOrder: [SidebarID] = [.workspace(Self.wsA), .workspace(Self.wsB)]
        let rowHeights = heights(for: topLevelOrder)

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [],
            workspaces: [a, b],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // Above (in the source's vacated slot) stays nil.
        #expect(resolveDropTarget(zones: zones, cursorY: 0) == nil)
        // Well below the last zone resolves to topLevel(end) so drop-at-
        // end works when the final entry is a group.
        #expect(resolveDropTarget(zones: zones, cursorY: 500) == .topLevel(index: 1))
    }

    /// The motivating bug: workspace cannot be dropped below the final
    /// group in the sidebar. Cursor anywhere below the group's bottom
    /// edge should resolve to drop-at-end.
    @Test func cursorBelowTrailingGroupDropsAtTopLevelEnd() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let group = WorkspaceGroup(
            id: Self.groupG,
            name: "G",
            isCollapsed: true,
            childOrder: []
        )
        // Layout: [A, G] — G is the last entry.
        let topLevelOrder: [SidebarID] = [.workspace(Self.wsA), .group(Self.groupG)]
        let rowHeights = heights(for: [.workspace(Self.wsA), .group(Self.groupG)])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // A is source. Zones: G header at y 24..44 (post-idx 0).
        // Cursor at 200 (well below G's bottom): drop at end.
        // Post-remove topLevelOrder is [G] (1 entry), so drop-at-end = index 1.
        #expect(resolveDropTarget(zones: zones, cursorY: 200) == .topLevel(index: 1))
    }

    // MARK: - Spring-load

    /// Without spring-load, a collapsed group emits only its header zone —
    /// its children (if any) are not hit-testable.
    @Test func collapsedGroupEmitsOnlyHeaderZone() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let c = Self.makeWorkspace(id: Self.wsC)
        let d = Self.makeWorkspace(id: Self.wsD)
        let group = WorkspaceGroup(
            id: Self.groupG,
            name: "G",
            isCollapsed: true,
            childOrder: [Self.wsC, Self.wsD]
        )
        let topLevelOrder: [SidebarID] = [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsB)
        ]
        let rowHeights = heights(for: [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsC),
            .workspace(Self.wsD),
            .workspace(Self.wsB)
        ])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a, b, c, d],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            startY: Self.startY
        )
        // No groupChild zones because the group is collapsed.
        let hasChildZones = zones.contains { if case .groupChild = $0.kind { true } else { false } }
        #expect(hasChildZones == false)
    }

    // MARK: - topLevelDropZones (group drag)

    /// A top-level span covers the *full extent* of each non-source entry.
    /// For an expanded group that means header + children's heights.
    @Test func topLevelSpansCoverFullGroupBlock() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let c = Self.makeWorkspace(id: Self.wsC)
        let groupG = WorkspaceGroup(
            id: Self.groupG,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsB, Self.wsC]
        )
        let groupH = WorkspaceGroup(
            id: Self.groupH,
            name: "H",
            isCollapsed: true,
            childOrder: []
        )
        let topLevelOrder: [SidebarID] = [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .group(Self.groupH)
        ]
        let rowHeights = heights(for: [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsB),
            .workspace(Self.wsC),
            .group(Self.groupH)
        ])

        // Drag group H (empty, collapsed). H is skipped; spans are A
        // (workspace) and G (expanded block: header + 2 children).
        let spans = topLevelDropZones(
            topLevelOrder: topLevelOrder,
            groups: [groupG, groupH],
            workspaces: [a, b, c],
            rowHeights: rowHeights,
            draggedGroupID: Self.groupH,
            startY: Self.startY
        )
        #expect(spans.count == 2)
        // A span: y 4..24 (row height 20).
        #expect(spans[0].yTop == 4)
        #expect(spans[0].yBottom == 24)
        #expect(spans[0].postRemoveTopIndex == 0)
        // G block: header (24..44) + B (44..64) + C (64..84) = y 24..84.
        #expect(spans[1].yTop == 24)
        #expect(spans[1].yBottom == 84)
        #expect(spans[1].postRemoveTopIndex == 1)
    }

    /// The source group is visually collapsed during its own drag, so its
    /// block shrinks to just the header regardless of `isCollapsed`.
    @Test func topLevelSpansSkipSourceGroupBlockHeight() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let groupG = WorkspaceGroup(
            id: Self.groupG,
            name: "G",
            isCollapsed: false,
            childOrder: [Self.wsB]
        )
        let topLevelOrder: [SidebarID] = [
            .group(Self.groupG),
            .workspace(Self.wsA)
        ]
        let rowHeights = heights(for: [
            .group(Self.groupG),
            .workspace(Self.wsB),
            .workspace(Self.wsA)
        ])

        let spans = topLevelDropZones(
            topLevelOrder: topLevelOrder,
            groups: [groupG],
            workspaces: [a, b],
            rowHeights: rowHeights,
            draggedGroupID: Self.groupG,
            startY: Self.startY
        )
        // G is source: skipped, but advances yTop by just the header (20),
        // not by header + child. So A's span starts at y = 4 + 20 = 24.
        #expect(spans.count == 1)
        #expect(spans[0].yTop == 24)
        #expect(spans[0].yBottom == 44)
        #expect(spans[0].postRemoveTopIndex == 0)
    }

    /// Resolver returns topLevel index for group drags; ignores group/child
    /// zones entirely.
    @Test func resolveTopLevelDropTargetHalves() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let groupG = WorkspaceGroup(id: Self.groupG, name: "G", isCollapsed: true, childOrder: [])
        let topLevelOrder: [SidebarID] = [
            .workspace(Self.wsA),
            .workspace(Self.wsB),
            .group(Self.groupG)
        ]
        let rowHeights = heights(for: [
            .workspace(Self.wsA),
            .workspace(Self.wsB),
            .group(Self.groupG)
        ])

        let spans = topLevelDropZones(
            topLevelOrder: topLevelOrder,
            groups: [groupG],
            workspaces: [a, b],
            rowHeights: rowHeights,
            draggedGroupID: Self.groupG,
            startY: Self.startY
        )
        // A 4..24 (idx 0), B 24..44 (idx 1), G skipped.
        // Cursor at 10 = top half of A → topLevel(0).
        #expect(resolveTopLevelDropTarget(spans: spans, cursorY: 10) == .topLevel(index: 0))
        // Cursor at 40 = bottom half of B → topLevel(2).
        #expect(resolveTopLevelDropTarget(spans: spans, cursorY: 40) == .topLevel(index: 2))
        // Cursor well below all spans → drop at end so group drags can
        // land after the final top-level entry.
        #expect(resolveTopLevelDropTarget(spans: spans, cursorY: 200) == .topLevel(index: 2))
    }

    /// When `springLoadedGroupID` matches a collapsed group, the walker
    /// must treat it as expanded and emit child zones so the drag can
    /// target precise positions inside it.
    @Test func springLoadedCollapsedGroupExposesChildZones() {
        let a = Self.makeWorkspace(id: Self.wsA)
        let b = Self.makeWorkspace(id: Self.wsB)
        let c = Self.makeWorkspace(id: Self.wsC)
        let d = Self.makeWorkspace(id: Self.wsD)
        let group = WorkspaceGroup(
            id: Self.groupG,
            name: "G",
            isCollapsed: true,
            childOrder: [Self.wsC, Self.wsD]
        )
        let topLevelOrder: [SidebarID] = [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsB)
        ]
        let rowHeights = heights(for: [
            .workspace(Self.wsA),
            .group(Self.groupG),
            .workspace(Self.wsC),
            .workspace(Self.wsD),
            .workspace(Self.wsB)
        ])

        let zones = dropZones(
            topLevelOrder: topLevelOrder,
            groups: [group],
            workspaces: [a, b, c, d],
            rowHeights: rowHeights,
            draggedID: Self.wsA,
            springLoadedGroupID: Self.groupG,
            startY: Self.startY
        )
        // Expect child zones for C (childIdx 0) and D (childIdx 1).
        let childIDs = zones.compactMap { zone -> UUID? in
            if case .groupChild(_, let childID, _) = zone.kind { return childID }
            return nil
        }
        #expect(childIDs == [Self.wsC, Self.wsD])

        // Layout: A 4..24 (top-idx 0), header 24..44 (top-idx 1),
        // C 44..64 (childIdx 0), D 64..84 (childIdx 1), B 84..104 (top-idx 2).
        // Cursor at 50 (top half of C) → intoGroup(G, 0).
        let dropInsideGroup = resolveDropTarget(zones: zones, cursorY: 50)
        #expect(dropInsideGroup == .intoGroup(groupID: Self.groupG, index: 0))
    }
}
