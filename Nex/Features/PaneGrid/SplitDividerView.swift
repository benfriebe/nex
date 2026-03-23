import SwiftUI

/// Drag handle between split panes. Handles drag gestures to update
/// the split ratio.
struct SplitDividerView: View {
    let direction: PaneLayout.SplitDirection
    let onDrag: (Double) -> Void

    @State private var isDragging = false

    private var isHorizontal: Bool {
        direction == .horizontal
    }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(isDragging ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2))
            .frame(
                width: isHorizontal ? 4 : nil,
                height: isHorizontal ? nil : 4
            )
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
