import SwiftUI

/// One node card on the pipeline canvas. Size is fixed
/// (`PipelineCanvasGeometry.nodeSize`) so geometry/hit-testing and
/// rendering agree on node bounds.
struct PipelineNodeView: View {
    let node: PipelineNode
    let isEntry: Bool
    let isSelected: Bool
    @Environment(\.chromeTheme) private var chromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if isEntry {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(chromeTheme.accent)
                }
                Text(node.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chromeTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(node.mode == .headless ? "headless" : "interactive")
                .font(.system(size: 10))
                .foregroundStyle(chromeTheme.textSecondary)
            Text(node.permissionMode.rawValue)
                .font(.system(size: 10))
                .foregroundStyle(chromeTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(
            width: PipelineCanvasGeometry.nodeSize.width,
            height: PipelineCanvasGeometry.nodeSize.height,
            alignment: .topLeading
        )
        .background(chromeTheme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? chromeTheme.selectionStroke : chromeTheme.divider,
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}
