import CoreGraphics
@testable import Nex
import Testing

@MainActor
struct PipelineCanvasGeometryTests {
    private func node(_ id: String) -> PipelineNode {
        PipelineNode(id: id, prompt: "do \(id)")
    }

    @Test func snappedRoundsToGrid() {
        let point = CGPoint(x: 13, y: 27)
        let snapped = PipelineCanvasGeometry.snapped(point)
        #expect(snapped == CGPoint(x: 16, y: 24))
    }

    @Test func clampedZoomRespectsRange() {
        #expect(PipelineCanvasGeometry.clampedZoom(0.01) == PipelineCanvasGeometry.zoomRange.lowerBound)
        #expect(PipelineCanvasGeometry.clampedZoom(10) == PipelineCanvasGeometry.zoomRange.upperBound)
        #expect(PipelineCanvasGeometry.clampedZoom(1) == 1)
    }

    @Test func viewAndDocumentPointsRoundTrip() {
        let doc = CGPoint(x: 100, y: 50)
        let zoom: CGFloat = 1.5
        let pan = CGPoint(x: 20, y: -10)
        let view = PipelineCanvasGeometry.viewPoint(fromDocument: doc, zoom: zoom, pan: pan)
        let back = PipelineCanvasGeometry.documentPoint(fromView: view, zoom: zoom, pan: pan)
        #expect(abs(back.x - doc.x) < 0.0001)
        #expect(abs(back.y - doc.y) < 0.0001)
    }

    @Test func hitTestFindsNodeContainingPoint() {
        let nodes = [node("a"), node("b")]
        let positions = ["a": CGPoint(x: 0, y: 0), "b": CGPoint(x: 300, y: 0)]
        let hit = PipelineCanvasGeometry.hitTest(
            documentPoint: CGPoint(x: 10, y: 10), nodes: nodes, positions: positions, edges: []
        )
        #expect(hit == .node("a"))
    }

    @Test func hitTestPrefersTopmostNodeOnOverlap() {
        let nodes = [node("bottom"), node("top")]
        let positions = ["bottom": CGPoint(x: 0, y: 0), "top": CGPoint(x: 0, y: 0)]
        let hit = PipelineCanvasGeometry.hitTest(
            documentPoint: CGPoint(x: 10, y: 10), nodes: nodes, positions: positions, edges: []
        )
        #expect(hit == .node("top"))
    }

    @Test func hitTestFindsEdgeWhenNoNodeContainsPoint() {
        let nodes = [node("a"), node("b")]
        let positions = ["a": CGPoint(x: 0, y: 0), "b": CGPoint(x: 400, y: 0)]
        let edges = [PipelineEdge(from: "a", on: .done, to: "b")]
        // Midpoint between the two node centers, well clear of either frame.
        let midY = PipelineCanvasGeometry.center(of: positions["a"]!).y
        let hit = PipelineCanvasGeometry.hitTest(
            documentPoint: CGPoint(x: 240, y: midY), nodes: nodes, positions: positions, edges: edges
        )
        #expect(hit == .edge(0))
    }

    @Test func hitTestReturnsNoneWhenNothingIsClose() {
        let nodes = [node("a")]
        let positions = ["a": CGPoint(x: 0, y: 0)]
        let hit = PipelineCanvasGeometry.hitTest(
            documentPoint: CGPoint(x: 5000, y: 5000), nodes: nodes, positions: positions, edges: []
        )
        #expect(hit == .none)
    }

    @Test func distanceToSegmentHandlesDegenerateSegment() {
        let a = CGPoint(x: 5, y: 5)
        let distance = PipelineCanvasGeometry.distance(from: CGPoint(x: 5, y: 8), toSegment: a, a)
        #expect(distance == 3)
    }

    @Test func nodesIntersectingFindsOverlappingRect() {
        let nodes = [node("a"), node("b")]
        let positions = ["a": CGPoint(x: 0, y: 0), "b": CGPoint(x: 500, y: 500)]
        let selected = PipelineCanvasGeometry.nodesIntersecting(
            rect: CGRect(x: -10, y: -10, width: 50, height: 50), nodes: nodes, positions: positions
        )
        #expect(selected == ["a"])
    }

    @Test func boundingBoxCoversAllPositionedNodes() {
        let positions = ["a": CGPoint(x: 0, y: 0), "b": CGPoint(x: 300, y: 300)]
        let box = PipelineCanvasGeometry.boundingBox(positions: positions)
        #expect(box != nil)
        #expect(box!.contains(CGPoint(x: 0, y: 0)))
        // CGRect.contains is exclusive of maxX/maxY (half-open interval),
        // so assert on the extent directly rather than the corner point.
        #expect(box!.maxX == 300 + PipelineCanvasGeometry.nodeSize.width)
        #expect(box!.maxY == 300 + PipelineCanvasGeometry.nodeSize.height)
    }

    @Test func boundingBoxIsNilForEmptyPositions() {
        #expect(PipelineCanvasGeometry.boundingBox(positions: [:]) == nil)
    }

    // MARK: - Edge curve geometry (drag-to-bend handles, issue #282 round 3)

    @Test func edgeHandlePositionAtZeroOffsetSitsOnTheDefaultCurve() {
        let from = CGPoint(x: 0, y: 100)
        let to = CGPoint(x: 400, y: 100)
        let (c1, c2) = PipelineCanvasGeometry.edgeControlPoints(from: from, to: to)
        let expected = PipelineCanvasGeometry.cubicBezierPoint(from: from, c1: c1, c2: c2, to: to, t: 0.5)
        #expect(PipelineCanvasGeometry.edgeHandlePosition(from: from, to: to) == expected)
        // Symmetric endpoints at the same y with zero offset -> the
        // curve's midpoint sits exactly between them.
        #expect(abs(expected.x - 200) < 0.0001)
        #expect(abs(expected.y - 100) < 0.0001)
    }

    @Test func edgeHandlePositionMovesWithSavedOffset() {
        let from = CGPoint(x: 0, y: 100)
        let to = CGPoint(x: 400, y: 100)
        let bent = PipelineCanvasGeometry.edgeHandlePosition(from: from, to: to, offset: CGPoint(x: 0, y: -60))
        // A negative-y offset bends the curve upward — the handle moves
        // up by exactly the offset scaled by `edgeHandleOffsetGain`.
        #expect(abs(bent.y - (100 - 60 * PipelineCanvasGeometry.edgeHandleOffsetGain)) < 0.0001)
    }

    @Test func updatedEdgeOffsetMakesTheHandleTrackTheDragExactly() {
        let from = CGPoint(x: 0, y: 100)
        let to = CGPoint(x: 400, y: 100)
        let startOffset = CGPoint.zero
        let dragDelta = CGPoint(x: 12, y: -18)
        let newOffset = PipelineCanvasGeometry.updatedEdgeOffset(currentOffset: startOffset, handleDragDelta: dragDelta)

        let before = PipelineCanvasGeometry.edgeHandlePosition(from: from, to: to, offset: startOffset)
        let after = PipelineCanvasGeometry.edgeHandlePosition(from: from, to: to, offset: newOffset)
        // The handle itself should have moved by exactly `dragDelta`,
        // not by some scaled/lagging amount.
        #expect(abs((after.x - before.x) - dragDelta.x) < 0.0001)
        #expect(abs((after.y - before.y) - dragDelta.y) < 0.0001)
    }

    @Test func hitTestFollowsABentEdgeNotTheStraightChord() {
        let nodes = [node("a"), node("b")]
        let positions = ["a": CGPoint(x: 0, y: 0), "b": CGPoint(x: 400, y: 0)]
        let edge = PipelineEdge(from: "a", on: .done, to: "b")
        let edges = [edge]
        let midY = PipelineCanvasGeometry.center(of: positions["a"]!).y

        // A point on the (now-empty) straight chord no longer hits once
        // the edge is bent 80pt away from it.
        let bentEdgeUI = [edge.identityKey: PipelineEdgeUI(offset: CGPoint(x: 0, y: -80))]
        let missOnChord = PipelineCanvasGeometry.hitTest(
            documentPoint: CGPoint(x: 200, y: midY), nodes: nodes, positions: positions, edges: edges, edgeUI: bentEdgeUI
        )
        #expect(missOnChord == .none)

        // But a point at the bent curve's actual handle position does hit.
        let handlePoint = PipelineCanvasGeometry.edgeHandlePosition(
            from: PipelineCanvasGeometry.center(of: positions["a"]!),
            to: PipelineCanvasGeometry.center(of: positions["b"]!),
            offset: CGPoint(x: 0, y: -80)
        )
        let hitOnBend = PipelineCanvasGeometry.hitTest(
            documentPoint: handlePoint, nodes: nodes, positions: positions, edges: edges, edgeUI: bentEdgeUI
        )
        #expect(hitOnBend == .edge(0))
    }
}
