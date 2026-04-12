import SwiftUI

struct CommandPaletteView: View {
    let query: String
    let items: [CommandPaletteItem]
    let selectedIndex: Int
    let onQueryChanged: (String) -> Void
    let onSelectIndex: (Int) -> Void
    let onSelectNext: () -> Void
    let onSelectPrevious: () -> Void
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var localQuery: String = ""
    @State private var scrollToSelection = false

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                TextField("Jump to workspace or pane...", text: $localQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFieldFocused)
                    .onChange(of: localQuery) { _, newValue in
                        onQueryChanged(newValue)
                    }
                    .onSubmit {
                        onConfirm()
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !items.isEmpty {
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                CommandPaletteRow(
                                    item: item,
                                    isSelected: index == selectedIndex
                                )
                                .id(item.id)
                                .onTapGesture {
                                    onSelectIndex(index)
                                    onConfirm()
                                }
                                .onHover { hovering in
                                    if hovering {
                                        onSelectIndex(index)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: selectedIndex) { _, newIndex in
                        if scrollToSelection, newIndex < items.count {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(items[newIndex].id, anchor: .center)
                            }
                        }
                        scrollToSelection = false
                    }
                }
            } else if !query.isEmpty {
                Divider()
                Text("No results")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                    .padding(.vertical, 16)
            }
        }
        .frame(width: 440)
        .background(.ultraThinMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onAppear {
            localQuery = query
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onKeyPress(.upArrow) {
            scrollToSelection = true
            onSelectPrevious()
            return .handled
        }
        .onKeyPress(.downArrow) {
            scrollToSelection = true
            onSelectNext()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.workspaceColor.color)
                .frame(width: 8, height: 8)

            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if item.paneID == nil {
                Text("workspace")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(4)
            } else {
                Text(item.workspaceName)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.workspaceColor.color.opacity(0.7))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}
