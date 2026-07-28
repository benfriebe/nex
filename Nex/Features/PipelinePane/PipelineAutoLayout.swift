import CoreGraphics
import Foundation

/// Deterministic layered auto-layout for pipeline nodes lacking a saved
/// `ui.nodes` position. Column = BFS depth from the entry node; a
/// back-edge (auditor -> implementer) never pushes an already-placed
/// node further right, so bounce-back loops don't distort the layout.
enum PipelineAutoLayout {
    static let columnSpacing: CGFloat = 240
    static let rowSpacing: CGFloat = 140
    static let origin = CGPoint(x: 80, y: 80)

    /// Computes a position for every node in `nodes`. Nodes reachable
    /// from `entry` are placed by BFS depth (column) and declared order
    /// within that column (row); unreachable nodes are appended one
    /// column past the deepest reachable one, in declared order.
    static func layout(nodes: [PipelineNode], edges: [PipelineEdge], entry: String) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        guard nodes.contains(where: { $0.id == entry }) else {
            return naiveLayout(nodes: nodes)
        }

        var depth: [String: Int] = [entry: 0]
        var frontier = [entry]
        while !frontier.isEmpty {
            var next: [String] = []
            for id in frontier {
                for edge in edges where edge.from == id {
                    if depth[edge.to] == nil {
                        depth[edge.to] = (depth[id] ?? 0) + 1
                        next.append(edge.to)
                    }
                }
            }
            frontier = next
        }

        let maxDepth = depth.values.max() ?? 0
        for node in nodes where depth[node.id] == nil {
            depth[node.id] = maxDepth + 1
        }

        let declaredOrder = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        var columns: [Int: [String]] = [:]
        for node in nodes {
            columns[depth[node.id] ?? 0, default: []].append(node.id)
        }

        var positions: [String: CGPoint] = [:]
        for (column, ids) in columns {
            let ordered = ids.sorted { (declaredOrder[$0] ?? 0) < (declaredOrder[$1] ?? 0) }
            for (row, id) in ordered.enumerated() {
                positions[id] = CGPoint(
                    x: origin.x + CGFloat(column) * columnSpacing,
                    y: origin.y + CGFloat(row) * rowSpacing
                )
            }
        }
        return positions
    }

    /// Merges a definition's saved `ui.nodes` positions with auto-layout
    /// for any node missing one (a freshly hand-written YAML file, or a
    /// node added since the last save). Stale positions for since-deleted
    /// nodes are dropped.
    static func reconciledPositions(for definition: PipelineDefinition) -> [String: CGPoint] {
        var result = layout(nodes: definition.nodes, edges: definition.edges, entry: definition.entry)
        let nodeIDs = Set(definition.nodes.map(\.id))
        for (id, point) in definition.ui.nodes where nodeIDs.contains(id) {
            result[id] = point
        }
        return result
    }

    private static func naiveLayout(nodes: [PipelineNode]) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        for (index, node) in nodes.enumerated() {
            positions[node.id] = CGPoint(x: origin.x, y: origin.y + CGFloat(index) * rowSpacing)
        }
        return positions
    }
}
