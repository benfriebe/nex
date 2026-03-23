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
