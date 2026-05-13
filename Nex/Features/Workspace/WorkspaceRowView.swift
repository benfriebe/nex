import SwiftUI

/// Pulsing status dot used by workspace rows and group headers to signal
/// agent activity in the sidebar.
struct AgentStatusDot: View {
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
    var labels: [String] = []

    /// Maximum chips rendered inline before collapsing into a `+N` more
    /// indicator. Three keeps rows visually compact in the narrow
    /// sidebar; the inspector shows the full set.
    private static let maxInlineLabels = 3

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.color)
                .frame(width: 4, height: rowAccentHeight)

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

                if !labels.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(labels.prefix(Self.maxInlineLabels)), id: \.self) { label in
                            RowLabelChip(text: label)
                        }
                        if labels.count > Self.maxInlineLabels {
                            Text("+\(labels.count - Self.maxInlineLabels)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer()

            if waitingPaneCount > 0 {
                AgentStatusDot(color: .blue)
            } else if hasRunningPanes {
                AgentStatusDot(color: .green)
            }

            // Negative indices opt out of the badge entirely. Used by
            // the filtered sidebar where workspace indices into
            // `visibleWorkspaceOrder` are either wrong or meaningless.
            if index >= 0, index < 9 {
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

    /// The color bar grows when label chips are visible so it stays
    /// roughly aligned with the row's full content height.
    private var rowAccentHeight: CGFloat {
        labels.isEmpty ? 24 : 36
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
