import SwiftUI

/// Single row in the workspace sidebar list.
struct WorkspaceRowView: View {
    let name: String
    let color: WorkspaceColor
    let paneCount: Int
    let repoCount: Int
    let gitStatus: RepoGitStatus
    let isActive: Bool
    let index: Int
    var waitingPaneCount: Int = 0
    var hasRunningPanes: Bool = false
    var isSelected: Bool = false
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.color)
                .frame(width: 4, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                // Always semibold so a long name doesn't re-wrap when
                // `isActive` toggles (regular and semibold measure
                // differently per character). Active/inactive is still
                // distinguished by colour plus the row's background
                // highlight.
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? .primary : .secondary)

                HStack(spacing: 6) {
                    Text("\(paneCount) pane\(paneCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if repoCount > 0 {
                        HStack(spacing: 2) {
                            gitStatusDot
                            Text("\(repoCount)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            if waitingPaneCount > 0 {
                PulsingDot(color: .blue)
            } else if hasRunningPanes {
                PulsingDot(color: .green)
            }

            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.18))
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                }
                if isActive {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                    // Accent outline makes the active workspace more
                    // prominent than the bare white fill could on its
                    // own, especially against a busy sidebar.
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
        )
        // Nesting inset is applied AFTER the background so the fill +
        // outline stay within the row's content area. A nested row
        // gets its outline indented from the sidebar edge instead of
        // spanning the full width.
        .padding(.leading, leadingInset)
        .contentShape(Rectangle())
    }

    private struct PulsingDot: View {
        let color: Color
        @State private var isPulsing = false

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .onAppear { isPulsing = true }
        }
    }

    @ViewBuilder
    private var gitStatusDot: some View {
        let dotColor: Color = switch gitStatus {
        case .unknown: .secondary
        case .clean: .green
        case .dirty: .orange
        }
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(dotColor)
    }
}
