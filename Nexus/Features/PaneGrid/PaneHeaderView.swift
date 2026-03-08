import ComposableArchitecture
import SwiftUI

/// Slim header bar at the top of each pane showing the working directory
/// and a close button.
struct PaneHeaderView: View {
    let pane: Pane
    let isFocused: Bool
    let onFocus: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isFocused ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)

            Text(displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

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
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if isFocused {
                    Color.accentColor.opacity(0.08)
                }
            }
        }
    }

    private var displayPath: String {
        let path = pane.workingDirectory
        if let home = ProcessInfo.processInfo.environment["HOME"],
           path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
