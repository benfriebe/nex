import AppKit
import ComposableArchitecture
import SwiftUI

/// Slim header bar at the top of each pane showing the working directory
/// and a close button.
struct PaneHeaderView: View {
    let pane: Pane
    let isFocused: Bool
    let onFocus: () -> Void
    let onSplitHorizontal: () -> Void
    let onSplitVertical: () -> Void
    let onClose: () -> Void
    var isZoomed: Bool = false
    var onToggleZoom: (() -> Void)?
    var isEditing: Bool = false
    var onToggleEdit: (() -> Void)?
    var onCopyMarkdown: (() -> Void)?
    var onCopyRichText: (() -> Void)?
    var onRefreshDiff: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var otherWorkspaces: [(id: UUID, name: String)] = []
    var onRename: (() -> Void)?
    var onMoveToWorkspace: ((UUID) -> Void)?
    /// Manually override the pane's agent status from the context menu
    /// (issue #183). Nil for non-shell panes and when the host hasn't
    /// wired it (tests, previews).
    var onSetStatus: ((PaneStatus) -> Void)?
    /// Open a fresh web pane split off THIS pane (issue #206). The
    /// argument is the split direction: `.horizontal` = right,
    /// `.vertical` = down. Used by the header globe button (click vs
    /// ⇧-click) and the "New Web Pane" context-menu entry. Nil when the
    /// host hasn't wired it (tests, previews).
    var onOpenWebPane: ((PaneLayout.SplitDirection) -> Void)?
    /// True when sync is on for the workspace but this pane has been
    /// opted out. Used to render the "Include in sync" context menu
    /// entry and the dimmed `SYNC OFF` badge.
    var isSyncExcluded: Bool = false
    /// Workspace-level sync flag (issue #121). When true the amber
    /// `SYNC` badge fires for every non-excluded pane in the
    /// workspace, and the context menu offers exclude/include.
    var workspaceSyncActive: Bool = false
    /// Toggle this pane's membership in the sync group. Nil when the
    /// host hasn't wired it (tests, previews).
    var onToggleSyncExcluded: (() -> Void)?

    @State private var isDragging = false
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            if pane.type == .markdown {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
            } else if pane.type == .scratchpad {
                Image(systemName: "note.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
            } else if pane.type == .diff {
                Image(systemName: "plusminus")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
            } else if pane.type == .web {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                    .animation(.easeInOut(duration: 0.3), value: pane.status)
            }

            if let label = pane.label, !label.isEmpty, pane.type != .markdown {
                HStack(spacing: 2) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 8))
                    Text(label)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }

            Text(displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isFocused ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if isZoomed {
                Button(action: { onToggleZoom?() }) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8))
                        Text("ZOOM")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Toggle zoom")
            }

            // Sync chrome — issue #121. The amber `SYNC` badge fires
            // whenever the workspace toggle is on AND this pane isn't
            // excluded, even if no peer is currently around (e.g. a
            // single-pane workspace where the broadcast would no-op
            // anyway). The user explicitly asked for a clear "I forgot
            // it was on" cue, so the visual presence of the toggle
            // takes priority over the abstract "are we currently
            // mirroring anything" question.
            if workspaceSyncActive, !isSyncExcluded {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.connected.to.line.below")
                        .font(.system(size: 8))
                    Text("SYNC")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                .help("Synchronise input is on — keystrokes mirror to peer panes")
            } else if workspaceSyncActive, isSyncExcluded {
                // Sync is on for the workspace but this pane is opted
                // out. Distinct affordance so the user can tell the
                // difference between "no sync" and "sync, but skipped".
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 8))
                    Text("SYNC OFF")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                .help("Excluded from the workspace sync group")
            }

            Spacer()

            if pane.type == .shell, pane.agentSessionID != nil {
                agentBadge
            }

            if let branch = pane.gitBranch {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            }

            if pane.type == .markdown, !isEditing,
               let onCopyMarkdown, let onCopyRichText {
                Button(action: {
                    showCopyMenu(
                        onCopyMarkdown: onCopyMarkdown,
                        onCopyRichText: onCopyRichText
                    )
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Copy whole file")
            }

            if pane.type == .markdown, let onToggleEdit {
                Button(action: onToggleEdit) {
                    Image(systemName: isEditing ? "eye" : "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help(isEditing ? "Preview (⌘E)" : "Edit (⌘E)")
            }

            if pane.type == .diff, let onRefreshDiff {
                Button(action: onRefreshDiff) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Refresh diff")
            }

            Button(action: onSplitHorizontal) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Split right (⌘D)")

            Button(action: onSplitVertical) {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Split down (⌘⇧D)")

            if let onOpenWebPane {
                Button {
                    // Click → split right; ⇧-click → split down. Read
                    // the modifier from the click event that drives this
                    // action (reliable at NSButton action time).
                    let down = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    onOpenWebPane(down ? .vertical : .horizontal)
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("New web pane (⇧-click splits down)")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Close pane (⌘W)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .onTapGesture(count: 2) { onToggleZoom?() }
        .onTapGesture { onFocus() }
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("paneGrid"))
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                    }
                    onDragChanged?(value.location)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnded?()
                }
        )
        // Flat header tone with just the structural divider; focus is shown by
        // the full pane-focus border (drawn around the whole pane in
        // PaneGridView), not a header underline.
        .background(theme.headerBackground)
        .overlay(alignment: .bottom) {
            theme.divider.frame(height: 1)
        }
    }

    /// Right-aligned agent badge: amber `claude · mm:ss` while running,
    /// blue `awaiting input` while waiting. Hidden when idle. Only shown
    /// for shell panes that have an attached agent session.
    @ViewBuilder
    private var agentBadge: some View {
        switch pane.status {
        case .running:
            HStack(spacing: 3) {
                Text("claude")
                if let started = pane.agentStartedAt {
                    Text("·")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(chromeElapsedLabel(from: started, to: context.date))
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(theme.activeAgent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.activeAgent.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
        case .waitingForInput:
            Text("awaiting input")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.statusWaiting)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.statusWaiting.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
        case .idle:
            EmptyView()
        }
    }

    private var statusDotColor: Color {
        switch pane.status {
        case .running:
            theme.statusRunning
        case .waitingForInput:
            theme.statusWaiting
        case .idle:
            isFocused ? theme.textTertiary : theme.textTertiary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if let onRename {
            Button("Rename\u{2026}") { onRename() }
        }
        Button("Close Pane", role: .destructive) { onClose() }
        Divider()
        Button("Split Right") { onSplitHorizontal() }
        Button("Split Down") { onSplitVertical() }
        if let onOpenWebPane {
            Button("New Web Pane") { onOpenWebPane(.horizontal) }
        }
        if let onSetStatus {
            Divider()
            Menu("Status") {
                statusMenuButton("Idle", .idle, onSetStatus)
                statusMenuButton("Running", .running, onSetStatus)
                statusMenuButton("Awaiting Input", .waitingForInput, onSetStatus)
            }
        }
        if !otherWorkspaces.isEmpty, let onMoveToWorkspace {
            Divider()
            Menu("Move to Workspace") {
                ForEach(otherWorkspaces, id: \.id) { ws in
                    Button(ws.name) { onMoveToWorkspace(ws.id) }
                }
            }
        }
        if workspaceSyncActive, let onToggleSyncExcluded {
            Divider()
            Button(isSyncExcluded ? "Include in Sync" : "Exclude from Sync") {
                onToggleSyncExcluded()
            }
        }
        Divider()
        Button("Open in Finder") { openInFinder() }
        Button("Copy Working Directory") { copyWorkingDirectory() }
    }

    /// A single entry in the Status submenu. The current status is marked
    /// with a leading checkmark; the others render as plain text.
    private func statusMenuButton(
        _ title: String,
        _ status: PaneStatus,
        _ onSetStatus: @escaping (PaneStatus) -> Void
    ) -> some View {
        Button { onSetStatus(status) } label: {
            if pane.status == status {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func openInFinder() {
        if pane.type == .markdown, let filePath = pane.filePath {
            NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
        } else if pane.type == .diff, let filePath = pane.filePath, !filePath.isEmpty {
            NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: pane.workingDirectory))
        }
    }

    private func copyWorkingDirectory() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pane.workingDirectory, forType: .string)
    }

    /// Fields that tick continuously while an agent works (status flips,
    /// terminal-title/activity updates). They drive only the header's live
    /// visuals — the status dot, path text, and agent badge — and are
    /// deliberately EXCLUDED from `==` below so an agent tick cannot force a
    /// re-render of the menu-host copy of this view and rebuild its
    /// `.contextMenu` NSMenu out from under an open submenu (issue #227,
    /// pane-header variant). Visual freshness for these fields comes from the
    /// separate live (non-hit-testing) overlay copy in `PaneGridView`.
    private static func menuStableProjection(_ pane: Pane) -> Pane {
        var p = pane
        p.status = .idle
        p.title = nil
        p.agentStartedAt = nil
        p.lastActivityAt = pane.createdAt
        return p
    }

    /// Show a popup menu at the current mouse location. Using an
    /// NSMenu rather than SwiftUI's `Menu` lets the button match the
    /// visual size of the surrounding plain Buttons — `Menu` adds
    /// chrome padding that makes its hit target taller than its peers.
    ///
    /// `popUp(positioning:at:in:)` is used instead of
    /// `popUpContextMenu(_:with:for:)` because the latter relies on
    /// `NSApp.currentEvent`, which by the time SwiftUI's button action
    /// fires is no longer the originating click — that produced a
    /// noticeable (~1 second) delay before the menu appeared.
    private func showCopyMenu(
        onCopyMarkdown: @escaping () -> Void,
        onCopyRichText: @escaping () -> Void
    ) {
        let menu = NSMenu()
        let mdItem = NSMenuItem(
            title: "Copy as Markdown",
            action: nil,
            keyEquivalent: ""
        )
        mdItem.representedObject = ClosureBox(onCopyMarkdown)
        mdItem.target = MenuActionTarget.shared
        mdItem.action = #selector(MenuActionTarget.invoke(_:))

        let rtfItem = NSMenuItem(
            title: "Copy as Rich Text",
            action: nil,
            keyEquivalent: ""
        )
        rtfItem.representedObject = ClosureBox(onCopyRichText)
        rtfItem.target = MenuActionTarget.shared
        rtfItem.action = #selector(MenuActionTarget.invoke(_:))

        menu.addItem(mdItem)
        menu.addItem(rtfItem)

        // Position the menu under the cursor in view-local coordinates.
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView
        else {
            menu.popUp(positioning: nil, at: .zero, in: nil)
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: contentView)
    }

    private var displayPath: String {
        if pane.type == .scratchpad {
            return "Scratchpad"
        }
        if pane.type == .markdown, let filePath = pane.filePath {
            return (filePath as NSString).lastPathComponent
        }
        if pane.type == .diff {
            let target = pane.filePath ?? ""
            let scope = target.isEmpty
                ? (pane.workingDirectory as NSString).lastPathComponent
                : (target as NSString).lastPathComponent
            return "diff: \(scope)"
        }
        return chromeHomeAbbreviated(pane.title ?? pane.workingDirectory)
    }
}

// MARK: - Equatable (menu-stability boundary)

/// `@preconcurrency` because `View` is `@MainActor`-isolated and `Equatable`
/// is not: SwiftUI only ever compares views during a main-actor render pass,
/// so the conformance is safe, and this silences the Swift 6 actor-isolation
/// diagnostic (the same pattern the codebase uses for Obj-C conformances).
extension PaneHeaderView: @preconcurrency Equatable {
    /// Two header views are "equal" — and SwiftUI may therefore skip
    /// re-rendering (and rebuilding the `.contextMenu` NSMenu) — whenever
    /// nothing that changes the menu's structure or the header's chrome has
    /// changed. High-frequency agent-activity fields (status / title /
    /// started-at / last-activity) are projected out via
    /// `menuStableProjection`, so a churning pane no longer dismisses an open
    /// Status / Move-to-Workspace submenu (issue #227). The stored closures are
    /// intentionally ignored: they are captured per pane id and stay correct
    /// even when a comparison skips a re-render. `PaneGridView` renders a second
    /// live, non-hit-testing copy on top so the status dot / path / badge still
    /// update in real time.
    static func == (lhs: PaneHeaderView, rhs: PaneHeaderView) -> Bool {
        menuStableProjection(lhs.pane) == menuStableProjection(rhs.pane)
            && lhs.isFocused == rhs.isFocused
            && lhs.isZoomed == rhs.isZoomed
            && lhs.isEditing == rhs.isEditing
            && lhs.isSyncExcluded == rhs.isSyncExcluded
            && lhs.workspaceSyncActive == rhs.workspaceSyncActive
            && lhs.otherWorkspaces.map(\.id) == rhs.otherWorkspaces.map(\.id)
            && lhs.otherWorkspaces.map(\.name) == rhs.otherWorkspaces.map(\.name)
    }
}

// MARK: - NSMenu closure dispatch

/// Box for invoking a `() -> Void` closure from an NSMenuItem's
/// `representedObject`. NSMenuItem.action needs an @objc target, so we
/// route through a shared dispatcher that pulls the closure off the
/// menu item that fired the action.
private final class ClosureBox {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
}

@MainActor
private final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    @objc func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.closure()
    }
}
