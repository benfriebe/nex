import ComposableArchitecture
import CoreGraphics
import Foundation

/// Where a dragged workspace would land if the user released right now.
///
/// Every case resolves to a reducer action in `WorkspaceListView`:
/// - `.topLevel(index:)`          → `.moveWorkspace` (same-top-level source)
///                                 or `.moveWorkspaceToGroup(groupID: nil, index:)`
/// - `.intoGroup(groupID:index:)` → `.moveWorkspaceToGroup(groupID:, index:)`
/// - `.ontoGroupHeader(groupID:)` → `.moveWorkspaceToGroup(groupID:, index: nil)` (append)
///
/// Indices are POST-REMOVE (i.e. the position the workspace should have
/// AFTER it has been detached from its current parent). The underlying
/// reducer semantics match, so no extra adjustment is needed at the call
/// site.
enum DropTarget: Equatable {
    case topLevel(index: Int)
    case intoGroup(groupID: UUID, index: Int)
    case ontoGroupHeader(groupID: UUID)
}

/// A single hit-testable slice of the sidebar layout. `yTop`/`yBottom` are
/// coordinates in the drag's named coordinate space.
struct DropZone: Equatable {
    enum Kind: Equatable {
        /// A top-level workspace row (not inside a group).
        case topLevelWorkspace(id: UUID, postRemoveTopIndex: Int)
        /// A group header (collapsed or expanded).
        case groupHeader(groupID: UUID, postRemoveTopIndex: Int)
        /// A workspace row inside an expanded group.
        case groupChild(groupID: UUID, childID: UUID, postRemoveChildIndex: Int)
        /// The "No workspaces" placeholder shown inside an expanded empty group.
        case groupEmpty(groupID: UUID)
    }

    let kind: Kind
    let yTop: CGFloat
    let yBottom: CGFloat
}

/// Compute the ordered list of drop zones for a drag in progress.
///
/// Walks `topLevelOrder` (and each expanded group's `childOrder`) in the
/// same order the SwiftUI VStack lays them out. The dragged workspace is
/// omitted from the zone list but still advances `yTop` — the VStack
/// leaves the source's slot in the flow and offsets it visually, so
/// non-source rows keep their on-screen Y positions.
///
/// Post-remove indices skip the source, so indices can be passed straight
/// to `.moveWorkspace` / `.moveWorkspaceToGroup` (both of which remove
/// from source BEFORE inserting at the given index).
func dropZones(
    topLevelOrder: [SidebarID],
    groups: IdentifiedArrayOf<WorkspaceGroup>,
    workspaces: IdentifiedArrayOf<WorkspaceFeature.State>,
    rowHeights: [SidebarID: CGFloat],
    draggedID: UUID,
    springLoadedGroupID: UUID? = nil,
    startY: CGFloat = 0,
    emptyPlaceholderHeight: CGFloat = 28
) -> [DropZone] {
    var zones: [DropZone] = []
    var yTop = startY
    var topIdx = 0

    for entry in topLevelOrder {
        switch entry {
        case .workspace(let id):
            let h = rowHeights[.workspace(id)] ?? 0
            if id == draggedID {
                // Skip the source zone — but yTop still advances because
                // the row occupies layout space (visually offset during drag).
            } else {
                zones.append(DropZone(
                    kind: .topLevelWorkspace(id: id, postRemoveTopIndex: topIdx),
                    yTop: yTop,
                    yBottom: yTop + h
                ))
                topIdx += 1
            }
            yTop += h

        case .group(let gid):
            guard let group = groups[id: gid] else { continue }
            let headerH = rowHeights[.group(gid)] ?? 0
            zones.append(DropZone(
                kind: .groupHeader(groupID: gid, postRemoveTopIndex: topIdx),
                yTop: yTop,
                yBottom: yTop + headerH
            ))
            yTop += headerH
            topIdx += 1

            // Treat the group as expanded if its persistent state says so
            // OR if it is currently spring-loaded by the drag.
            let effectivelyExpanded = !group.isCollapsed || springLoadedGroupID == gid
            if effectivelyExpanded {
                let children = group.childOrder.filter { workspaces[id: $0] != nil }
                if children.isEmpty {
                    zones.append(DropZone(
                        kind: .groupEmpty(groupID: gid),
                        yTop: yTop,
                        yBottom: yTop + emptyPlaceholderHeight
                    ))
                    yTop += emptyPlaceholderHeight
                } else {
                    var childIdx = 0
                    for childID in children {
                        let h = rowHeights[.workspace(childID)] ?? 0
                        if childID == draggedID {
                            // Skip source child.
                        } else {
                            zones.append(DropZone(
                                kind: .groupChild(
                                    groupID: gid,
                                    childID: childID,
                                    postRemoveChildIndex: childIdx
                                ),
                                yTop: yTop,
                                yBottom: yTop + h
                            ))
                            childIdx += 1
                        }
                        yTop += h
                    }
                }
            }
        }
    }

    return zones
}

/// A full top-level entry's vertical extent. Used by group drags, where
/// the cursor can only target positions *between* top-level entries (no
/// nesting is allowed). Each span covers a workspace row or an entire
/// group block (header + children).
struct TopLevelSpan: Equatable {
    let postRemoveTopIndex: Int
    let yTop: CGFloat
    let yBottom: CGFloat
}

/// Compute top-level spans for a group drag in progress.
///
/// Each top-level entry produces one span covering its full vertical
/// extent (a workspace is just its row; a group is header + children if
/// expanded). The source group is skipped so post-remove indices match
/// the `.moveGroup` reducer's insert semantics.
///
/// The dragged group is rendered as collapsed for the duration of the
/// drag (plan's 4d behaviour), so callers should pass its height
/// accordingly via `rowHeights` OR rely on the walker treating the
/// source as header-only (we default to the latter since the caller
/// can't easily override a single group's measured height).
func topLevelDropZones(
    topLevelOrder: [SidebarID],
    groups: IdentifiedArrayOf<WorkspaceGroup>,
    workspaces: IdentifiedArrayOf<WorkspaceFeature.State>,
    rowHeights: [SidebarID: CGFloat],
    draggedGroupID: UUID,
    springLoadedGroupID: UUID? = nil,
    startY: CGFloat = 0,
    emptyPlaceholderHeight: CGFloat = 28
) -> [TopLevelSpan] {
    var spans: [TopLevelSpan] = []
    var yTop = startY
    var topIdx = 0

    for entry in topLevelOrder {
        switch entry {
        case .workspace(let id):
            let h = rowHeights[.workspace(id)] ?? 0
            spans.append(TopLevelSpan(
                postRemoveTopIndex: topIdx,
                yTop: yTop,
                yBottom: yTop + h
            ))
            topIdx += 1
            yTop += h

        case .group(let gid):
            guard let group = groups[id: gid] else { continue }
            let headerH = rowHeights[.group(gid)] ?? 0
            // The source group is visually collapsed during its own drag,
            // so its block height is just the header. All other groups
            // use their true extent (header + children when expanded).
            let isSource = gid == draggedGroupID
            let effectivelyExpanded = !group.isCollapsed || springLoadedGroupID == gid
            var blockH = headerH
            if effectivelyExpanded, !isSource {
                let children = group.childOrder.filter { workspaces[id: $0] != nil }
                if children.isEmpty {
                    blockH += emptyPlaceholderHeight
                } else {
                    for childID in children {
                        blockH += rowHeights[.workspace(childID)] ?? 0
                    }
                }
            }
            if isSource {
                // Skip source; yTop advances by source's visual height
                // (header only, since we visually collapse it on drag).
            } else {
                spans.append(TopLevelSpan(
                    postRemoveTopIndex: topIdx,
                    yTop: yTop,
                    yBottom: yTop + blockH
                ))
                topIdx += 1
            }
            yTop += blockH
        }
    }

    return spans
}

/// Map a cursor Y to a `.topLevel(index:)` DropTarget for a group drag.
/// Top-half of a span → drop before; bottom-half → drop after. Cursor
/// below every span → drop at end (so the user can drop AFTER the last
/// top-level entry, including when that entry is a group with no row
/// below it).
func resolveTopLevelDropTarget(spans: [TopLevelSpan], cursorY: CGFloat) -> DropTarget? {
    for span in spans {
        guard cursorY >= span.yTop, cursorY < span.yBottom else { continue }
        let midY = (span.yTop + span.yBottom) / 2
        let index = cursorY < midY ? span.postRemoveTopIndex : span.postRemoveTopIndex + 1
        return .topLevel(index: index)
    }
    if let last = spans.last, cursorY >= last.yBottom {
        return .topLevel(index: last.postRemoveTopIndex + 1)
    }
    return nil
}

/// Map a cursor Y (in the drag coordinate space) to a DropTarget.
///
/// Resolution rules (matching the Phase 4a design in
/// `plans/workspace-groups.md`):
/// - Top-level workspace: top half → drop before; bottom half → drop after.
/// - Group header: top half → drop before the group at the top level; bottom
///   half → drop into the group (append). A future revision with the
///   x-indent threshold will refine this.
/// - Group child (expanded group): top half → drop before; bottom half → drop after.
/// - Empty group placeholder: always → drop into the group at index 0.
/// - Cursor outside every zone → `nil` (no drop preview).
func resolveDropTarget(zones: [DropZone], cursorY: CGFloat) -> DropTarget? {
    for zone in zones {
        guard cursorY >= zone.yTop, cursorY < zone.yBottom else { continue }
        let midY = (zone.yTop + zone.yBottom) / 2
        let isTopHalf = cursorY < midY

        switch zone.kind {
        case .topLevelWorkspace(_, let postIdx):
            return .topLevel(index: isTopHalf ? postIdx : postIdx + 1)

        case .groupHeader(let gid, let postIdx):
            return isTopHalf
                ? .topLevel(index: postIdx)
                : .ontoGroupHeader(groupID: gid)

        case .groupChild(let gid, _, let childIdx):
            return .intoGroup(groupID: gid, index: isTopHalf ? childIdx : childIdx + 1)

        case .groupEmpty(let gid):
            return .intoGroup(groupID: gid, index: 0)
        }
    }

    // Cursor below every zone — cover the trailing spacer so users can
    // drop AFTER the final top-level entry even when it's a group with
    // no entry below it.
    if let last = zones.last, cursorY >= last.yBottom,
       let trailingIdx = trailingTopLevelIndex(zones: zones) {
        return .topLevel(index: trailingIdx)
    }
    return nil
}

/// Post-remove top-level index that corresponds to dropping AFTER the
/// final top-level entry in `zones`.
private func trailingTopLevelIndex(zones: [DropZone]) -> Int? {
    var lastTopIdx: Int?
    for zone in zones {
        switch zone.kind {
        case .topLevelWorkspace(_, let postIdx),
             .groupHeader(_, let postIdx):
            lastTopIdx = postIdx + 1
        case .groupChild, .groupEmpty:
            continue
        }
    }
    return lastTopIdx
}
