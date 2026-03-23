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

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.color)
                .frame(width: 4, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
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
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isActive
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                : nil
        )
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
