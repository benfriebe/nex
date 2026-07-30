import SwiftUI

/// The zoom/pan canvas: edges (a `Canvas` layer) + node cards (plain
/// SwiftUI views), value-typed all the way down. Drag-to-reposition and
/// double-click-to-add-node are wired here; port-drag edge creation and
/// rubber-band multi-select are deferred (see `PipelineInspectorView`'s
/// "Add edge" affordance for the v1 substitute).
struct PipelineCanvasView: View {
    let document: PipelineDefinition
    let positions: [String: CGPoint]
    let selection: PipelineCanvasSelection
    let zoom: CGFloat
    let pan: CGPoint
    let onSelect: (PipelineCanvasSelection) -> Void
    let onMoveNode: (String, CGPoint) -> Void
    let onAddNode: (CGPoint) -> Void
    /// Monitor mode (issue #282 phase 7): structural edits (add node,
    /// select edges for editing) are guarded off — position drags stay
    /// live. Double-click on a node jumps to its pane instead of
    /// selecting it for the inspector.
    var isMonitorMode: Bool = false
    var nodeStatuses: [String: PipelineNodeRunDisplay] = [:]
    var onJumpToNode: (String) -> Void = { _ in }

    @Environment(\.chromeTheme) private var chromeTheme
    @State private var dragOrigin: [String: CGPoint] = [:]

    private var selectedEdgeIndex: Int? {
        if case let .edge(index) = selection {
            return index
        }
        return nil
    }

    private var canvasSize: CGSize {
        guard let box = PipelineCanvasGeometry.boundingBox(positions: positions) else {
            return CGSize(width: 1200, height: 800)
        }
        return CGSize(width: max(box.maxX + 400, 1200), height: max(box.maxY + 400, 800))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            chromeTheme.surfaceBackground.opacity(0.4)

            // `.local` here is the view's own untransformed layout space,
            // which already lines up with document points since the view
            // is laid out at `canvasSize` (document units) before the
            // parent's `.scaleEffect`/`.offset` are applied — no further
            // zoom/pan correction needed for a location from this space.
            let doubleTap = SpatialTapGesture(count: 2, coordinateSpace: .local)
                .onEnded { value in
                    guard !isMonitorMode else { return }
                    onAddNode(PipelineCanvasGeometry.snapped(value.location))
                }
            let singleTap = SpatialTapGesture(count: 1, coordinateSpace: .local)
                .onEnded { value in
                    let hit = PipelineCanvasGeometry.hitTest(
                        documentPoint: value.location,
                        nodes: document.nodes,
                        positions: positions,
                        edges: document.edges
                    )
                    switch hit {
                    case let .node(id): onSelect(.node(id))
                    case let .edge(index): onSelect(.edge(index))
                    case .none: onSelect(.none)
                    }
                }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: canvasSize.width, height: canvasSize.height)
                .gesture(doubleTap.exclusively(before: singleTap))

            PipelineEdgeLayer(edges: document.edges, positions: positions, selectedEdgeIndex: selectedEdgeIndex)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .allowsHitTesting(false)

            ForEach(document.nodes) { node in
                if let position = positions[node.id] {
                    PipelineNodeView(
                        node: node,
                        isEntry: node.id == document.entry,
                        isSelected: selection == .node(node.id),
                        isMonitorMode: isMonitorMode,
                        run: nodeStatuses[node.id]
                    )
                    .equatable()
                    .position(
                        x: position.x + PipelineCanvasGeometry.nodeSize.width / 2,
                        y: position.y + PipelineCanvasGeometry.nodeSize.height / 2
                    )
                    .onTapGesture(count: 2) { onJumpToNode(node.id) }
                    .onTapGesture { onSelect(.node(node.id)) }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let origin = dragOrigin[node.id] ?? position
                                if dragOrigin[node.id] == nil {
                                    dragOrigin[node.id] = position
                                }
                                let moved = CGPoint(
                                    x: origin.x + value.translation.width / zoom,
                                    y: origin.y + value.translation.height / zoom
                                )
                                onMoveNode(node.id, moved)
                            }
                            .onEnded { value in
                                let origin = dragOrigin[node.id] ?? position
                                let moved = CGPoint(
                                    x: origin.x + value.translation.width / zoom,
                                    y: origin.y + value.translation.height / zoom
                                )
                                onMoveNode(node.id, PipelineCanvasGeometry.snapped(moved))
                                dragOrigin[node.id] = nil
                            }
                    )
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(x: pan.x, y: pan.y)
    }
}
