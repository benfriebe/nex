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
    var isZoomed: Bool = false
    var isEditing: Bool = false
    var onToggleEdit: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 4) {
            if pane.type == .markdown {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                    .animation(.easeInOut(duration: 0.3), value: pane.status)
            }

            if let label = pane.label, !label.isEmpty, pane.type != .markdown {
                HStack(spacing: 2) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 8))
                    Text(label)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }

            Text(displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if isZoomed {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8))
                    Text("ZOOM")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            if let branch = pane.gitBranch {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            }

            if pane.type == .markdown, let onToggleEdit {
                Button(action: onToggleEdit) {
                    Image(systemName: isEditing ? "eye" : "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help(isEditing ? "Preview (⌘E)" : "Edit (⌘E)")
            }

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
                    Color.accentColor.opacity(0.15)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isFocused {
                Color.accentColor.opacity(0.6)
                    .frame(height: 2)
            }
        }
    }

    private var statusDotColor: Color {
        switch pane.status {
        case .running:
            .green
        case .waitingForInput:
            .blue
        case .idle:
            isFocused ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.3)
        }
    }

    private var displayPath: String {
        if pane.type == .markdown, let filePath = pane.filePath {
            return (filePath as NSString).lastPathComponent
        }
        let path = pane.title ?? pane.workingDirectory
        if let home = ProcessInfo.processInfo.environment["HOME"],
           path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
