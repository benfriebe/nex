import Foundation

struct SplitDividerInfo: Identifiable {
    let id: String
    let direction: PaneLayout.SplitDirection
    let rect: CGRect
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

    /// Update the ratio of the split node identified by `splitPath`.
    /// The path uses the same encoding as `SplitDividerInfo.id`:
    /// `"d"` = root split, each `L`/`R` suffix navigates into the first/second child.
    func updatingSplitRatio(atPath splitPath: String, to newRatio: Double) -> PaneLayout {
        // Strip the leading "d" to get the navigation sequence
        let navigation = splitPath.dropFirst()
        return updatingSplitRatioByNavigation(navigation[...], newRatio: newRatio)
    }

    private func updatingSplitRatioByNavigation(_ nav: Substring, newRatio: Double) -> PaneLayout {
        let clamped = min(max(newRatio, 0.1), 0.9)
        switch self {
        case .leaf, .empty:
            return self
        case .split(let direction, let ratio, let first, let second):
            if nav.isEmpty {
                // This is the target split node
                return .split(direction, ratio: clamped, first: first, second: second)
            }
            let remaining = nav.dropFirst()
            if nav.first == "L" {
                return .split(direction, ratio: ratio,
                              first: first.updatingSplitRatioByNavigation(remaining, newRatio: newRatio),
                              second: second)
            } else {
                return .split(direction, ratio: ratio,
                              first: first,
                              second: second.updatingSplitRatioByNavigation(remaining, newRatio: newRatio))
            }
        }
    }
}

// MARK: - Predefined Layouts

enum PredefinedLayout: String, CaseIterable, Codable, Equatable {
    case evenHorizontal = "even-horizontal"
    case evenVertical = "even-vertical"
    case mainHorizontal = "main-horizontal"
    case mainVertical = "main-vertical"
    case tiled

    var displayName: String {
        switch self {
        case .evenHorizontal: "Even Horizontal"
        case .evenVertical: "Even Vertical"
        case .mainHorizontal: "Main Horizontal"
        case .mainVertical: "Main Vertical"
        case .tiled: "Tiled"
        }
    }

    /// Build a layout tree for this predefined layout using the given pane IDs.
    /// The first pane ID is treated as the "main" pane for main-* layouts.
    func buildLayout(for paneIDs: [UUID]) -> PaneLayout {
        guard let first = paneIDs.first else { return .empty }
        guard paneIDs.count > 1 else { return .leaf(first) }

        switch self {
        case .evenHorizontal:
            return Self.evenSplit(direction: .horizontal, paneIDs: paneIDs)
        case .evenVertical:
            return Self.evenSplit(direction: .vertical, paneIDs: paneIDs)
        case .mainHorizontal:
            let rest = Array(paneIDs.dropFirst())
            return .split(
                .vertical, ratio: 0.6,
                first: .leaf(first),
                second: Self.evenSplit(direction: .horizontal, paneIDs: rest)
            )
        case .mainVertical:
            let rest = Array(paneIDs.dropFirst())
            return .split(
                .horizontal, ratio: 0.6,
                first: .leaf(first),
                second: Self.evenSplit(direction: .vertical, paneIDs: rest)
            )
        case .tiled:
            return Self.tiledSplit(paneIDs: paneIDs, direction: .horizontal)
        }
    }

    /// Recursively split panes evenly in the given direction.
    /// For N panes, the first gets 1/N of the space, the rest split the remainder.
    static func evenSplit(direction: PaneLayout.SplitDirection, paneIDs: [UUID]) -> PaneLayout {
        guard let first = paneIDs.first else { return .empty }
        guard paneIDs.count > 1 else { return .leaf(first) }

        let ratio = 1.0 / Double(paneIDs.count)
        let rest = Array(paneIDs.dropFirst())
        return .split(
            direction, ratio: ratio,
            first: .leaf(first),
            second: evenSplit(direction: direction, paneIDs: rest)
        )
    }

    /// Recursively tile panes by splitting at the midpoint, alternating direction.
    private static func tiledSplit(
        paneIDs: [UUID],
        direction: PaneLayout.SplitDirection
    ) -> PaneLayout {
        guard let first = paneIDs.first else { return .empty }
        guard paneIDs.count > 1 else { return .leaf(first) }

        let mid = paneIDs.count / 2
        let firstHalf = Array(paneIDs.prefix(mid))
        let secondHalf = Array(paneIDs.suffix(from: mid))
        let nextDirection: PaneLayout.SplitDirection = direction == .horizontal ? .vertical : .horizontal

        return .split(
            direction, ratio: Double(mid) / Double(paneIDs.count),
            first: tiledSplit(paneIDs: firstHalf, direction: nextDirection),
            second: tiledSplit(paneIDs: secondHalf, direction: nextDirection)
        )
    }
}
