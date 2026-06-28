import AppKit
import ComposableArchitecture
import SwiftUI

/// Custom in-content window title bar shown under the hidden native
/// titlebar (`.windowStyle(.hiddenTitleBar)`). Centres the active
/// workspace identity (status dot · name · pane count · branch) and
/// hosts the right-hand chrome controls. Traffic lights float over its
/// leading edge; window dragging is preserved via
/// `isMovableByWindowBackground` set on the window.
///
/// A distinct child view with its own `WithPerceptionTracking` so it
/// re-renders in Release builds when the active workspace / pane state
/// changes (the outer `WithPerceptionTracking` is a no-op there).
struct WindowTitleBar: View {
    let store: StoreOf<AppReducer>
    @Environment(\.chromeTheme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        WithPerceptionTracking {
            let workspace = store.activeWorkspace
            ZStack {
                // Match the bottom status bar's background (sidebar/footer
                // tone). `WindowDragRegion` is a real layer in front of the
                // colour but behind the title content, so empty parts of the
                // bar drag the window (via `performDrag`) — scoped to the bar
                // so it doesn't make the sidebar a drag handle the way
                // `isMovableByWindowBackground` did.
                theme.footerBackground
                WindowDragRegion()
                identityCluster(workspace)
                trailingControls
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                theme.divider.frame(height: 1)
            }
        }
    }

    private func identityCluster(_ workspace: WorkspaceFeature.State?) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor(workspace))
                .frame(width: 7, height: 7)

            Text(workspace?.name ?? "Nex")
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)

            if let workspace {
                separator
                Text("\(workspace.panes.count) pane\(workspace.panes.count == 1 ? "" : "s")")
                    .foregroundStyle(theme.textTertiary)
            }

            if let branch = activeBranch(workspace) {
                separator
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                }
                .foregroundStyle(theme.textTertiary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
        // Asymmetric insets: clear the traffic lights on the left (80) and
        // reserve room for the trailing controls on the right (86) so a long
        // name + branch truncates instead of overlapping the menu / sidebar
        // buttons on a narrow window.
        .padding(.leading, 80)
        .padding(.trailing, 86)
    }

    private var trailingControls: some View {
        HStack(spacing: 14) {
            Spacer()

            Menu {
                Button("Settings…") { openSettings() }
                Button(store.isInspectorVisible ? "Hide Inspector" : "Show Inspector") {
                    store.send(.toggleInspector)
                }
                Divider()
                Button("Restart Socket Server") { store.send(.restartSocketServer) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // borderlessButton tints its label with the accent; force it to the
            // neutral text colour so the ••• matches the other title-bar controls.
            .tint(theme.textSecondary)
            .foregroundStyle(theme.textSecondary)

            Button { store.send(.toggleSidebar) } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .help("Toggle sidebar")
        }
        .font(.system(size: 13))
        .padding(.trailing, 14)
    }

    private var separator: some View {
        Text("·").foregroundStyle(theme.textTertiary)
    }

    private func dotColor(_ workspace: WorkspaceFeature.State?) -> Color {
        guard let workspace else { return theme.textTertiary }
        if workspace.panes.contains(where: { $0.status == .waitingForInput }) {
            return theme.statusWaiting
        }
        if workspace.panes.contains(where: { $0.status == .running }) {
            return theme.statusRunning
        }
        return workspace.color.color
    }

    /// Branch of the focused pane, falling back to the first pane that has
    /// one (so the title bar still shows a branch when focus is on a
    /// non-shell pane).
    private func activeBranch(_ workspace: WorkspaceFeature.State?) -> String? {
        guard let workspace else { return nil }
        if let focusedID = workspace.focusedPaneID,
           let branch = workspace.panes[id: focusedID]?.gitBranch {
            return branch
        }
        return workspace.panes.compactMap(\.gitBranch).first
    }
}

/// A transparent, hit-testable backing view that lets the window be dragged
/// from the non-interactive parts of the custom title bar. Scoped to the
/// title bar (not the whole window) so it doesn't hijack sidebar drag-to-
/// reorder the way `NSWindow.isMovableByWindowBackground` did. Interactive
/// SwiftUI controls layered in front (the buttons) keep their own handling.
private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        DragView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class DragView: NSView {
        /// `mouseDownCanMoveWindow` is unreliable for a SwiftUI-embedded view,
        /// so initiate the drag explicitly. `performDrag` also handles the
        /// double-click-to-zoom/minimise titlebar conventions.
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
