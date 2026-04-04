import SwiftUI

struct StatusBarPopoverView: View {
    let items: [StatusBarItem]
    let onSelectPane: (UUID, UUID) -> Void

    private var groupedItems: [(workspaceName: String, workspaceColor: WorkspaceColor, panes: [StatusBarItem])] {
        let grouped = Dictionary(grouping: items) { $0.workspaceID }
        return grouped.values
            .compactMap { group -> (String, WorkspaceColor, [StatusBarItem])? in
                guard let first = group.first else { return nil }
                return (first.workspaceName, first.workspaceColor, group)
            }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                allClearView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groupedItems, id: \.workspaceName) { group in
                            workspaceSection(
                                name: group.workspaceName,
                                color: group.workspaceColor,
                                panes: group.panes
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 280)
    }

    private func workspaceSection(name: String, color: WorkspaceColor, panes: [StatusBarItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Workspace header
            HStack(spacing: 6) {
                Circle()
                    .fill(color.color)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            // Pane rows
            ForEach(panes) { item in
                paneRow(item)
            }
        }
    }

    private func paneRow(_ item: StatusBarItem) -> some View {
        Button {
            onSelectPane(item.paneID, item.workspaceID)
        } label: {
            HStack(spacing: 8) {
                Text(item.paneTitle)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                statusDot(for: item.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.0001))
        )
        .onHover { _ in
            // Handled by SwiftUI button highlight
        }
    }

    @ViewBuilder
    private func statusDot(for status: PaneStatus) -> some View {
        switch status {
        case .waitingForInput:
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(.blue.opacity(0.4))
                        .frame(width: 12, height: 12)
                        .pulse()
                )
        case .running:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        case .idle:
            EmptyView()
        }
    }

    private var allClearView: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("All clear")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// MARK: - Pulse Animation

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 1 : 0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

private extension View {
    func pulse() -> some View {
        modifier(PulseModifier())
    }
}
