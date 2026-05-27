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
    /// 0..1 progress through the current load (`WKWebView.estimatedProgress`).
    /// Drives the Safari-style accent strip at the bottom of the chrome.
    var loadProgress: Double = 0
    /// True while the strip should be visible — covers both the live
    /// load and the short fade-out after completion.
    var loadProgressVisible: Bool = false
    /// All open tabs. Used by the tab strip to render pills.
    let tabs: [WebTab]
    let activeTabID: UUID?
    /// True when the pane is running against a `nonPersistent()`
    /// data store — surfaced as a filled-lock icon on the storage
    /// chrome button.
    var isPrivate: Bool = false
    /// True while the storage / cookies disclosure panel is open
    /// (the button shows accent fill while the panel is visible).
    var storagePanelVisible: Bool = false
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onNavigate: (String) -> Void
    let onInspect: () -> Void
    var onToggleStoragePanel: (() -> Void)?
    let onTabSelect: (UUID) -> Void
    let onTabClose: (UUID) -> Void
    let onTabNew: () -> Void
    /// True while the panel is visible AND the page picker is armed.
    var inspectorArmed: Bool = false
    /// Pending batch item count — drives the numeric badge on the
    /// scope icon so a closed panel still surfaces "items waiting".
    var pendingItemCount: Int = 0
    /// Toggle the element-pickup panel. Reducer handles start / hide /
    /// show based on current state; items persist across hide/show.
    var onTogglePickup: (() -> Void)?

    /// Set non-nil to programmatically promote the URL bar to first
    /// responder (consumed by the priority key layer for ⌘L).
    let focusRequestToken: UInt64
    var favourites: [Favourite] = []
    var onToggleStar: (() -> Void)?
    var onOpenFavourite: ((String) -> Void)?

    /// `showSettingsWindow:` via `NSApp.sendAction` with a nil target
    /// doesn't always reach the Settings scene through the responder
    /// chain; `openSettings()` is the supported entry point.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            navAndURLBar
            if tabs.count > 1 {
                tabStrip
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Divider()
                progressStrip
            }
        }
    }

    /// Safari-style accent strip pinned to the bottom edge of the
    /// chrome. Width is bound to `loadProgress` so the bar fills as
    /// the load progresses; opacity is bound to `loadProgressVisible`
    /// so it fades out cleanly after completion.
    private var progressStrip: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: max(0, geo.size.width * loadProgress), height: 2)
                .opacity(loadProgressVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: loadProgress)
                .animation(.easeInOut(duration: 0.25), value: loadProgressVisible)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private var bookmarksMenuButton: some View {
        Menu {
            if favourites.isEmpty {
                Text("No favourites yet")
                Text("Click the star to save the current page")
                    .font(.caption)
            } else {
                ForEach(favourites) { fav in
                    Button(Self.truncatedMenuLabel(fav.displayLabel)) {
                        onOpenFavourite?(fav.url)
                    }
                }
            }
            Divider()
            Button("Manage favourites…") {
                // Stash for cold-open (no listener yet); also post so
                // an already-mounted Settings scene flips immediately.
                WebPaneChrome.pendingSettingsTab = .web
                openSettings()
                NotificationCenter.default.post(
                    name: WebPaneChrome.openSettingsTabNotification, object: SettingsTab.web
                )
            }
        } label: {
            Image(systemName: "book")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .opacity(0.8)
        .help("Bookmarks")
    }

    /// Mid-truncates with `…` so both ends of a long page title stay
    /// visible in the menu (a leading-only ellipsis loses the host;
    /// trailing-only loses the page name). Full title is in Settings.
    static func truncatedMenuLabel(_ label: String, max: Int = 50) -> String {
        guard label.count > max else { return label }
        let head = label.prefix(max / 2)
        let tail = label.suffix(max / 2 - 1)
        return "\(head)…\(tail)"
    }

    static let openSettingsTabNotification = Notification.Name("nex.settings.openTab")

    /// Cross-scene hand-off: the notification posted alongside
    /// `openSettings()` doesn't reach a Settings view that hasn't
    /// mounted yet, so the requested tab is also stashed here and
    /// consumed by `SettingsView.onAppear`.
    nonisolated(unsafe) static var pendingSettingsTab: SettingsTab?

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
                onSubmit: onNavigate,
                isStarred: favourites.firstMatching(url: displayedURL) != nil,
                canStar: !displayedURL.isEmpty,
                onToggleStar: onToggleStar
            )
            .frame(maxWidth: .infinity)

            bookmarksMenuButton

            Button(action: onTabNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.8)
            .help("New tab (⌘T)")

            inspectPickupControl

            storageControl

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

    private var storageControl: some View {
        Button(action: { onToggleStoragePanel?() }) {
            Image(systemName: isPrivate ? "lock.fill" : "lock")
                .font(.system(size: 11, weight: storagePanelVisible ? .semibold : .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .foregroundStyle(
                    (isPrivate || storagePanelVisible)
                        ? Color.accentColor
                        : Color.primary.opacity(0.8)
                )
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(storagePanelVisible ? Color.accentColor.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(isPrivate ? "Storage (private mode)" : "Storage / cookies")
    }

    private var inspectPickupControl: some View {
        Button(action: { onTogglePickup?() }) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: inspectorArmed ? .semibold : .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .foregroundStyle(inspectorArmed ? Color.accentColor : Color.primary.opacity(0.8))
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(inspectorArmed ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(alignment: .topTrailing) {
                    if pendingItemCount > 0 {
                        Text("\(pendingItemCount)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                            .offset(x: 5, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(scopeButtonHelpText)
    }

    private var scopeButtonHelpText: String {
        if inspectorArmed {
            return "Close element pickup (items kept)"
        }
        if pendingItemCount > 0 {
            return "Reopen element pickup (\(pendingItemCount) item\(pendingItemCount == 1 ? "" : "s") waiting)"
        }
        return "Pick elements to send to another pane"
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

/// One row in the inspect-pickup menu. `id` is the target pane's
/// UUID; `label` is what the user sees.
struct InspectTargetOption: Identifiable, Equatable {
    let id: UUID
    let label: String
}

/// A single tab pill in the strip. Shows the tab's title (or host as
/// a fallback) plus a close `x`. Click anywhere on the pill to select;
/// hovering reveals the close button overlaid on the right edge of the
/// pill so the tab footprint does not change on hover (issue #154).
private struct WebTabPill: View {
    let tab: WebTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    private var showsCloseButton: Bool { isHovered || isActive }

    var body: some View {
        Text(tab.displayLabel)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .mask(titleMask)
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
            .overlay(alignment: .trailing) {
                if showsCloseButton {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab (⌘W)")
                    .padding(.trailing, 4)
                }
            }
            .onTapGesture(perform: onSelect)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var titleMask: some View {
        if showsCloseButton {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.black
        }
    }
}

// MARK: - URL bar

/// Composite URL bar: an unbezeled `NSTextField` plus a trailing star
/// toggle, both wrapped in a single rounded border so the star looks
/// embedded inside the URL bar rather than hovering next to it. The
/// AppKit field is kept (rather than swapping to SwiftUI's TextField)
/// because we need first-responder + select-all-on-focus for ⌘L —
/// see `WebURLField` below.
struct WebURLBar: View {
    let initialURL: String
    let paneID: UUID
    let focusRequestToken: UInt64
    let onSubmit: (String) -> Void
    /// Star state for the embedded toggle. Star is shown disabled
    /// (and unclickable) when the URL is empty so a brand-new tab
    /// can't get a meaningless favourite.
    var isStarred: Bool = false
    var canStar: Bool = false
    var onToggleStar: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            WebURLField(
                initialURL: initialURL,
                paneID: paneID,
                focusRequestToken: focusRequestToken,
                onSubmit: onSubmit
            )
            .padding(.leading, 6)
            .frame(maxWidth: .infinity)

            Button(action: { onToggleStar?() }) {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .foregroundStyle(isStarred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canStar)
            .opacity(canStar ? 1.0 : 0.3)
            .help(isStarred ? "Remove from favourites" : "Add to favourites")
            .padding(.trailing, 3)
        }
        .frame(height: 21)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
        )
    }
}

/// The actual text field. Kept as a thin `NSViewRepresentable` so
/// `WebURLBar` can compose it with the star button under a shared
/// SwiftUI border without giving up first-responder control or the
/// select-all-on-focus behaviour.
struct WebURLField: NSViewRepresentable {
    let initialURL: String
    let paneID: UUID
    let focusRequestToken: UInt64
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.focusRingType = .none
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
