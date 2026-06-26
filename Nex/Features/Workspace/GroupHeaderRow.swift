import SwiftUI

/// Header for a workspace group in the sidebar. Tap toggles collapse.
/// Rename is initiated from the context menu (which sets `isRenaming`).
struct GroupHeaderRow: View {
    let name: String
    let color: WorkspaceColor?
    let icon: GroupIcon?
    let isCollapsed: Bool
    let workspaceCount: Int
    let isRenaming: Bool
    var hasWaitingPanes: Bool = false
    var hasRunningPanes: Bool = false
    let onToggleCollapse: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool
    @Environment(\.chromeTheme) private var theme
    @Environment(\.sidebarColorIntensity) private var colorIntensity
    @Environment(\.sidebarFillStroke) private var fillStroke

    /// Group-colour wash behind the header. Rendered as a rounded, inset
    /// band (a pill) per the mockup. Falls back to a neutral tint when the
    /// group has no colour.
    private var headerTint: Color {
        let fill = fillStroke.resolvedGroupFill(preset: theme.groupBandOpacity)
        return (color?.color ?? theme.textTertiary).opacity(min(1, fill * colorIntensity))
    }

    /// Optional band border (opt-in; default off).
    private var headerStroke: Color {
        (color?.color ?? theme.textTertiary).opacity(min(1, fillStroke.groupStroke * colorIntensity))
    }

    var body: some View {
        HStack(spacing: 9) {
            groupIcon

            if isRenaming {
                TextField("Group name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .focused($renameFieldFocused)
                    .onAppear {
                        renameText = name
                        // Defer the focus assignment so the TextField's
                        // NSTextField is attached to the window first.
                        // Without this, SwiftUI's focus binding silently
                        // no-ops and the keyView chain hands focus to the
                        // sidebar's filter input instead (issue #132).
                        DispatchQueue.main.async { renameFieldFocused = true }
                    }
                    .onExitCommand { onCancelRename() }
                    .onSubmit {
                        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            onCancelRename()
                        } else {
                            onCommitRename(trimmed)
                        }
                    }
                    .onChange(of: renameFieldFocused) { _, focused in
                        // Focus loss commits silently — matches macOS Finder folders.
                        guard !focused else { return }
                        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty || trimmed == name {
                            onCancelRename()
                        } else {
                            onCommitRename(trimmed)
                        }
                    }
            } else {
                Text(name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        // 6pt vertical padding matches WorkspaceRowView so a group band is
        // the same height as a workspace row (both have a 22pt icon/avatar).
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Rounded, inset band (pill) — matches the mockup. The 8pt outer
        // inset keeps it clear of the sidebar edges; the list's trailing-8
        // scroller padding then balances the right margin.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(headerTint)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(headerStroke, lineWidth: 1)
                )
        )
        .padding(.leading, 8)
        // Vertical breathing room between adjacent group bands.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isRenaming {
                // Click on this header's chrome (not the TextField) exits
                // rename cleanly via the focus-loss commit path.
                NSApp.keyWindow?.makeFirstResponder(nil)
            } else {
                onToggleCollapse()
            }
        }
    }

    /// Group glyph with the agent-activity dot overlaid on its corner
    /// (green = running, blue = waiting), matching the mockup.
    private var groupIcon: some View {
        iconGlyph
            .frame(width: 22, height: 22)
            .overlay(alignment: .topTrailing) {
                if hasWaitingPanes {
                    statusDot(theme.statusWaiting)
                } else if hasRunningPanes {
                    statusDot(theme.statusRunning)
                }
            }
    }

    private func statusDot(_ color: Color) -> some View {
        PulsingStatusDot(color: color, borderColor: theme.sidebarBackground)
            .offset(x: 3, y: -2)
    }

    @ViewBuilder
    private var iconGlyph: some View {
        switch icon {
        case .none:
            // Default: colour-tinted folder (filled when a colour is
            // set, outlined otherwise).
            Image(systemName: color == nil ? "folder" : "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(color?.color ?? theme.textSecondary)
        case .systemName(let name):
            // Custom SF Symbol. Inherit the group's colour tint so it
            // reads the same as the default folder would. Folder is
            // special-cased to upgrade to `folder.fill` when a colour
            // is set, so picking "Folder" from the Symbol menu and
            // using "Reset to Folder" render the same glyph on a
            // coloured group.
            let effective = (name == "folder" && color != nil) ? "folder.fill" : name
            Image(systemName: effective)
                .font(.system(size: 14))
                .foregroundStyle(color?.color ?? theme.textSecondary)
        case .emoji(let grapheme):
            // Emoji glyphs render with their native palette — SwiftUI
            // can't recolour them cleanly, so we skip the tint.
            Text(grapheme)
                .font(.system(size: 13))
        }
    }
}

/// Placeholder shown inside an expanded but empty group. Drag math
/// uses the runtime-measured height (`effectiveEmptyRowHeight`), so the
/// placeholder no longer has to mimic a workspace row's laid-out height.
struct GroupEmptyRow: View {
    var body: some View {
        HStack(spacing: 8) {
            // Match the 16pt leading spacer + 4pt colour-bar slot used
            // by nested workspace rows so "No workspaces" aligns with
            // the column of workspace names above.
            Spacer().frame(width: 16)
            Color.clear.frame(width: 4, height: 16)
            Text("No workspaces")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        // Right-click anywhere on the row should open the empty-group
        // context menu — without an explicit hit shape only the Text's
        // glyph area would respond.
        .contentShape(Rectangle())
    }
}
