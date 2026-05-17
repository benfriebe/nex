import AppKit
import Foundation
import WebKit

/// Per-pane owner of WKWebView instances, one per tab, all sharing
/// the pane's `WKWebsiteDataStore`.
///
/// Lifecycle contract, mirrors `SurfaceManager` for terminal panes:
/// - `WebPaneStore` creates the coordinator lazily on first access.
/// - `WebPaneView.makeNSView` retrieves the active tab's WKWebView and
///   embeds it; if the surrounding split is later torn down by a layout
///   transition, `WebPaneView.dismantleNSView` only detaches from
///   superview. The coordinator (and the WebView) lives on.
/// - The coordinator is destroyed only when the pane itself is closed,
///   via `WebPaneStore.destroyCoordinator(paneID:)` invoked from the
///   `.closePane` effect in `WorkspaceFeature`.
@MainActor
final class WebPaneCoordinator: NSObject, WKNavigationDelegate {
    let paneID: UUID
    let dataStore: WKWebsiteDataStore

    /// Per-tab WKWebView. Keyed by tab id.
    private var webViews: [UUID: WKWebView] = [:]
    /// Per-tab frame-based container around the WKWebView. Acts as
    /// the "attachment view" the Inspector docks into — see
    /// `container(for:)` for the rationale.
    private var containers: [UUID: WebPaneTabContainer] = [:]

    /// Notification posted when a WebView's URL or title changes. Used
    /// by `WebPaneView` to mirror state into the store (which the CLI
    /// `pane web url` reads). User info: `paneID`, `tabID`, `url`,
    /// `title`.
    static let stateDidChangeNotification = Notification.Name("WebPaneCoordinator.stateDidChange")

    /// KVO tokens per webview, so deinit (or destroy) can detach.
    private var kvoTokens: [UUID: [NSKeyValueObservation]] = [:]

    init(
        paneID: UUID,
        dataStore: WKWebsiteDataStore
    ) {
        self.paneID = paneID
        self.dataStore = dataStore
        super.init()
    }

    deinit {
        // KVO observations have to be invalidated before their host
        // object goes away; left dangling they fire selector calls
        // against deallocated memory at app teardown.
        for tokens in kvoTokens.values {
            for token in tokens {
                token.invalidate()
            }
        }
    }

    // MARK: - Tab access

    /// Get-or-create the frame-based container hosting the active
    /// tab's WKWebView. The container exists so the Safari Web
    /// Inspector can dock itself in attached mode: WebKit attaches by
    /// inserting an inspector view as a sibling of the WKWebView and
    /// resizing both via direct frame manipulation. Auto Layout
    /// constraints between the WKWebView and its parent block that
    /// (silent attach failure — "show succeeds but no inspector
    /// surface"). The container fixes both halves: itself fills the
    /// outer (Auto Layout) parent, but lets its children float on
    /// `autoresizingMask`, leaving WebKit free to insert and resize
    /// the inspector view alongside the WKWebView.
    func container(for tab: WebTab) -> WebPaneTabContainer {
        if let existing = containers[tab.id] { return existing }
        let webView = webView(for: tab)
        let host = WebPaneTabContainer(webView: webView)
        containers[tab.id] = host
        return host
    }

    /// Look up the existing container without creating one. Used by
    /// the multi-tab host view to enumerate already-mounted tabs
    /// without forcing a load.
    func containerIfExists(tabID: UUID) -> WebPaneTabContainer? {
        containers[tabID]
    }

    /// Tear down a single tab — invalidates its KVO tokens, drops
    /// its WKWebView from the dict, removes its container from the
    /// view hierarchy. Used by `webPaneTabClose` to release resources
    /// without affecting sibling tabs.
    func destroyTab(tabID: UUID) {
        if let tokens = kvoTokens.removeValue(forKey: tabID) {
            for token in tokens {
                token.invalidate()
            }
        }
        if let container = containers.removeValue(forKey: tabID) {
            container.removeFromSuperview()
        }
        webViews.removeValue(forKey: tabID)
    }

    /// Get-or-create the WebView for the given tab.
    func webView(for tab: WebTab) -> WKWebView {
        if let existing = webViews[tab.id] { return existing }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // Belt-and-braces: enable WebKit's developer extras on the
        // configuration's preferences in addition to the public
        // `isInspectable` flag below. The public API alone is supposed
        // to enable the "Inspect Element" context menu item on
        // macOS 13.3+, but some WebKit builds also check this older
        // private preference before showing the entry. Setting both
        // is the well-known reliable path for a developer-facing
        // browser.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // No script handlers in Phase 1 — they arrive in Phase 3.

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // Right-click → Inspect Element opens the native Safari Web
        // Inspector. macOS 13.3+ only; project min is 14.0 so safe.
        webView.isInspectable = true

        webViews[tab.id] = webView

        // Track url + title for the chrome's URL bar and the
        // `pane web url` reply. The KVO closure is `@Sendable`
        // under Swift 6 strict concurrency, so we can't read
        // `webView.url` / `webView.title` (both main-actor) from
        // it directly; capture the webView pointer and read on
        // the main actor inside Task.
        let tabID = tab.id
        let snapshotAndPost: @Sendable (WKWebView?) -> Void = { [weak self] webView in
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                postStateChange(
                    tabID: tabID,
                    url: webView.url?.absoluteString ?? "",
                    title: webView.title ?? ""
                )
            }
        }
        let urlToken = webView.observe(\.url, options: [.new]) { [weak webView] _, _ in
            snapshotAndPost(webView)
        }
        let titleToken = webView.observe(\.title, options: [.new]) { [weak webView] _, _ in
            snapshotAndPost(webView)
        }
        kvoTokens[tab.id] = [urlToken, titleToken]

        if let url = URL(string: tab.url) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    private func postStateChange(tabID: UUID, url: String, title: String) {
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: nil,
            userInfo: [
                "paneID": paneID,
                "tabID": tabID,
                "url": url,
                "title": title
            ]
        )
    }

    // MARK: - Navigation

    /// Load a new URL in the given tab (creating its WKWebView if needed).
    /// Accepts bare hostnames ("example.com") by prepending `https://`
    /// when no scheme is present.
    @discardableResult
    func navigate(tab: WebTab, to rawURLString: String) -> URL? {
        let urlString = Self.normalizeURLInput(rawURLString)
        guard let url = URL(string: urlString) else { return nil }
        let webView = webView(for: tab)
        webView.load(URLRequest(url: url))
        return url
    }

    /// Promote a user-typed URL bar value into something `URL` can
    /// parse. "example.com" → "https://example.com"; an existing
    /// scheme is left intact. Nonisolated so the reducer (which
    /// isn't always on the main actor) can call it before dispatch.
    nonisolated static func normalizeURLInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.contains("://") { return trimmed }
        if trimmed.hasPrefix("about:") { return trimmed }
        return "https://\(trimmed)"
    }

    @discardableResult
    func goBack(tabID: UUID) -> Bool {
        guard let webView = webViews[tabID], webView.canGoBack else { return false }
        webView.goBack()
        return true
    }

    @discardableResult
    func goForward(tabID: UUID) -> Bool {
        guard let webView = webViews[tabID], webView.canGoForward else { return false }
        webView.goForward()
        return true
    }

    @discardableResult
    func reload(tabID: UUID, hard: Bool = false) -> Bool {
        guard let webView = webViews[tabID] else { return false }
        if hard {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
        return true
    }

    /// Toggle the Safari Web Inspector docked inside the tab's
    /// `WebPaneTabContainer` via WebKit's private `_inspector` SPI.
    /// Closes the inspector if it's currently visible; otherwise
    /// opens and docks it. Returns false if the SPI isn't present on
    /// this WebKit build (older macOS).
    ///
    /// Order matters on open: `show` first, then `attach`. Calling
    /// `attach` before `show` is a no-op because the inspector window
    /// hasn't been instantiated yet, so the inspector falls back to
    /// its persisted state (detached by default on first launch, or
    /// whatever the user last left it in — which is what right-click
    /// "Inspect Element" also obeys).
    @discardableResult
    func toggleInspector(tabID: UUID) -> Bool {
        guard let webView = webViews[tabID] else { return false }

        let inspectorSel = NSSelectorFromString("_inspector")
        if webView.responds(to: inspectorSel),
           let inspectorAny = webView.perform(inspectorSel)?.takeUnretainedValue(),
           let inspector = inspectorAny as? NSObject {
            let isVisible = (inspector.value(forKey: "visible") as? Bool) ?? false
            if isVisible {
                let closeSel = NSSelectorFromString("close")
                let hideSel = NSSelectorFromString("hide")
                if inspector.responds(to: closeSel) {
                    inspector.perform(closeSel)
                    return true
                } else if inspector.responds(to: hideSel) {
                    inspector.perform(hideSel)
                    return true
                }
                return false
            }

            let showSel = NSSelectorFromString("show")
            let showWithArg = NSSelectorFromString("show:")
            if inspector.responds(to: showSel) {
                inspector.perform(showSel)
            } else if inspector.responds(to: showWithArg) {
                inspector.perform(showWithArg, with: nil)
            } else {
                return false
            }
            // Defer the attach by a runloop tick — the inspector
            // window needs to finish mounting before `attach` can
            // re-dock it. This also flips WebKit's persisted dock
            // preference so subsequent right-click "Inspect Element"
            // opens stay docked.
            let attachSel = NSSelectorFromString("attachBottom")
            let attachFallback = NSSelectorFromString("attach")
            DispatchQueue.main.async { [inspector] in
                if inspector.responds(to: attachSel) {
                    inspector.perform(attachSel)
                } else if inspector.responds(to: attachFallback) {
                    inspector.perform(attachFallback)
                }
            }
            return true
        }
        // Legacy fallback for older WebKit builds.
        let legacy = NSSelectorFromString("_showWebInspector")
        if webView.responds(to: legacy) {
            webView.perform(legacy)
            return true
        }
        return false
    }

    // MARK: - Inspection

    /// Current URL + title for the named tab. Falls back to the cached
    /// state when no WKWebView has been built yet (e.g. immediately
    /// after restore but before the pane has rendered).
    func currentURLAndTitle(tabID: UUID) -> (url: String, title: String)? {
        guard let webView = webViews[tabID] else { return nil }
        return (webView.url?.absoluteString ?? "", webView.title ?? "")
    }

    /// Visible text in the active tab. Returns the empty string when
    /// no page has finished loading yet. JS injection runs on the main
    /// frame only; cross-origin iframes are not stitched together in
    /// Phase 1.
    func captureText(tabID: UUID, maxBytes: Int = 1_000_000) async -> String {
        guard let webView = webViews[tabID] else { return "" }
        let result = try? await webView.evaluateJavaScript(
            "document.body ? document.body.innerText : ''"
        )
        guard let text = result as? String else { return "" }
        if text.utf8.count <= maxBytes { return text }
        // Truncate to byte budget while staying on a UTF-8 boundary.
        var truncated = text
        while truncated.utf8.count > maxBytes {
            truncated.removeLast()
        }
        return truncated + "\n[truncated]"
    }

    /// Capture the visible viewport as a PNG. Returns the raw bytes;
    /// callers decide whether to inline as base64 or spill to a file.
    func captureScreenshot(tabID: UUID) async -> Data? {
        guard let webView = webViews[tabID] else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        do {
            let image = try await webView.takeSnapshot(configuration: config)
            guard
                let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            else { return nil }
            return png
        } catch {
            return nil
        }
    }

    // WKNavigationDelegate methods are intentionally left at default
    // (.allow) for Phase 1 — link clicks navigate in-place. Phase 4
    // will likely intercept .linkActivated to support "open in new
    // tab".
}

/// Frame-based NSView that holds a WKWebView and gives the Safari Web
/// Inspector a place to dock. Auto Layout constraints between the
/// WKWebView and the surrounding SwiftUI hierarchy stop the inspector
/// from attaching (it needs to resize the WKWebView and add a sibling
/// view), so we sit this container in the middle: Auto Layout fills
/// it from above (PaneFocusView), and its children float on
/// `autoresizingMask` from below.
@MainActor
final class WebPaneTabContainer: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        autoresizesSubviews = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
