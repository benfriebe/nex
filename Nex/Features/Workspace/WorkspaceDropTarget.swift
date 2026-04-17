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

            if !group.isCollapsed {
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
    return nil
}
