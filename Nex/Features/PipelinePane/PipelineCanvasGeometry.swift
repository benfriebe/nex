import CoreGraphics
import Foundation

/// Pure geometry for the pipeline canvas — document-space <-> view-space
/// transforms, node frames, and hit-testing. No view/reducer coupling so
/// this is unit-testable in isolation (the `WorkspaceDropTarget.dropZones`
/// discipline).
enum PipelineCanvasGeometry {
    // Tall enough for name + mode + permission-mode + full status text
    // (e.g. "awaitingApproval") without vertical clipping (issue #282
    // round 3 — status text was cut off in the shorter card).
    static let nodeSize = CGSize(width: 168, height: 92)
    static let gridSnap: CGFloat = 8
    /// How close (in document points) a click must land to a bezier's
    /// sampled polyline to count as an edge hit.
    static let edgeHitTolerance: CGFloat = 8
    static let zoomRange: ClosedRange<CGFloat> = 0.25 ... 2.0

    static func nodeFrame(at position: CGPoint) -> CGRect {
        CGRect(origin: position, size: nodeSize)
    }

    static func center(of position: CGPoint) -> CGPoint {
        CGPoint(x: position.x + nodeSize.width / 2, y: position.y + nodeSize.height / 2)
    }

    static func snapped(_ point: CGPoint, to grid: CGFloat = gridSnap) -> CGPoint {
        CGPoint(x: (point.x / grid).rounded() * grid, y: (point.y / grid).rounded() * grid)
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// View-space point -> document-space point, given the current
    /// zoom/pan transform (pan is applied in view space, before scale).
    static func documentPoint(fromView viewPoint: CGPoint, zoom: CGFloat, pan: CGPoint) -> CGPoint {
        guard zoom != 0 else { return viewPoint }
        return CGPoint(x: (viewPoint.x - pan.x) / zoom, y: (viewPoint.y - pan.y) / zoom)
    }

    static func viewPoint(fromDocument documentPoint: CGPoint, zoom: CGFloat, pan: CGPoint) -> CGPoint {
        CGPoint(x: documentPoint.x * zoom + pan.x, y: documentPoint.y * zoom + pan.y)
    }

    enum HitTarget: Equatable {
        case node(String)
        case edge(Int)
        case none
    }

    /// Hit-test priority: node body first (top-most declared node wins on
    /// overlap, mirroring z-order), then edges (following their actual
    /// bezier curve, including any saved drag-to-bend offset — issue
    /// #282 round 3 — not just the straight chord between centers), else
    /// `.none`. Port/chip hit-testing is deferred to the interactive
    /// drag-edge feature; the midpoint HANDLE (for bending a curve) is a
    /// separate SwiftUI view with its own drag gesture, not part of this
    /// hit-test.
    static func hitTest(
        documentPoint point: CGPoint,
        nodes: [PipelineNode],
        positions: [String: CGPoint],
        edges: [PipelineEdge],
        edgeUI: [String: PipelineEdgeUI] = [:]
    ) -> HitTarget {
        for node in nodes.reversed() {
            guard let pos = positions[node.id] else { continue }
            if nodeFrame(at: pos).contains(point) {
                return .node(node.id)
            }
        }
        for (index, edge) in edges.enumerated() {
            guard let fromPos = positions[edge.from], let toPos = positions[edge.to] else { continue }
            let from = center(of: fromPos)
            let to = center(of: toPos)
            let offset = edgeUI[edge.identityKey]?.offset ?? .zero
            if distanceToBezier(point: point, from: from, to: to, offset: offset) < edgeHitTolerance {
                return .edge(index)
            }
        }
        return .none
    }

    // MARK: - Edge curve geometry (drag-to-bend handles, issue #282 round 3)

    /// The two cubic-bezier control points for an edge between two node
    /// CENTERS. `offset` (a saved `PipelineEdgeUI.offset`, document
    /// units) is applied symmetrically to both — dragging the midpoint
    /// handle just adjusts this one 2D value. Zero offset reproduces the
    /// original deterministic curve (horizontal control arms scaled by
    /// the endpoints' separation).
    static func edgeControlPoints(from: CGPoint, to: CGPoint, offset: CGPoint = .zero) -> (c1: CGPoint, c2: CGPoint) {
        let baseOffset = max(abs(to.x - from.x) / 2, 40)
        let c1 = CGPoint(x: from.x + baseOffset + offset.x, y: from.y + offset.y)
        let c2 = CGPoint(x: to.x - baseOffset + offset.x, y: to.y + offset.y)
        return (c1, c2)
    }

    static func cubicBezierPoint(from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * mt * from.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * to.x,
            y: mt * mt * mt * from.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * to.y
        )
    }

    /// The draggable midpoint handle's document-space position for an
    /// edge between two node centers, given its saved curve offset —
    /// the point at `t = 0.5` along the actual cubic bezier (not just
    /// the midpoint of the two endpoints).
    static func edgeHandlePosition(from: CGPoint, to: CGPoint, offset: CGPoint = .zero) -> CGPoint {
        let (c1, c2) = edgeControlPoints(from: from, to: to, offset: offset)
        return cubicBezierPoint(from: from, c1: c1, c2: c2, to: to, t: 0.5)
    }

    /// d(handle position)/d(offset) at `t = 0.5`, for a symmetric offset
    /// applied to both control points: `3·(1-t)²t + 3·(1-t)t²` at
    /// `t = 0.5` is `0.75`. Converts a 1:1 screen-space drag delta on the
    /// handle into the equivalent delta on the stored offset, so the
    /// handle tracks the cursor exactly instead of lagging behind it.
    static let edgeHandleOffsetGain: CGFloat = 0.75

    static func updatedEdgeOffset(currentOffset: CGPoint, handleDragDelta: CGPoint) -> CGPoint {
        CGPoint(
            x: currentOffset.x + handleDragDelta.x / edgeHandleOffsetGain,
            y: currentOffset.y + handleDragDelta.y / edgeHandleOffsetGain
        )
    }

    private static func distanceToBezier(
        point: CGPoint, from: CGPoint, to: CGPoint, offset: CGPoint, samples: Int = 16
    ) -> CGFloat {
        let (c1, c2) = edgeControlPoints(from: from, to: to, offset: offset)
        var minDistance = CGFloat.greatestFiniteMagnitude
        var previous = from
        for i in 1 ... samples {
            let t = CGFloat(i) / CGFloat(samples)
            let sample = cubicBezierPoint(from: from, c1: c1, c2: c2, to: to, t: t)
            minDistance = min(minDistance, distance(from: point, toSegment: previous, sample))
            previous = sample
        }
        return minDistance
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    /// Node ids whose frame intersects `rect` (document space) — backs
    /// rubber-band multi-select.
    static func nodesIntersecting(
        rect: CGRect,
        nodes: [PipelineNode],
        positions: [String: CGPoint]
    ) -> Set<String> {
        var result: Set<String> = []
        for node in nodes {
            guard let pos = positions[node.id] else { continue }
            if nodeFrame(at: pos).intersects(rect) {
                result.insert(node.id)
            }
        }
        return result
    }

    /// Bounding box over every positioned node, for the "Fit" zoom
    /// command. Returns nil when there are no positioned nodes.
    static func boundingBox(positions: [String: CGPoint]) -> CGRect? {
        guard !positions.isEmpty else { return nil }
        var box: CGRect?
        for position in positions.values {
            let frame = nodeFrame(at: position)
            box = box?.union(frame) ?? frame
        }
        return box
    }
}
