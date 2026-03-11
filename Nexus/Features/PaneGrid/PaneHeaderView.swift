import ComposableArchitecture
import SwiftUI

/// Slim header bar at the top of each pane showing the working directory
/// and a close button.
struct PaneHeaderView: View {
    let pane: Pane
    let isFocused: Bool
    let onFocus: () -> Void
    let onSplitHorizontal: () -> Void
    let onSplitVertical: () -> Void
    let onClose: () -> Void
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)
                .animation(.easeInOut(duration: 0.3), value: pane.status)

            Text(displayTitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onSplitHorizontal) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Split right (⌘D)")

            Button(action: onSplitVertical) {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Split down (⌘⇧D)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Close pane (⌘W)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("paneGrid"))
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                    }
                    onDragChanged?(value.location)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnded?()
                }
        )
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if isFocused {
                    Color.accentColor.opacity(0.08)
                }
            }
        }
    }

    private var statusDotColor: Color {
        switch pane.status {
        case .running:
            return .green
        case .waitingForInput:
            return .blue
        case .idle:
            return isFocused ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.3)
        }
    }

    private var displayTitle: String {
        if let title = pane.title, !title.isEmpty {
            return title
        }
        let path = pane.workingDirectory
        if let home = ProcessInfo.processInfo.environment["HOME"],
           path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
