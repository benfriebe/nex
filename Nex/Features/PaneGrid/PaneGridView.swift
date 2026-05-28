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
    let onToggleZoom: () -> Void
    let onToggleMarkdownEdit: (UUID) -> Void
    let onScratchpadContentChanged: (UUID, String) -> Void
    let onUpdateRatio: (String, Double) -> Void
    var onMovePane: ((UUID, UUID, PaneLayout.DropZone) -> Void)?
    var searchingPaneID: UUID?
    var searchNeedle: String = ""
    var searchTotal: Int?
    var searchSelected: Int?
    var onSearchNeedleChanged: ((String) -> Void)?
    var onSearchNavigateNext: (() -> Void)?
    var onSearchNavigatePrevious: (() -> Void)?
    var onSearchClose: (() -> Void)?
    var focusFollowsMouse: Bool = false
    var focusFollowsMouseDelay: Int = 0
    var otherWorkspaces: [(id: UUID, name: String)] = []
    var onRenamePane: ((UUID) -> Void)?
    var onMovePaneToWorkspace: ((UUID, UUID) -> Void)?
    /// Sidecar state for `.web` panes in this workspace. Keyed by pane id.
    var webPanes: [UUID: WebPaneState] = [:]
    /// URL bar focus token bumped by ⌘L. Used by `WebPaneView` to
    /// promote the URL bar to first responder for the matching pane.
    var webPaneURLFocusToken: [UUID: UInt64] = [:]
    var onWebNavigate: ((UUID, String) -> Void)?
    var onWebBack: ((UUID) -> Void)?
    var onWebForward: ((UUID) -> Void)?
    var onWebReload: ((UUID) -> Void)?
    var onWebTabSelect: ((UUID, UUID) -> Void)?
    var onWebTabClose: ((UUID, UUID) -> Void)?
    var onWebTabNew: ((UUID) -> Void)?
    /// Toggle the element-pickup panel on a web pane. Reducer-side
    /// logic decides between start / hide / show based on the
    /// current state of `batchInspect` and `panelVisible`.
    var onWebTogglePickup: ((UUID) -> Void)?
    var onWebBatchItemCommentChanged: ((UUID, UUID, String) -> Void)?
    var onWebBatchItemRemoved: ((UUID, UUID) -> Void)?
    var onWebBatchRowTapped: ((UUID, UUID) -> Void)?
    /// Send the batch. Second arg is the destination pane id —
    /// nil = drop into the local inspect-result queue.
    var onWebBatchSend: ((UUID, UUID?) -> Void)?
    var onWebBatchCancel: ((UUID) -> Void)?
    /// Flip the per-pane private mode flag. Reducer destroys the
    /// coordinator, the host then rebuilds against the new store on
    /// the next SwiftUI pass.
    var onWebTogglePrivate: ((UUID) -> Void)?
    /// Global web favourites — surfaced in every web pane's chrome.
    var favourites: [Favourite] = []
    var onToggleFavourite: ((String, String) -> Void)?
    var onOpenFavourite: ((UUID, String) -> Void)?

    @Environment(\.ghosttyConfig) private var ghosttyConfig
    @Environment(\.surfaceManager) private var surfaceManager

    @State private var dragSourcePaneID: UUID?
    @State private var dragTargetPaneID: UUID?
    @State private var dragDropZone: PaneLayout.DropZone?
    @State private var gridSize: CGSize = .zero
    @State private var isResizing = false
    @State private var resizeHideTask: Task<Void, Never>?
    @State private var focusHoverTask: Task<Void, Never>?
    @State private var diffRefreshTokens: [UUID: UInt64] = [:]

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
                let oldSize = gridSize
                gridSize = newSize
                if oldSize != .zero, newSize != oldSize {
                    resizeHideTask?.cancel()
                    isResizing = true
                    scheduleResizeHide()
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
                onClose: { onClosePane(pane.id) },
                isZoomed: isZoomed,
                onToggleZoom: onToggleZoom,
                isEditing: pane.isEditing,
                onToggleEdit: pane.type == .markdown ? { onToggleMarkdownEdit(pane.id) } : nil,
                onCopyMarkdown: pane.type == .markdown
                    ? { postMarkdownCopy(pane.id, kind: .markdown) }
                    : nil,
                onCopyRichText: pane.type == .markdown
                    ? { postMarkdownCopy(pane.id, kind: .richText) }
                    : nil,
                onRefreshDiff: pane.type == .diff
                    ? { diffRefreshTokens[pane.id, default: 0] &+= 1 }
                    : nil,
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
                },
                otherWorkspaces: otherWorkspaces,
                onRename: onRenamePane.map { handler in { handler(pane.id) } },
                onMoveToWorkspace: onMovePaneToWorkspace.map { handler in
                    { targetWS in handler(pane.id, targetWS) }
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
                    if let editorCommand = pane.externalEditorCommand {
                        // The reducer also calls createSurface with this same
                        // command; SurfaceManager deduplicates so both code
                        // paths converge on a single surface.
                        SurfaceContainerView(
                            paneID: pane.id,
                            workingDirectory: pane.workingDirectory,
                            isFocused: pane.id == focusedPaneID,
                            command: editorCommand
                        )
                    } else {
                        MarkdownEditorView(
                            paneID: pane.id,
                            filePath: pane.filePath ?? "",
                            isFocused: pane.id == focusedPaneID,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            backgroundOpacity: ghosttyConfig.backgroundOpacity
                        )
                        .clipped()
                    }
                } else {
                    MarkdownPaneView(
                        paneID: pane.id,
                        filePath: pane.filePath ?? "",
                        isFocused: pane.id == focusedPaneID,
                        backgroundColor: ghosttyConfig.backgroundColor,
                        backgroundOpacity: ghosttyConfig.backgroundOpacity,
                        fontSize: pane.markdownFontSize
                    )
                }
            case .scratchpad:
                ScratchpadEditorView(
                    paneID: pane.id,
                    initialContent: pane.scratchpadContent ?? "",
                    isFocused: pane.id == focusedPaneID,
                    onContentChanged: { content in
                        onScratchpadContentChanged(pane.id, content)
                    },
                    backgroundColor: ghosttyConfig.backgroundColor,
                    backgroundOpacity: ghosttyConfig.backgroundOpacity
                )
                .clipped()
            case .diff:
                DiffPaneView(
                    paneID: pane.id,
                    repoPath: pane.workingDirectory,
                    targetPath: pane.filePath,
                    isFocused: pane.id == focusedPaneID,
                    refreshToken: diffRefreshTokens[pane.id] ?? 0,
                    backgroundColor: ghosttyConfig.backgroundColor,
                    backgroundOpacity: ghosttyConfig.backgroundOpacity,
                    fontSize: pane.markdownFontSize
                )
            case .web:
                WebPaneView(
                    paneID: pane.id,
                    tabs: webPanes[pane.id]?.tabs ?? [],
                    activeTabID: webPanes[pane.id]?.activeTabID,
                    isPrivate: webPanes[pane.id]?.isPrivate ?? false,
                    isFocused: pane.id == focusedPaneID,
                    focusURLBarToken: webPaneURLFocusToken[pane.id] ?? 0,
                    onNavigate: { url in onWebNavigate?(pane.id, url) },
                    onBack: { onWebBack?(pane.id) },
                    onForward: { onWebForward?(pane.id) },
                    onReload: { onWebReload?(pane.id) },
                    onTabSelect: { tabID in onWebTabSelect?(pane.id, tabID) },
                    onTabClose: { tabID in onWebTabClose?(pane.id, tabID) },
                    onTabNew: { onWebTabNew?(pane.id) },
                    onTogglePrivate: { onWebTogglePrivate?(pane.id) },
                    availableInspectTargets: inspectTargets(excluding: pane.id),
                    inspectorArmed: (webPanes[pane.id]?.batchInspect?.panelVisible) ?? false,
                    batchInspect: webPanes[pane.id]?.batchInspect,
                    lastBatchTarget: webPanes[pane.id]?.lastBatchTarget,
                    onTogglePickup: { onWebTogglePickup?(pane.id) },
                    onBatchItemCommentChanged: { itemID, comment in
                        onWebBatchItemCommentChanged?(pane.id, itemID, comment)
                    },
                    onBatchItemRemoved: { itemID in
                        onWebBatchItemRemoved?(pane.id, itemID)
                    },
                    onBatchRowTapped: { itemID in
                        onWebBatchRowTapped?(pane.id, itemID)
                    },
                    onBatchSend: { sendTo in onWebBatchSend?(pane.id, sendTo) },
                    onBatchCancel: { onWebBatchCancel?(pane.id) },
                    favourites: favourites,
                    onToggleFavourite: { url, title in
                        onToggleFavourite?(url, title)
                    },
                    onOpenFavourite: { url in
                        onOpenFavourite?(pane.id, url)
                    }
                )
            }
        }
        // Clamp the VStack to the computed pane rect and clip overflow.
        // `.frame(width:height:)` only assigns a layout slot — SwiftUI
        // does not strictly force the inner content to render within
        // those bounds. PaneHeaderView's `.background { Color }` and
        // its focused accent line size to the HStack's actual rendered
        // width, and the embedded `NSViewRepresentable` can keep stale
        // Auto Layout bounds during inspector / sidebar toggles. The
        // result was that the header chrome and focus ring spilled past
        // the pane's right edge into the inspector strip (#143).
        // `.clipped()` enforces the visible bounds; the outer `.frame`
        // at the end of the chain stays put so `.onHover` hit-testing
        // is anchored to the same rect.
        .frame(width: frame.width, height: frame.height)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if searchingPaneID == pane.id {
                PaneSearchOverlay(
                    needle: searchNeedle,
                    total: searchTotal,
                    selected: searchSelected,
                    onNeedleChanged: { onSearchNeedleChanged?($0) },
                    onNavigateNext: { onSearchNavigateNext?() },
                    onNavigatePrevious: { onSearchNavigatePrevious?() },
                    onClose: { onSearchClose?() }
                )
                .padding(.top, 4)
                .padding(.trailing, 8)
            }
        }
        .background {
            if pane.type == .markdown || pane.type == .scratchpad || pane.type == .diff || pane.type == .web {
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
        .overlay {
            if isResizing {
                ResizeDimensionsView(paneID: pane.id, paneFrame: frame)
            }
        }
        .onHover { hovering in
            guard focusFollowsMouse else { return }
            focusHoverTask?.cancel()
            if hovering, pane.id != focusedPaneID {
                let delay = focusFollowsMouseDelay
                if delay > 0 {
                    focusHoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled else { return }
                        onFocusPane(pane.id)
                    }
                } else {
                    onFocusPane(pane.id)
                }
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
        } onDragStateChanged: { dragging in
            if dragging {
                resizeHideTask?.cancel()
                isResizing = true
            } else {
                scheduleResizeHide()
            }
        }
        .frame(width: info.rect.width, height: info.rect.height)
        .offset(x: info.rect.origin.x, y: info.rect.origin.y)
    }

    private func scheduleResizeHide() {
        resizeHideTask?.cancel()
        resizeHideTask = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            isResizing = false
        }
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

    /// Build the dropdown entries for the web pane's inspect-pickup
    /// button: every other shell pane in the same workspace,
    /// labelled by its tag (or working-directory tail when no tag is
    /// set). The source web pane is excluded so users don't
    /// accidentally pipe the payload back into the page they're
    /// inspecting, and non-shell panes (markdown / scratchpad / diff
    /// / web) are filtered out because they have no terminal surface
    /// for `paneSendText` to write to.
    private func inspectTargets(excluding sourcePaneID: UUID) -> [InspectTargetOption] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return panes.compactMap { pane -> InspectTargetOption? in
            guard pane.id != sourcePaneID else { return nil }
            guard pane.type == .shell else { return nil }
            let label: String = {
                if let tag = pane.label, !tag.isEmpty { return tag }
                var cwd = pane.workingDirectory
                if !home.isEmpty, cwd.hasPrefix(home) {
                    cwd = "~" + cwd.dropFirst(home.count)
                }
                let lastComponent = (cwd as NSString).lastPathComponent
                return "shell: \(lastComponent)"
            }()
            return InspectTargetOption(id: pane.id, label: label)
        }
    }

    private func postMarkdownCopy(_ paneID: UUID, kind: MarkdownCopyKind) {
        NotificationCenter.default.post(
            name: MarkdownPaneView.copyRequestNotification,
            object: nil,
            userInfo: ["paneID": paneID, "kind": kind.rawValue]
        )
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
