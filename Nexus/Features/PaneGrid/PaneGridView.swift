import ComposableArchitecture
import SwiftUI

/// Renders a PaneLayout as a flat ZStack with stable ForEach identity.
/// Pane frames are computed mathematically from the layout tree, so
/// SurfaceContainerView instances are never destroyed during layout changes —
/// only repositioned/resized.
struct PaneGridView: View {
    let layout: PaneLayout
    let panes: IdentifiedArrayOf<Pane>
    let focusedPaneID: UUID?
    let onCreatePane: () -> Void
    let onSplitPane: (UUID, PaneLayout.SplitDirection) -> Void
    let onClosePane: (UUID) -> Void
    let onFocusPane: (UUID) -> Void
    let onUpdateRatio: (UUID, Double) -> Void

    var body: some View {
        if layout.isEmpty {
            emptyView
        } else {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let frames = layout.paneFrames(in: bounds)
                let dividers = layout.splitDividers(in: bounds)

                ZStack(alignment: .topLeading) {
                    // Stable pane views — ForEach preserves identity across layout changes
                    ForEach(panes) { pane in
                        if let frame = frames[pane.id] {
                            paneView(pane: pane, frame: frame)
                        }
                    }
                    // Divider drag handles
                    ForEach(dividers) { info in
                        dividerView(info: info)
                    }
                }
            }
            // Prevent implicit animations from interfering with
            // NSView re-parenting during layout transitions.
            .transaction { $0.animation = nil }
        }
    }

    private func paneView(pane: Pane, frame: CGRect) -> some View {
        VStack(spacing: 0) {
            PaneHeaderView(
                pane: pane,
                isFocused: pane.id == focusedPaneID,
                onFocus: { onFocusPane(pane.id) },
                onSplitHorizontal: { onSplitPane(pane.id, .horizontal) },
                onSplitVertical: { onSplitPane(pane.id, .vertical) },
                onClose: { onClosePane(pane.id) }
            )

            SurfaceContainerView(
                paneID: pane.id,
                workingDirectory: pane.workingDirectory,
                isFocused: pane.id == focusedPaneID
            )
        }
        .border(
            pane.id == focusedPaneID ? Color.accentColor.opacity(0.4) : Color.clear,
            width: 1
        )
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.origin.x, y: frame.origin.y)
    }

    private func dividerView(info: SplitDividerInfo) -> some View {
        SplitDividerView(direction: info.direction) { delta in
            guard let id = info.firstChildPaneID else { return }
            let newRatio = (info.firstSize + delta) / info.available
            onUpdateRatio(id, newRatio)
        }
        .frame(width: info.rect.width, height: info.rect.height)
        .offset(x: info.rect.origin.x, y: info.rect.origin.y)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No panes")
                .foregroundStyle(.secondary)
                .font(.title3)
            Button("New Pane") {
                onCreatePane()
            }
            .keyboardShortcut(.return, modifiers: [])
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
