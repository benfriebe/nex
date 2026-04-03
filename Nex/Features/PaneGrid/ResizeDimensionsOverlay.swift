import SwiftUI

/// Floating overlay that shows terminal grid dimensions (e.g. "80x24")
/// during pane or window resize operations. Centered on the pane.
struct ResizeDimensionsOverlay: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .allowsHitTesting(false)
    }
}

/// Wrapper view that queries the surface manager for cell size and computes
/// grid dimensions from the pane frame. Falls back to pixel dimensions for
/// non-terminal panes (markdown).
struct ResizeDimensionsView: View {
    let paneID: UUID
    let paneFrame: CGRect
    @Environment(\.surfaceManager) private var surfaceManager

    var body: some View {
        if let cell = surfaceManager.cellSize(for: paneID) {
            let cols = Int(paneFrame.width / cell.width)
            let rows = Int(paneFrame.height / cell.height)
            ResizeDimensionsOverlay(text: "\(cols) x \(rows)")
        } else {
            ResizeDimensionsOverlay(text: "\(Int(paneFrame.width)) x \(Int(paneFrame.height))")
        }
    }
}
