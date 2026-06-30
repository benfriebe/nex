import SwiftUI

/// Pulsing agent-activity dot overlaid on a workspace avatar or group icon
/// corner. The `borderColor` ring separates it from the glyph underneath.
struct PulsingStatusDot: View {
    let color: Color
    let borderColor: Color
    var size: CGFloat = 9
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(borderColor, lineWidth: 1.5))
            .opacity(isPulsing ? 0.35 : 1.0)
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
    let isActive: Bool
    let index: Int
    var icon: GroupIcon?
    var waitingPaneCount: Int = 0
    var hasRunningPanes: Bool = false
    var isSelected: Bool = false
    var leadingInset: CGFloat = 0
    var labels: [String] = []
    /// Resolved preset colours per label string. Built once at the list
    /// level from the configured presets; a missing key renders neutral.
    var labelStyles: [String: ResolvedLabelStyle] = [:]

    @Environment(\.chromeTheme) private var theme
    @Environment(\.sidebarColorIntensity) private var colorIntensity
    @Environment(\.sidebarFillStroke) private var fillStroke

    /// Maximum chips rendered inline before collapsing into a `+N` more
    /// indicator. Three keeps rows visually compact in the narrow
    /// sidebar; the inspector shows the full set.
    private static let maxInlineLabels = 3

    var body: some View {
        HStack(spacing: 9) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                // Always semibold so a long name doesn't re-wrap when
                // `isActive` toggles (regular and semibold measure
                // differently per character). Active/inactive is still
                // distinguished by colour plus the row's background
                // highlight.
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)

                if !labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(labels.prefix(Self.maxInlineLabels)), id: \.self) { label in
                            RowLabelChip(text: label, style: labelStyles[label])
                        }
                        if labels.count > Self.maxInlineLabels {
                            Text("+\(labels.count - Self.maxInlineLabels)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            // Negative indices opt out of the badge entirely. Used by
            // the filtered sidebar where workspace indices into
            // `visibleWorkspaceOrder` are either wrong or meaningless.
            if index >= 0, index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(rowBackground)
        // Outer gap (outside the selection ring) matching the group bands'
        // 2pt, so the spacing between a row and an adjacent group/row is the
        // same everywhere — incl. the gap between a selected row's ring and
        // the group header above/below it.
        .padding(.vertical, 2)
        // Nesting inset is applied AFTER the background so the fill +
        // outline stay within the row's content area. A nested row
        // gets its outline indented from the sidebar edge instead of
        // spanning the full width.
        .padding(.leading, leadingInset)
        .contentShape(Rectangle())
    }

    /// Rounded-square colour avatar carrying the workspace's initial, with
    /// the agent-activity dot overlaid on its top-right corner (green =
    /// running, blue = waiting) — matching the group header.
    private var avatar: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.color.opacity(min(1, fillStroke.avatarFill * colorIntensity)))
            .frame(width: 22, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(color.color.opacity(min(1, fillStroke.avatarStroke * colorIntensity)), lineWidth: 1)
            )
            .overlay(avatarContent)
            .overlay(alignment: .topTrailing) {
                if waitingPaneCount > 0 {
                    statusDot(theme.statusWaiting)
                } else if hasRunningPanes {
                    statusDot(theme.statusRunning)
                }
            }
    }

    private func statusDot(_ color: Color) -> some View {
        PulsingStatusDot(color: color, borderColor: theme.sidebarBackground)
            .offset(x: 3, y: -3)
    }

    /// Avatar contents: a custom emoji or SF Symbol when set, otherwise the
    /// first letter of the workspace name.
    @ViewBuilder
    private var avatarContent: some View {
        switch icon {
        case .emoji(let grapheme):
            Text(grapheme).font(.system(size: 12))
        case .systemName(let symbolName):
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color.color)
        case .none:
            Text(avatarGlyph)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color.color)
        }
    }

    /// First grapheme of the name, upper-cased. Falls back to "?" for an
    /// empty/whitespace name. Non-Latin scripts (e.g. kanji) render as-is.
    private var avatarGlyph: String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    private var rowBackground: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 7).fill(theme.selectionFill)
                RoundedRectangle(cornerRadius: 7).stroke(theme.selectionStroke.opacity(0.7), lineWidth: 1)
            }
            if isActive {
                RoundedRectangle(cornerRadius: 7).fill(theme.selectionFill.opacity(0.7))
                // Accent outline makes the active workspace more prominent
                // than the bare fill could on its own, especially against a
                // busy sidebar.
                RoundedRectangle(cornerRadius: 7).stroke(theme.selectionStroke, lineWidth: 1.5)
            }
        }
    }
}
