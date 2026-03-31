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
    let isZoomed: Bool
    let onToggleMarkdownEdit: (UUID) -> Void
    let onUpdateRatio: (String, Double) -> Void
    var onMovePane: ((UUID, UUID, PaneLayout.DropZone) -> Void)?

    @Environment(\.ghosttyConfig) private var ghosttyConfig

    @State private var dragSourcePaneID: UUID?
    @State private var dragTargetPaneID: UUID?
    @State private var dragDropZone: PaneLayout.DropZone?
    @State private var gridSize: CGSize = .zero

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
                    // Drop zone overlay
                    if let targetID = dragTargetPaneID,
                       let zone = dragDropZone,
                       let targetFrame = frames[targetID] {
                        dropZoneOverlay(frame: targetFrame, zone: zone)
                    }
                }
            }
            .coordinateSpace(name: "paneGrid")
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: { newSize in
                gridSize = newSize
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
                onClose: { onClosePane(pane.id) },
                isZoomed: isZoomed,
                isEditing: pane.isEditing,
                onToggleEdit: pane.type == .markdown ? { onToggleMarkdownEdit(pane.id) } : nil,
                onDragChanged: { point in
                    dragSourcePaneID = pane.id
                    let bounds = CGRect(origin: .zero, size: gridSize)
                    let frames = layout.paneFrames(in: bounds)
                    // Hit-test: find which pane contains the cursor
                    var hitTarget: UUID?
                    for (id, rect) in frames {
                        if id != pane.id, rect.contains(point) {
                            hitTarget = id
                            break
                        }
                    }
                    dragTargetPaneID = hitTarget
                    if let hitTarget, let rect = frames[hitTarget] {
                        dragDropZone = PaneLayout.DropZone.calculate(at: point, in: rect)
                    } else {
                        dragDropZone = nil
                    }
                },
                onDragEnded: {
                    if let source = dragSourcePaneID,
                       let target = dragTargetPaneID,
                       let zone = dragDropZone {
                        onMovePane?(source, target, zone)
                    }
                    dragSourcePaneID = nil
                    dragTargetPaneID = nil
                    dragDropZone = nil
                }
            )

            switch pane.type {
            case .shell:
                SurfaceContainerView(
                    paneID: pane.id,
                    workingDirectory: pane.workingDirectory,
                    isFocused: pane.id == focusedPaneID
                )
            case .markdown:
                if pane.isEditing {
                    MarkdownEditorView(
                        paneID: pane.id,
                        filePath: pane.filePath ?? "",
                        isFocused: pane.id == focusedPaneID,
                        backgroundColor: ghosttyConfig.backgroundColor,
                        backgroundOpacity: ghosttyConfig.backgroundOpacity
                    )
                } else {
                    MarkdownPaneView(
                        paneID: pane.id,
                        filePath: pane.filePath ?? "",
                        isFocused: pane.id == focusedPaneID,
                        backgroundColor: ghosttyConfig.backgroundColor,
                        backgroundOpacity: ghosttyConfig.backgroundOpacity
                    )
                }
            }
        }
        .background {
            if pane.type == .markdown {
                Color(nsColor: ghosttyConfig.backgroundColor)
                    .opacity(ghosttyConfig.backgroundOpacity)
            }
        }
        .overlay {
            if pane.id == focusedPaneID {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            }
        }
        .opacity(dragSourcePaneID == pane.id ? 0.5 : 1.0)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.origin.x, y: frame.origin.y)
    }

    private func dividerView(info: SplitDividerInfo) -> some View {
        SplitDividerView(direction: info.direction) { delta in
            let newRatio = (info.firstSize + delta) / info.available
            onUpdateRatio(info.id, newRatio)
        }
        .frame(width: info.rect.width, height: info.rect.height)
        .offset(x: info.rect.origin.x, y: info.rect.origin.y)
    }

    private func dropZoneOverlay(frame: CGRect, zone: PaneLayout.DropZone) -> some View {
        let overlayRect = switch zone {
        case .left:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }

        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.2))
            .border(Color.accentColor.opacity(0.5), width: 2)
            .frame(width: overlayRect.width, height: overlayRect.height)
            .offset(x: overlayRect.origin.x, y: overlayRect.origin.y)
            .allowsHitTesting(false)
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
        .background(Color(nsColor: ghosttyConfig.backgroundColor))
    }
}
