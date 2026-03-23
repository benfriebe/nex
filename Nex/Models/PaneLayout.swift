import Foundation

struct SplitDividerInfo: Identifiable {
    let id: String
    let direction: PaneLayout.SplitDirection
    let rect: CGRect
    let firstChildPaneID: UUID?
    let available: CGFloat
    let firstSize: CGFloat
}

indirect enum PaneLayout: Equatable, Codable {
    static let dividerThickness: CGFloat = 4
    case leaf(UUID)
    case split(SplitDirection, ratio: Double, first: PaneLayout, second: PaneLayout)
    case empty

    enum SplitDirection: String, Codable {
        case horizontal // side by side (⌘D)
        case vertical // stacked (⌘⇧D)
    }

    // MARK: - Queries

    var allPaneIDs: [UUID] {
        switch self {
        case .leaf(let id):
            [id]
        case .split(_, _, let first, let second):
            first.allPaneIDs + second.allPaneIDs
        case .empty:
            []
        }
    }

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    func contains(paneID: UUID) -> Bool {
        allPaneIDs.contains(paneID)
    }

    // MARK: - Mutations

    func replacing(paneID: UUID, with replacement: PaneLayout) -> PaneLayout {
        switch self {
        case .leaf(let id):
            id == paneID ? replacement : self
        case .split(let direction, let ratio, let first, let second):
            .split(
                direction,
                ratio: ratio,
                first: first.replacing(paneID: paneID, with: replacement),
                second: second.replacing(paneID: paneID, with: replacement)
            )
        case .empty:
            self
        }
    }

    func removing(paneID: UUID) -> PaneLayout {
        switch self {
        case .leaf(let id):
            return id == paneID ? .empty : self
        case .split(let direction, let ratio, let first, let second):
            let newFirst = first.removing(paneID: paneID)
            let newSecond = second.removing(paneID: paneID)
            if newFirst.isEmpty { return newSecond }
            if newSecond.isEmpty { return newFirst }
            return .split(direction, ratio: ratio, first: newFirst, second: newSecond)
        case .empty:
            return self
        }
    }

    /// Split an existing leaf pane into two panes.
    /// Returns the new layout and the ID of the newly created pane.
    func splitting(
        paneID: UUID,
        direction: SplitDirection,
        newPaneID: UUID = UUID()
    ) -> (layout: PaneLayout, newPaneID: UUID) {
        let splitNode = PaneLayout.split(
            direction,
            ratio: 0.5,
            first: .leaf(paneID),
            second: .leaf(newPaneID)
        )
        return (replacing(paneID: paneID, with: splitNode), newPaneID)
    }

    // MARK: - Drop Zone

    enum DropZone: Equatable {
        case top, bottom, left, right

        var splitDirection: SplitDirection {
            switch self {
            case .left, .right: .horizontal
            case .top, .bottom: .vertical
            }
        }

        /// Whether the dragged pane goes first in the new split.
        var isFirst: Bool {
            switch self {
            case .left, .top: true
            case .right, .bottom: false
            }
        }

        /// Determine drop zone from cursor position within a rect (closest edge).
        static func calculate(at point: CGPoint, in rect: CGRect) -> DropZone {
            let dx = point.x - rect.midX
            let dy = point.y - rect.midY
            let hw = rect.width / 2
            let hh = rect.height / 2

            // Normalize distances to [-1, 1] range
            let nx = hw > 0 ? dx / hw : 0
            let ny = hh > 0 ? dy / hh : 0

            if abs(nx) > abs(ny) {
                return nx > 0 ? .right : .left
            } else {
                return ny > 0 ? .bottom : .top
            }
        }
    }

    // MARK: - Move Pane

    /// Move a pane to be adjacent to another pane in the given drop zone.
    func movingPane(_ paneID: UUID, toAdjacentOf targetID: UUID, zone: DropZone) -> PaneLayout {
        guard paneID != targetID else { return self }

        // Remove dragged pane — tree collapses automatically
        let withoutPane = removing(paneID: paneID)

        // Build the new split node
        let direction = zone.splitDirection
        let paneLeaf = PaneLayout.leaf(paneID)
        let targetLeaf = PaneLayout.leaf(targetID)
        let splitNode: PaneLayout = zone.isFirst
            ? .split(direction, ratio: 0.5, first: paneLeaf, second: targetLeaf)
            : .split(direction, ratio: 0.5, first: targetLeaf, second: paneLeaf)

        // Replace target leaf with the new split
        return withoutPane.replacing(paneID: targetID, with: splitNode)
    }

    // MARK: - Focus Navigation

    func nextPaneID(after currentID: UUID) -> UUID? {
        let ids = allPaneIDs
        guard let index = ids.firstIndex(of: currentID), ids.count > 1 else { return nil }
        return ids[(index + 1) % ids.count]
    }

    func previousPaneID(before currentID: UUID) -> UUID? {
        let ids = allPaneIDs
        guard let index = ids.firstIndex(of: currentID), ids.count > 1 else { return nil }
        return ids[(index - 1 + ids.count) % ids.count]
    }

    // MARK: - Split Ratio Updates

    // MARK: - Frame Computation

    /// Recursively compute each leaf pane's frame rect within the given bounds.
    func paneFrames(in bounds: CGRect) -> [UUID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: bounds]
        case .split(let direction, let ratio, let first, let second):
            let (firstBounds, secondBounds) = splitBounds(
                direction: direction, ratio: ratio, in: bounds
            )
            var frames = first.paneFrames(in: firstBounds)
            for (id, rect) in second.paneFrames(in: secondBounds) {
                frames[id] = rect
            }
            return frames
        case .empty:
            return [:]
        }
    }

    /// Recursively compute divider positions for drag handles.
    func splitDividers(in bounds: CGRect, prefix: String = "d") -> [SplitDividerInfo] {
        switch self {
        case .leaf, .empty:
            return []
        case .split(let direction, let ratio, let first, let second):
            let totalSize = direction == .horizontal ? bounds.width : bounds.height
            let available = totalSize - Self.dividerThickness
            let firstSize = available * ratio

            let (firstBounds, secondBounds) = splitBounds(
                direction: direction, ratio: ratio, in: bounds
            )

            let dividerRect = if direction == .horizontal {
                CGRect(
                    x: bounds.minX + firstSize, y: bounds.minY,
                    width: Self.dividerThickness, height: bounds.height
                )
            } else {
                CGRect(
                    x: bounds.minX, y: bounds.minY + firstSize,
                    width: bounds.width, height: Self.dividerThickness
                )
            }

            let info = SplitDividerInfo(
                id: prefix,
                direction: direction,
                rect: dividerRect,
                firstChildPaneID: first.allPaneIDs.first,
                available: available,
                firstSize: firstSize
            )

            return [info]
                + first.splitDividers(in: firstBounds, prefix: prefix + "L")
                + second.splitDividers(in: secondBounds, prefix: prefix + "R")
        }
    }

    /// Compute the two child bounds for a split at the given ratio.
    private func splitBounds(
        direction: SplitDirection, ratio: Double, in bounds: CGRect
    ) -> (first: CGRect, second: CGRect) {
        let totalSize = direction == .horizontal ? bounds.width : bounds.height
        let available = totalSize - Self.dividerThickness
        let firstSize = available * ratio

        if direction == .horizontal {
            let firstBounds = CGRect(
                x: bounds.minX, y: bounds.minY,
                width: firstSize, height: bounds.height
            )
            let secondBounds = CGRect(
                x: bounds.minX + firstSize + Self.dividerThickness, y: bounds.minY,
                width: available - firstSize, height: bounds.height
            )
            return (firstBounds, secondBounds)
        } else {
            let firstBounds = CGRect(
                x: bounds.minX, y: bounds.minY,
                width: bounds.width, height: firstSize
            )
            let secondBounds = CGRect(
                x: bounds.minX, y: bounds.minY + firstSize + Self.dividerThickness,
                width: bounds.width, height: available - firstSize
            )
            return (firstBounds, secondBounds)
        }
    }

    // MARK: - Split Ratio Updates

    /// Update the ratio of the split node whose first child contains `firstChildPaneID`.
    func updatingSplitRatio(firstChildPaneID: UUID, to newRatio: Double) -> PaneLayout {
        let clamped = min(max(newRatio, 0.1), 0.9)
        switch self {
        case .leaf, .empty:
            return self
        case .split(let direction, let ratio, let first, let second):
            if first.contains(paneID: firstChildPaneID), !second.contains(paneID: firstChildPaneID) {
                // This split's first child contains the target — update this node's ratio
                // But only if the pane is a direct leaf or we're at the right level
                if case .leaf = first {
                    return .split(direction, ratio: clamped, first: first, second: second)
                }
                // Recurse into the first child
                let updatedFirst = first.updatingSplitRatio(firstChildPaneID: firstChildPaneID, to: newRatio)
                if updatedFirst != first {
                    return .split(direction, ratio: ratio, first: updatedFirst, second: second)
                }
                // The pane wasn't found deeper — this must be the right split
                return .split(direction, ratio: clamped, first: first, second: second)
            }
            // Recurse into second child
            return .split(
                direction,
                ratio: ratio,
                first: first,
                second: second.updatingSplitRatio(firstChildPaneID: firstChildPaneID, to: newRatio)
            )
        }
    }
}
