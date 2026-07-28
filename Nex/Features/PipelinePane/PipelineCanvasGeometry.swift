import CoreGraphics
import Foundation

/// Pure geometry for the pipeline canvas — document-space <-> view-space
/// transforms, node frames, and hit-testing. No view/reducer coupling so
/// this is unit-testable in isolation (the `WorkspaceDropTarget.dropZones`
/// discipline).
enum PipelineCanvasGeometry {
    static let nodeSize = CGSize(width: 160, height: 64)
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
    /// overlap, mirroring z-order), then edges, else `.none`. Port/chip
    /// hit-testing is deferred to the interactive drag-edge feature.
    static func hitTest(
        documentPoint point: CGPoint,
        nodes: [PipelineNode],
        positions: [String: CGPoint],
        edges: [PipelineEdge]
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
            if distance(from: point, toSegment: from, to) < edgeHitTolerance {
                return .edge(index)
            }
        }
        return .none
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
