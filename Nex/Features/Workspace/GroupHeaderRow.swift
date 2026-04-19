import SwiftUI

/// Header for a workspace group in the sidebar. Tap toggles collapse.
/// Rename is initiated from the context menu (which sets `isRenaming`).
struct GroupHeaderRow: View {
    let name: String
    let color: WorkspaceColor?
    let isCollapsed: Bool
    let workspaceCount: Int
    let isRenaming: Bool
    let onToggleCollapse: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Folder icon carries the group colour. Filled when coloured
            // so the hue reads clearly; outlined + secondary when the
            // user hasn't set a colour. Collapse state reads from
            // whether the group's children render below, so no chevron
            // is needed.
            //
            // The icon sits in a 4pt-wide slot that matches the colour
            // pill on workspace rows, so a group header and a root
            // workspace share the same leading-column anchor. The
            // glyph is wider than 4pt; it overflows the slot and
            // centres on the 18pt-from-entry-edge column — visually
            // aligned with the pill.
            ZStack {
                Color.clear.frame(width: 4, height: 24)
                Image(systemName: color == nil ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(color?.color ?? Color.secondary)
            }

            if isRenaming {
                TextField("Group name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .focused($renameFieldFocused)
                    .onAppear {
                        renameText = name
                        renameFieldFocused = true
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                Text("\(workspaceCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.06))
                    )
            }
        }
        // Match a workspace row's laid-out height: a workspace row's
        // inner HStack is driven by the 13pt name + 10pt subtitle
        // VStack at ~29pt, plus 8pt vertical padding on each side
        // ≈ 45pt total. Driving the header to the same content height
        // here + the same 8pt vertical padding aligns the group's
        // count badge vertically with the workspace rows' ⌘N badges.
        .frame(minHeight: 29)
        .padding(.vertical, 8)
        // 16pt total horizontal padding matches the workspace row's
        // layered padding (8pt internal inside `WorkspaceRowView` + 8pt
        // external in `WorkspaceListView`'s `workspaceRow`). That puts
        // the 4pt folder slot at 16pt from the entry leading edge —
        // centred at 18pt, exactly under the workspace row's pill.
        .padding(.horizontal, 16)
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
    }
}
