import AppKit
import SwiftUI

/// Chrome strip at the top of a web pane: nav buttons + URL bar +
/// inspector toggle, with a tab strip below. The tab strip and `+`
/// button are hidden when only one tab is open so single-tab panes
/// stay visually quiet.
struct WebPaneChrome: View {
    let paneID: UUID
    let displayedURL: String
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    /// All open tabs. Used by the tab strip to render pills.
    let tabs: [WebTab]
    let activeTabID: UUID?
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onNavigate: (String) -> Void
    let onInspect: () -> Void
    let onTabSelect: (UUID) -> Void
    let onTabClose: (UUID) -> Void
    let onTabNew: () -> Void

    /// Set non-nil to programmatically promote the URL bar to first
    /// responder (consumed by the priority key layer for ⌘L).
    let focusRequestToken: UInt64

    var body: some View {
        VStack(spacing: 0) {
            navAndURLBar
            if tabs.count > 1 {
                tabStrip
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var navAndURLBar: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .opacity(canGoBack ? 0.8 : 0.3)
            .help("Back (⌘[)")

            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
            .opacity(canGoForward ? 0.8 : 0.3)
            .help("Forward (⌘])")

            Button(action: onReload) {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.8)
            .help("Reload (⌘R)")

            WebURLBar(
                initialURL: displayedURL,
                paneID: paneID,
                focusRequestToken: focusRequestToken,
                onSubmit: onNavigate
            )
            .frame(maxWidth: .infinity)

            Button(action: onTabNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.8)
            .help("New tab (⌘T)")

            Button(action: onInspect) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.8)
            .help("Toggle Safari Web Inspector")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    WebTabPill(
                        tab: tab,
                        isActive: tab.id == activeTabID,
                        onSelect: { onTabSelect(tab.id) },
                        onClose: { onTabClose(tab.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}

/// A single tab pill in the strip. Shows the tab's title (or host as
/// a fallback) plus a close `x`. Click anywhere on the pill to select;
/// hovering reveals the close button.
private struct WebTabPill: View {
    let tab: WebTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.displayLabel)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1
                )
        )
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}

// MARK: - URL bar

/// `NSTextField`-backed URL bar. SwiftUI's `TextField` doesn't expose
/// first-responder control cleanly, and we need that for ⌘L (focus URL
/// bar) and for the "select-all-on-focus" behaviour every browser
/// gives you. Using AppKit directly avoids ad-hoc workarounds.
struct WebURLBar: NSViewRepresentable {
    let initialURL: String
    let paneID: UUID
    let focusRequestToken: UInt64
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.placeholderString = "Enter URL"
        field.stringValue = initialURL
        field.delegate = context.coordinator
        context.coordinator.field = field
        context.coordinator.lastSeenToken = focusRequestToken
        context.coordinator.lastSeenURL = initialURL
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coord = context.coordinator
        // Only overwrite the URL bar when the underlying URL actually
        // changes and the user isn't actively editing — otherwise the
        // user's in-progress typing would be wiped on every render.
        if coord.lastSeenURL != initialURL,
           field.window?.firstResponder !== field.currentEditor() {
            field.stringValue = initialURL
            coord.lastSeenURL = initialURL
        }
        if coord.lastSeenToken != focusRequestToken {
            coord.lastSeenToken = focusRequestToken
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let onSubmit: (String) -> Void
        weak var field: NSTextField?
        var lastSeenToken: UInt64 = 0
        var lastSeenURL: String = ""

        init(onSubmit: @escaping (String) -> Void) {
            self.onSubmit = onSubmit
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let value = field?.stringValue {
                    onSubmit(value)
                }
                return true
            }
            return false
        }
    }
}
