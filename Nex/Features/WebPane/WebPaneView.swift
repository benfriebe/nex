import AppKit
import SwiftUI
import WebKit

/// SwiftUI wrapper for a `.web` pane. Composes the chrome strip
/// (URL bar + nav buttons) over a `NSViewRepresentable` host that
/// owns the WKWebView lifecycle: the WebView is fetched from
/// `WebPaneStore` on first render and re-parented across SwiftUI
/// rebuilds during layout transitions (sibling close, workspace
/// switch).
struct WebPaneView: View {
    let paneID: UUID
    let tab: WebTab?
    let isFocused: Bool
    /// Bumped by parent (PaneGridView) when ⌘L fires for this pane —
    /// the chrome promotes the URL bar to first responder.
    let focusURLBarToken: UInt64
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void

    @Environment(\.webPaneStore) private var webPaneStore
    @State private var displayedURL: String = ""
    @State private var canGoBack: Bool = false
    @State private var canGoForward: Bool = false
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            WebPaneChrome(
                paneID: paneID,
                displayedURL: displayedURL,
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                isLoading: isLoading,
                onBack: onBack,
                onForward: onForward,
                onReload: onReload,
                onNavigate: onNavigate,
                onInspect: toggleInspector,
                focusRequestToken: focusURLBarToken
            )

            if let tab {
                WebPaneHost(
                    paneID: paneID,
                    tabID: tab.id,
                    initialURL: tab.url,
                    isFocused: isFocused
                )
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: refreshState)
        .onChange(of: tab?.id) { _, _ in refreshState() }
        .onReceive(NotificationCenter.default.publisher(for: WebPaneCoordinator.stateDidChangeNotification)) { note in
            guard
                let info = note.userInfo,
                let firedPane = info["paneID"] as? UUID,
                firedPane == paneID,
                let firedTab = info["tabID"] as? UUID,
                firedTab == tab?.id
            else { return }
            displayedURL = (info["url"] as? String) ?? displayedURL
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
        guard let tab else { return }
        let coord = webPaneStore.coordinator(for: paneID)
        let ok = coord.toggleInspector(tabID: tab.id)
        if !ok {
            NSLog("WebPaneView: Web Inspector SPI not available on this WebKit build")
        }
    }

    private func refreshState() {
        guard let tab else {
            displayedURL = ""
            canGoBack = false
            canGoForward = false
            return
        }
        let coord = webPaneStore.coordinatorIfExists(for: paneID)
        if let snapshot = coord?.currentURLAndTitle(tabID: tab.id), !snapshot.url.isEmpty {
            displayedURL = snapshot.url
        } else {
            displayedURL = tab.url
        }
        refreshNavState()
    }

    private func refreshNavState() {
        guard let tab,
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

// MARK: - WKWebView host

/// Re-parents the active tab's WKWebView into a fresh container each
/// time SwiftUI rebuilds the surrounding pane (layout transition,
/// sibling close, workspace switch). The store retains the WebView so
/// `dismantleNSView` only needs to detach it from the superview —
/// destruction happens centrally via `WebPaneStore.destroyCoordinator`.
private struct WebPaneHost: NSViewRepresentable {
    let paneID: UUID
    let tabID: UUID
    let initialURL: String
    let isFocused: Bool

    @Environment(\.webPaneStore) private var webPaneStore

    func makeNSView(context _: Context) -> PaneFocusView {
        let focus = PaneFocusView(paneID: paneID)
        let coord = webPaneStore.coordinator(for: paneID)
        // The tab the caller passed isn't necessarily registered with
        // the coordinator yet, so synthesise a stub for the lookup —
        // the coordinator's get-or-create logic will build the WebView
        // and its host container on demand.
        let tab = WebTab(id: tabID, url: initialURL)
        let tabContainer = coord.container(for: tab)
        focus.embed(tabContainer)
        if isFocused {
            Self.claimFirstResponder(for: tabContainer.webView, allowDuringTextEditing: true)
        }
        return focus
    }

    func updateNSView(_ focus: PaneFocusView, context _: Context) {
        let coord = webPaneStore.coordinator(for: paneID)
        let tab = WebTab(id: tabID, url: initialURL)
        let tabContainer = coord.container(for: tab)

        for subview in focus.subviews where subview !== tabContainer {
            subview.removeFromSuperview()
        }
        if tabContainer.superview !== focus {
            tabContainer.removeFromSuperview()
            focus.embed(tabContainer)
        }
        if isFocused {
            Self.claimFirstResponder(for: tabContainer.webView, allowDuringTextEditing: false)
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
        // Detach only — the WKWebView and its coordinator are owned by
        // WebPaneStore. The store releases them on pane close.
        for sub in container.subviews {
            sub.removeFromSuperview()
        }
    }
}
