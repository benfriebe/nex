import SwiftUI

/// Draws every edge as a bezier with an arrowhead, colour-coded by
/// outcome. Non-interactive — the canvas's own hit-testing (via
/// `PipelineCanvasGeometry.hitTest`) drives edge selection, not this
/// layer directly.
struct PipelineEdgeLayer: View {
    let edges: [PipelineEdge]
    let positions: [String: CGPoint]
    let selectedEdgeIndex: Int?
    @Environment(\.chromeTheme) private var chromeTheme

    var body: some View {
        Canvas { context, _ in
            for (index, edge) in edges.enumerated() {
                guard let fromPos = positions[edge.from], let toPos = positions[edge.to] else { continue }
                draw(edge: edge, from: fromPos, to: toPos, isSelected: selectedEdgeIndex == index, context: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func color(for outcome: PipelineNodeOutcome) -> Color {
        switch outcome {
        case .done: chromeTheme.statusRunning
        case .fail: .red
        case .partial: chromeTheme.statusWaiting
        }
    }

    private func draw(edge: PipelineEdge, from fromPos: CGPoint, to toPos: CGPoint, isSelected: Bool, context: inout GraphicsContext) {
        let from = PipelineCanvasGeometry.center(of: fromPos)
        let to = PipelineCanvasGeometry.center(of: toPos)
        let controlOffset = max(abs(to.x - from.x) / 2, 40)
        let c1 = CGPoint(x: from.x + controlOffset, y: from.y)
        let c2 = CGPoint(x: to.x - controlOffset, y: to.y)

        var path = Path()
        path.move(to: from)
        path.addCurve(to: to, control1: c1, control2: c2)

        let strokeColor = isSelected ? chromeTheme.selectionStroke : color(for: edge.on)
        let lineWidth: CGFloat = isSelected ? 3 : 1.5
        context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)

        // Arrowhead pointing along the curve's tangent at `to`.
        let angle = atan2(to.y - c2.y, to.x - c2.x)
        let arrowLength: CGFloat = 8
        let arrowAngle: CGFloat = .pi / 7
        var arrow = Path()
        arrow.move(to: to)
        arrow.addLine(to: CGPoint(
            x: to.x - arrowLength * cos(angle - arrowAngle),
            y: to.y - arrowLength * sin(angle - arrowAngle)
        ))
        arrow.move(to: to)
        arrow.addLine(to: CGPoint(
            x: to.x - arrowLength * cos(angle + arrowAngle),
            y: to.y - arrowLength * sin(angle + arrowAngle)
        ))
        context.stroke(arrow, with: .color(strokeColor), lineWidth: lineWidth)
    }
}
