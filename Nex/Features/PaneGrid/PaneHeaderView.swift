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

    @State private var isDragging = false

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
                .foregroundStyle(isFocused ? .primary : .secondary)
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

            Spacer()

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
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if isFocused {
                    Color.accentColor.opacity(0.15)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isFocused {
                Color.accentColor.opacity(0.6)
                    .frame(height: 2)
            }
        }
    }

    private var statusDotColor: Color {
        switch pane.status {
        case .running:
            .green
        case .waitingForInput:
            .blue
        case .idle:
            isFocused ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.3)
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
        if !otherWorkspaces.isEmpty, let onMoveToWorkspace {
            Divider()
            Menu("Move to Workspace") {
                ForEach(otherWorkspaces, id: \.id) { ws in
                    Button(ws.name) { onMoveToWorkspace(ws.id) }
                }
            }
        }
        Divider()
        Button("Open in Finder") { openInFinder() }
        Button("Copy Working Directory") { copyWorkingDirectory() }
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
        let path = pane.title ?? pane.workingDirectory
        if let home = ProcessInfo.processInfo.environment["HOME"],
           path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
