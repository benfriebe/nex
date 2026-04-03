import Foundation
@testable import Nex
import Testing

struct PaneLayoutTests {
    // MARK: - allPaneIDs

    @Test func leafReturnsOneID() {
        let id = UUID()
        let layout = PaneLayout.leaf(id)
        #expect(layout.allPaneIDs == [id])
    }

    @Test func emptyReturnsNoIDs() {
        #expect(PaneLayout.empty.allPaneIDs.isEmpty)
    }

    @Test func splitReturnsAllIDs() {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = PaneLayout.split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        #expect(layout.allPaneIDs == [a, b, c])
    }

    // MARK: - splitting

    @Test func splitLeafCreatesThreePanes() {
        let original = UUID()
        let layout = PaneLayout.leaf(original)
        let (newLayout, newID) = layout.splitting(paneID: original, direction: .horizontal)

        #expect(newLayout.allPaneIDs.count == 2)
        #expect(newLayout.allPaneIDs.contains(original))
        #expect(newLayout.allPaneIDs.contains(newID))
        if case .split(let dir, let ratio, .leaf(let first), .leaf(let second)) = newLayout {
            #expect(dir == .horizontal)
            #expect(ratio == 0.5)
            #expect(first == original)
            #expect(second == newID)
        } else {
            Issue.record("Expected split layout")
        }
    }

    @Test func splitNestedLeaf() {
        let a = UUID(), b = UUID()
        let layout = PaneLayout.split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let (newLayout, newID) = layout.splitting(paneID: b, direction: .vertical)

        #expect(newLayout.allPaneIDs.count == 3)
        #expect(newLayout.allPaneIDs == [a, b, newID])
    }

    // MARK: - removing

    @Test func removeLeafFromSplitPromotesSibling() {
        let a = UUID(), b = UUID()
        let layout = PaneLayout.split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let result = layout.removing(paneID: a)
        #expect(result == .leaf(b))
    }

    @Test func removeFromNestedSplit() {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = PaneLayout.split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        let result = layout.removing(paneID: b)
        #expect(result == .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(c)))
    }

    @Test func removeLastPaneReturnsEmpty() {
        let id = UUID()
        let result = PaneLayout.leaf(id).removing(paneID: id)
        #expect(result.isEmpty)
    }

    // MARK: - Focus navigation

    @Test func nextPaneCycles() {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = PaneLayout.split(
            .horizontal,
            ratio: 0.5,
            first: .leaf(a),
            second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        #expect(layout.nextPaneID(after: a) == b)
        #expect(layout.nextPaneID(after: b) == c)
        #expect(layout.nextPaneID(after: c) == a) // wraps
    }

    @Test func previousPaneCycles() {
        let a = UUID(), b = UUID()
        let layout = PaneLayout.split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        #expect(layout.previousPaneID(before: a) == b)
        #expect(layout.previousPaneID(before: b) == a)
    }

    @Test func singlePaneReturnsNilForNavigation() {
        let id = UUID()
        let layout = PaneLayout.leaf(id)
        #expect(layout.nextPaneID(after: id) == nil)
        #expect(layout.previousPaneID(before: id) == nil)
    }

    // MARK: - Split ratio updates

    @Test func updateRatioAtRoot() {
        let a = UUID(), b = UUID()
        let layout = PaneLayout.split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let updated = layout.updatingSplitRatio(atPath: "d", to: 0.7)
        #expect(updated == .split(.horizontal, ratio: 0.7, first: .leaf(a), second: .leaf(b)))
    }

    @Test func updateRatioNestedLeft() {
        let a = UUID(), b = UUID(), c = UUID()
        // (A|B) | C — inner split is in the first child
        let layout = PaneLayout.split(
            .horizontal, ratio: 0.5,
            first: .split(.vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)),
            second: .leaf(c)
        )
        // "dL" targets the inner split (first child of root)
        let updated = layout.updatingSplitRatio(atPath: "dL", to: 0.3)
        if case .split(_, let rootRatio, let first, _) = updated {
            #expect(rootRatio == 0.5) // root ratio unchanged
            if case .split(_, let innerRatio, _, _) = first {
                #expect(innerRatio == 0.3) // inner ratio updated
            } else {
                Issue.record("Expected nested split")
            }
        } else {
            Issue.record("Expected split layout")
        }
    }

    @Test func updateRatioNestedRight() {
        let a = UUID(), b = UUID(), c = UUID()
        // A | (B|C) — inner split is in the second child
        let layout = PaneLayout.split(
            .horizontal, ratio: 0.5,
            first: .leaf(a),
            second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        // "dR" targets the inner split (second child of root)
        let updated = layout.updatingSplitRatio(atPath: "dR", to: 0.8)
        if case .split(_, let rootRatio, _, let second) = updated {
            #expect(rootRatio == 0.5)
            if case .split(_, let innerRatio, _, _) = second {
                #expect(innerRatio == 0.8)
            } else {
                Issue.record("Expected nested split")
            }
        } else {
            Issue.record("Expected split layout")
        }
    }

    @Test func updateRatioClampsToRange() {
        let a = UUID(), b = UUID()
        let layout = PaneLayout.split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let tooLow = layout.updatingSplitRatio(atPath: "d", to: 0.01)
        let tooHigh = layout.updatingSplitRatio(atPath: "d", to: 0.99)
        if case .split(_, let lowRatio, _, _) = tooLow {
            #expect(lowRatio == 0.1)
        }
        if case .split(_, let highRatio, _, _) = tooHigh {
            #expect(highRatio == 0.9)
        }
    }

    @Test func updateRatioAmbiguousFirstPaneHandledCorrectly() {
        let a = UUID(), b = UUID(), c = UUID()
        // split(split(A|B) | C) — both root and inner share pane A as leftmost
        // The old firstChildPaneID approach would be ambiguous here.
        // With path-based targeting, "d" = root, "dL" = inner — no ambiguity.
        let layout = PaneLayout.split(
            .horizontal, ratio: 0.5,
            first: .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)),
            second: .leaf(c)
        )

        // Update root ratio only
        let updatedRoot = layout.updatingSplitRatio(atPath: "d", to: 0.7)
        if case .split(_, let rootRatio, let first, _) = updatedRoot {
            #expect(rootRatio == 0.7)
            if case .split(_, let innerRatio, _, _) = first {
                #expect(innerRatio == 0.5) // inner unchanged
            }
        }

        // Update inner ratio only
        let updatedInner = layout.updatingSplitRatio(atPath: "dL", to: 0.3)
        if case .split(_, let rootRatio, let first, _) = updatedInner {
            #expect(rootRatio == 0.5) // root unchanged
            if case .split(_, let innerRatio, _, _) = first {
                #expect(innerRatio == 0.3)
            }
        }
    }

    // MARK: - Codable round-trip

    @Test func codableRoundTrip() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = PaneLayout.split(
            .horizontal,
            ratio: 0.6,
            first: .leaf(a),
            second: .split(.vertical, ratio: 0.4, first: .leaf(b), second: .leaf(c))
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(PaneLayout.self, from: data)
        #expect(decoded == layout)
    }
}

// MARK: - PredefinedLayout

struct PredefinedLayoutTests {
    // MARK: - Single pane

    @Test func singlePaneReturnsLeafForAll() {
        let id = UUID()
        for layout in PredefinedLayout.allCases {
            let result = layout.buildLayout(for: [id])
            #expect(result == .leaf(id), "Expected .leaf for \(layout.rawValue) with 1 pane")
        }
    }

    @Test func emptyPaneIDsReturnsEmpty() {
        for layout in PredefinedLayout.allCases {
            let result = layout.buildLayout(for: [])
            #expect(result == .empty, "Expected .empty for \(layout.rawValue) with 0 panes")
        }
    }

    // MARK: - Even Horizontal

    @Test func evenHorizontalTwoPanes() {
        let a = UUID(), b = UUID()
        let result = PredefinedLayout.evenHorizontal.buildLayout(for: [a, b])
        #expect(result == .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
    }

    @Test func evenHorizontalThreePanes() {
        let a = UUID(), b = UUID(), c = UUID()
        let result = PredefinedLayout.evenHorizontal.buildLayout(for: [a, b, c])
        let expected = PaneLayout.split(
            .horizontal, ratio: 1.0 / 3.0,
            first: .leaf(a),
            second: .split(.horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        #expect(result == expected)
    }

    @Test func evenHorizontalFourPanes() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let result = PredefinedLayout.evenHorizontal.buildLayout(for: [a, b, c, d])
        let expected = PaneLayout.split(
            .horizontal, ratio: 0.25,
            first: .leaf(a),
            second: .split(
                .horizontal, ratio: 1.0 / 3.0,
                first: .leaf(b),
                second: .split(.horizontal, ratio: 0.5, first: .leaf(c), second: .leaf(d))
            )
        )
        #expect(result == expected)
    }

    // MARK: - Even Vertical

    @Test func evenVerticalTwoPanes() {
        let a = UUID(), b = UUID()
        let result = PredefinedLayout.evenVertical.buildLayout(for: [a, b])
        #expect(result == .split(.vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
    }

    // MARK: - Main Horizontal

    @Test func mainHorizontalTwoPanes() {
        let a = UUID(), b = UUID()
        let result = PredefinedLayout.mainHorizontal.buildLayout(for: [a, b])
        #expect(result == .split(.vertical, ratio: 0.6, first: .leaf(a), second: .leaf(b)))
    }

    @Test func mainHorizontalThreePanes() {
        let a = UUID(), b = UUID(), c = UUID()
        let result = PredefinedLayout.mainHorizontal.buildLayout(for: [a, b, c])
        let expected = PaneLayout.split(
            .vertical, ratio: 0.6,
            first: .leaf(a),
            second: .split(.horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        #expect(result == expected)
    }

    // MARK: - Main Vertical

    @Test func mainVerticalTwoPanes() {
        let a = UUID(), b = UUID()
        let result = PredefinedLayout.mainVertical.buildLayout(for: [a, b])
        #expect(result == .split(.horizontal, ratio: 0.6, first: .leaf(a), second: .leaf(b)))
    }

    @Test func mainVerticalThreePanes() {
        let a = UUID(), b = UUID(), c = UUID()
        let result = PredefinedLayout.mainVertical.buildLayout(for: [a, b, c])
        let expected = PaneLayout.split(
            .horizontal, ratio: 0.6,
            first: .leaf(a),
            second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        #expect(result == expected)
    }

    // MARK: - Tiled

    @Test func tiledTwoPanes() {
        let a = UUID(), b = UUID()
        let result = PredefinedLayout.tiled.buildLayout(for: [a, b])
        #expect(result == .split(.horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
    }

    @Test func tiledThreePanes() {
        let a = UUID(), b = UUID(), c = UUID()
        let result = PredefinedLayout.tiled.buildLayout(for: [a, b, c])
        // mid = 1, so first half = [a], second half = [b, c]
        // second half splits vertically: [b] | [c]
        let expected = PaneLayout.split(
            .horizontal, ratio: 1.0 / 3.0,
            first: .leaf(a),
            second: .split(.vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        #expect(result == expected)
    }

    @Test func tiledFourPanes() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let result = PredefinedLayout.tiled.buildLayout(for: [a, b, c, d])
        // mid = 2, so [a,b] | [c,d]
        // first half splits vertically: a / b
        // second half splits vertically: c / d
        let expected = PaneLayout.split(
            .horizontal, ratio: 0.5,
            first: .split(.vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)),
            second: .split(.vertical, ratio: 0.5, first: .leaf(c), second: .leaf(d))
        )
        #expect(result == expected)
    }

    // MARK: - Pane ID preservation

    @Test func allPaneIDsPreserved() {
        let ids = (0 ..< 5).map { _ in UUID() }
        for layout in PredefinedLayout.allCases {
            let result = layout.buildLayout(for: ids)
            let resultIDs = Set(result.allPaneIDs)
            #expect(resultIDs == Set(ids), "Pane IDs not preserved for \(layout.rawValue)")
        }
    }
}
