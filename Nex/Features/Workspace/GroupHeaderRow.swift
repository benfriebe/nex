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
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture { onToggleCollapse() }

            if let color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.color)
                    .frame(width: 3, height: 14)
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
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
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

/// Placeholder shown inside an expanded but empty group. Phase 4 will turn the
/// container into a drop target.
struct GroupEmptyRow: View {
    var body: some View {
        HStack(spacing: 8) {
            // `WorkspaceRowView` at depth 1 inserts a 16pt leading
            // spacer before its color bar — match it here so the
            // "No workspaces" text aligns with nested workspaces' names.
            Spacer().frame(width: 16)
            // Match `WorkspaceRowView`'s color bar slot (4×24).
            Color.clear.frame(width: 4, height: 24)
            // Mirror `WorkspaceRowView`'s 2-line VStack (13pt + 10pt)
            // so the placeholder's laid-out height equals a workspace
            // row. Font sizes drive the VStack's intrinsic height and
            // therefore the whole row's height — the color bar alone
            // isn't the tallest child. Without this, live-applying a
            // drag into this empty group jumps the layout by the
            // difference between the placeholder and a real row.
            VStack(alignment: .leading, spacing: 1) {
                Text("No workspaces")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Text(" ")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        // 16pt on each side = the 8pt outer padding the workspace row
        // gets from `WorkspaceListView` plus the 8pt inner padding
        // `WorkspaceRowView` applies to itself.
        .padding(.horizontal, 16)
    }
}
