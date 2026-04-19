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

            // Folder icon carries the group colour. Filled when coloured
            // so the hue reads clearly; outlined + secondary when the
            // user hasn't set a colour, matching the muted appearance of
            // the rest of the header chrome.
            Image(systemName: color == nil ? "folder" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(color?.color ?? Color.secondary)
                .frame(width: 14, alignment: .center)

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
