import AppKit
import SwiftUI
import WebKit

/// SwiftUI wrapper for a `.web` pane. Composes the chrome strip
/// (URL bar + nav buttons + tab strip) over a `NSViewRepresentable`
/// host that owns the WKWebView lifecycle. The host keeps all tab
/// containers mounted side-by-side as siblings (only the active one
/// visible via `isHidden = false`); the store retains them across
/// SwiftUI rebuilds during layout transitions.
struct WebPaneView: View {
    let paneID: UUID
    /// All tabs in this web pane, in display order. Empty array =
    /// blank pane (no tab yet).
    let tabs: [WebTab]
    /// Currently visible tab. nil falls back to `tabs.first`.
    let activeTabID: UUID?
    let isFocused: Bool
    /// Bumped by parent (PaneGridView) when ⌘L fires for this pane,
    /// the chrome promotes the URL bar to first responder.
    let focusURLBarToken: UInt64
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onTabSelect: (UUID) -> Void
    let onTabClose: (UUID) -> Void
    let onTabNew: () -> Void
    /// Sibling panes in the same workspace, surfaced in the panel's
    /// destination picker at send time.
    let availableInspectTargets: [InspectTargetOption]
    let inspectorArmed: Bool
    /// Active batch state. nil = no batch in progress.
    let batchInspect: BatchInspectState?
    /// Previous batch destination on this pane (in-session memory) —
    /// seeds the panel's initial picker selection on a second batch.
    let lastBatchTarget: BatchTargetMemory?
    let onTogglePickup: () -> Void
    /// Edit / remove individual items, then finalise or cancel.
    let onBatchItemCommentChanged: (UUID, String) -> Void
    let onBatchItemRemoved: (UUID) -> Void
    let onBatchRowTapped: (UUID) -> Void
    /// `sendTo` nil → queue locally; non-nil → paste into that pane.
    let onBatchSend: (UUID?) -> Void
    let onBatchCancel: () -> Void
    let favourites: [Favourite]
    let onToggleFavourite: (String, String) -> Void
    let onOpenFavourite: (String) -> Void

    @Environment(\.webPaneStore) private var webPaneStore
    @State private var displayedURL: String = ""
    /// Title that pairs with `displayedURL`. Updated from the same
    /// stateDidChange notification so the star toggle never saves a
    /// stale title under a newly-navigated URL.
    @State private var displayedTitle: String = ""
    @State private var canGoBack: Bool = false
    @State private var canGoForward: Bool = false
    @State private var isLoading: Bool = false

    /// Single source of truth for which tab is active. The host and
    /// chrome both read this so they never disagree about the
    /// fallback when `activeTabID` is stale.
    private var activeTab: WebTab? {
        if let id = activeTabID, let tab = tabs.first(where: { $0.id == id }) { return tab }
        return tabs.first
    }

    var body: some View {
        let active = activeTab
        VStack(spacing: 0) {
            WebPaneChrome(
                paneID: paneID,
                displayedURL: displayedURL,
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                isLoading: isLoading,
                tabs: tabs,
                activeTabID: active?.id,
                onBack: onBack,
                onForward: onForward,
                onReload: onReload,
                onNavigate: onNavigate,
                onInspect: toggleInspector,
                onTabSelect: onTabSelect,
                onTabClose: onTabClose,
                onTabNew: onTabNew,
                inspectorArmed: inspectorArmed,
                pendingItemCount: batchInspect?.items.count ?? 0,
                onTogglePickup: onTogglePickup,
                focusRequestToken: focusURLBarToken,
                favourites: favourites,
                onToggleStar: {
                    onToggleFavourite(displayedURL, displayedTitle)
                },
                onOpenFavourite: onOpenFavourite
            )

            if let batchInspect, batchInspect.panelVisible {
                WebBatchInspectPanel(
                    items: batchInspect.items,
                    availableTargets: availableInspectTargets,
                    focusedItemID: batchInspect.focusedItemID,
                    onCommentChanged: onBatchItemCommentChanged,
                    onRemoveItem: onBatchItemRemoved,
                    onRowTapped: onBatchRowTapped,
                    onSend: onBatchSend,
                    onCancel: onBatchCancel,
                    initialSelection: lastBatchTarget
                )
            }

            if tabs.isEmpty {
                emptyState
            } else {
                WebPaneHost(
                    paneID: paneID,
                    tabs: tabs,
                    activeTab: active,
                    isFocused: isFocused
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: refreshState)
        .onChange(of: active?.id) { _, _ in refreshState() }
        .onReceive(NotificationCenter.default.publisher(for: WebPaneCoordinator.stateDidChangeNotification)) { note in
            guard
                let info = note.userInfo,
                let firedPane = info["paneID"] as? UUID,
                firedPane == paneID,
                let firedTab = info["tabID"] as? UUID,
                firedTab == active?.id
            else { return }
            // Ignore the empty/about:blank placeholders WebKit surfaces
            // during a failed or in-progress load — otherwise a broken
            // URL would persist as "about:blank" in the URL bar
            // (mirrors the guard in WorkspaceFeature.webPaneStateChanged).
            if let rawURL = info["url"] as? String,
               !rawURL.isEmpty, rawURL != "about:blank" {
                displayedURL = rawURL
                displayedTitle = (info["title"] as? String) ?? ""
            }
            refreshNavState()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("New web pane")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text("Type a URL above and press Return")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleInspector() {
        guard let tab = activeTab else { return }
        webPaneStore.coordinator(for: paneID).toggleInspector(tabID: tab.id)
    }

    private func refreshState() {
        guard let tab = activeTab else {
            displayedURL = ""
            displayedTitle = ""
            canGoBack = false
            canGoForward = false
            return
        }
        let coord = webPaneStore.coordinatorIfExists(for: paneID)
        if let snapshot = coord?.currentURLAndTitle(tabID: tab.id), !snapshot.url.isEmpty {
            displayedURL = snapshot.url
            displayedTitle = snapshot.title
        } else {
            displayedURL = tab.url
            displayedTitle = tab.title
        }
        refreshNavState()
    }

    private func refreshNavState() {
        guard let tab = activeTab,
              let webView = webPaneStore.coordinatorIfExists(for: paneID)?.webView(for: tab) else {
            canGoBack = false
            canGoForward = false
            isLoading = false
            return
        }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }
}

// MARK: - WKWebView host (multi-tab)

/// Mounts every tab's `WebPaneTabContainer` as a sibling inside a
/// single `PaneFocusView`, toggling `isHidden` to swap which one is
/// visible. Non-active tabs keep loading / running JS in the
/// background; their WKWebViews persist across tab switches and
/// SwiftUI rebuilds (the store owns them).
///
/// Lifecycle:
/// - `makeNSView` builds the focus container and mounts every tab.
/// - `updateNSView` reconciles when tabs are added/removed/reordered
///   and updates `isHidden`.
/// - `dismantleNSView` only detaches from superview; the store
///   keeps the WKWebViews alive.
private struct WebPaneHost: NSViewRepresentable {
    let paneID: UUID
    let tabs: [WebTab]
    /// Pre-resolved by `WebPaneView` so this host and the chrome
    /// agree on which tab is visible (no double fallback).
    let activeTab: WebTab?
    let isFocused: Bool

    @Environment(\.webPaneStore) private var webPaneStore

    func makeNSView(context _: Context) -> PaneFocusView {
        let focus = PaneFocusView(paneID: paneID)
        let coord = webPaneStore.coordinator(for: paneID)
        for tab in tabs {
            let tabContainer = coord.container(for: tab)
            focus.embed(tabContainer)
            tabContainer.isHidden = tab.id != activeTab?.id
        }
        if let activeTab, isFocused {
            Self.claimFirstResponder(
                for: coord.container(for: activeTab).webView,
                allowDuringTextEditing: true
            )
        }
        return focus
    }

    func updateNSView(_ focus: PaneFocusView, context _: Context) {
        let coord = webPaneStore.coordinator(for: paneID)
        let liveContainers = tabs.map { coord.container(for: $0) }
        let liveContainerSet = Set(liveContainers.map { ObjectIdentifier($0) })

        // Drop subviews that no longer correspond to a live tab
        // (e.g. tab closed via `webPaneTabClose`).
        for subview in focus.subviews {
            if !liveContainerSet.contains(ObjectIdentifier(subview)) {
                subview.removeFromSuperview()
            }
        }

        for container in liveContainers {
            if container.superview !== focus {
                container.removeFromSuperview()
                focus.embed(container)
            }
        }

        // Active tab visible, others hidden but still mounted so
        // their JS keeps running.
        for (tab, container) in zip(tabs, liveContainers) {
            container.isHidden = tab.id != activeTab?.id
        }

        if isFocused, let activeTab {
            Self.claimFirstResponder(
                for: coord.container(for: activeTab).webView,
                allowDuringTextEditing: false
            )
        }
    }

    /// Promote `webView` to first responder if it isn't already and the
    /// URL bar isn't actively editing. Skips synchronously when the
    /// state is already correct so SwiftUI's frequent `updateNSView`
    /// calls don't queue redundant main-actor hops.
    private static func claimFirstResponder(for webView: WKWebView, allowDuringTextEditing: Bool) {
        if let window = webView.window {
            if window.firstResponder === webView { return }
            if !allowDuringTextEditing, window.firstResponder is NSText { return }
        }
        DispatchQueue.main.async { [weak webView] in
            guard let webView, let window = webView.window else { return }
            if window.firstResponder === webView { return }
            if !allowDuringTextEditing, window.firstResponder is NSText { return }
            window.makeFirstResponder(webView)
        }
    }

    static func dismantleNSView(_ container: PaneFocusView, coordinator _: ()) {
        // Detach only — WKWebViews and tab containers are owned by
        // WebPaneStore and survive view teardown.
        for sub in container.subviews {
            sub.removeFromSuperview()
        }
    }
}
