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
}
