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

    /// Notification posted on every `estimatedProgress` or `isLoading`
    /// transition so `WebPaneView` can drive the Safari-style progress
    /// strip in the chrome. User info: `paneID`, `tabID`,
    /// `progress: Double` (0..1), `isLoading: Bool`.
    static let loadProgressDidChangeNotification = Notification.Name("WebPaneCoordinator.loadProgressDidChange")

    /// Notification posted for every captured console line.
    /// User info: `paneID`, `tabID`, `level`, `message`, `url`,
    /// optional `lineNumber`, `columnNumber`.
    static let consoleLineNotification = Notification.Name("WebPaneCoordinator.consoleLine")

    /// Notification posted for every accepted (main-frame, nonce-
    /// matched) inspect-result payload. User info: `paneID`, `tabID`,
    /// `payload: [String: Any]` (the raw JSON from the picker JS).
    static let inspectResultNotification = Notification.Name("WebPaneCoordinator.inspectResult")

    /// Notification posted when the user clicks a batch-marker badge
    /// rendered on the page. User info: `paneID`, `tabID`, `itemID`
    /// (the BatchInspectItem.id passed in via `setBatchMarkers`).
    static let batchMarkerClickedNotification = Notification.Name("WebPaneCoordinator.batchMarkerClicked")

    /// Notification posted when the user types in the on-page comment
    /// popover. User info: `paneID`, `tabID`, `itemID`, `comment`.
    static let batchCommentEditedNotification = Notification.Name("WebPaneCoordinator.batchCommentEdited")

    /// Notification posted when the user clicks Done (or hits Esc)
    /// in the page popover. User info: `paneID`, `tabID`, `itemID`.
    static let batchPopoverDismissedNotification = Notification.Name("WebPaneCoordinator.batchPopoverDismissed")

    /// Notification posted when the user clicks Remove in the page
    /// popover. User info: `paneID`, `tabID`, `itemID`.
    static let batchItemRemovedFromPopoverNotification = Notification.Name("WebPaneCoordinator.batchItemRemovedFromPopover")

    /// KVO tokens per webview, so deinit (or destroy) can detach.
    private var kvoTokens: [UUID: [NSKeyValueObservation]] = [:]

    /// Last `(progress, isLoading)` posted per tab. `estimatedProgress`
    /// and `isLoading` both fire `progressPost` reading the *current*
    /// values, so a single transition (e.g. `isLoading=false` + final
    /// `estimatedProgress=1.0`) easily double-posts identical payloads.
    private var lastPostedProgress: [UUID: (Double, Bool)] = [:]

    // MARK: - Inspector arm state

    /// Currently-armed inspector tab. Used to validate inspect
    /// payloads and to disarm on tab switch/close.
    private(set) var armedInspectorTabID: UUID?
    /// Nonce installed at arm time. Compared against every inspect
    /// payload's `nonce`; mismatch → drop.
    private(set) var armedInspectorNonce: String?
    /// True when the picker should remain armed across multiple
    /// clicks (batch annotate mode). The coordinator stops auto-
    /// disarming on inbound `nexInspect` messages while this is set;
    /// the page-side picker also keeps its overlay/listeners attached.
    private(set) var armedInspectorIsSticky: Bool = false

    /// URL we last asked each tab's WKWebView to load via
    /// `navigate(tab:to:)`. On a load failure the WKWebView's `url`
    /// property reverts to `about:blank` or the previous successful
    /// URL; we re-emit this value through `stateDidChangeNotification`
    /// so the URL bar keeps showing what the user tried.
    private var lastAttemptedURL: [UUID: String] = [:]

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
        lastAttemptedURL.removeValue(forKey: tabID)
        lastPostedProgress.removeValue(forKey: tabID)
        showingErrorPage.remove(tabID)
        // Drop the inspector arm if it pointed at the destroyed tab
        // — a late click against the gone WebView could otherwise
        // route an inspect payload nowhere useful.
        if armedInspectorTabID == tabID {
            armedInspectorTabID = nil
            armedInspectorNonce = nil
            armedInspectorIsSticky = false
        }
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

        // Phase 3: console + inspector scripts. A weak proxy receives
        // the script messages so the WKWebView ↔ message-handler edge
        // doesn't retain the coordinator (the store owns the
        // coordinator; we want it released on pane close).
        let handler = WebPaneScriptHandler(coordinator: self, tabID: tab.id)
        config.userContentController.add(handler, name: "nexConsole")
        config.userContentController.add(handler, name: "nexInspect")
        config.userContentController.add(handler, name: "nexBatchMarker")
        // Console wraps `console.*` so we want it to run before page
        // code; `forMainFrameOnly: false` so cross-origin iframes
        // also report (still scoped to this pane's WebView).
        config.userContentController.addUserScript(WKUserScript(
            source: WebPaneConsoleScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // Inspector + batch markers only run in the main frame —
        // iframe support is out of scope and would also leak overlays
        // across origins.
        config.userContentController.addUserScript(WKUserScript(
            source: WebPaneInspectorScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: WebPaneBatchMarkerScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // Actuator namespace (window.__nexAct) — selector parser +
        // DOM lookup / action / wait primitives that every
        // `nex web <verb>` invocation composes on top of. Main frame
        // only; cross-origin frames are out of scope for actuation.
        config.userContentController.addUserScript(WKUserScript(
            source: WebPaneActuatorScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

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
                // Explicit `self.` is required under Swift 6 strict
                // concurrency in the Release-config compile path —
                // swiftformat's redundantSelf rule wants to strip it,
                // hence the inline disable.
                // swiftformat:disable:next redundantSelf
                self.postStateChange(
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
        // Drive the Safari-style progress strip — both fire frequently
        // during a single page load (subresource fetches bump progress,
        // navigation start / finish flip isLoading), so they share one
        // post helper that captures the current values together.
        let progressPost: @Sendable (WKWebView?) -> Void = { [weak self] webView in
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                // See note above — explicit `self.` required by the
                // Release-config Swift 6 compiler; formatter wants it
                // stripped, so suppress the rule for this call.
                // swiftformat:disable:next redundantSelf
                self.postLoadProgress(
                    tabID: tabID,
                    progress: webView.estimatedProgress,
                    isLoading: webView.isLoading
                )
            }
        }
        let progressToken = webView.observe(\.estimatedProgress, options: [.new]) { [weak webView] _, _ in
            progressPost(webView)
        }
        let loadingToken = webView.observe(\.isLoading, options: [.new]) { [weak webView] _, _ in
            progressPost(webView)
        }
        kvoTokens[tab.id] = [urlToken, titleToken, progressToken, loadingToken]

        if let url = URL(string: tab.url) {
            // Mirror what `navigate(tab:to:)` does so the reload
            // button and the error stub's Retry anchor have a URL
            // to fall back to when the initial restore load fails.
            // Without this seed, `presentLoadFailure` ends up with
            // an empty `failedURL` and the stub renders with an
            // empty href; reload() then has nothing to retry.
            lastAttemptedURL[tab.id] = url.absoluteString
            load(url, into: webView)
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

    private func postLoadProgress(tabID: UUID, progress: Double, isLoading: Bool) {
        if let last = lastPostedProgress[tabID], last == (progress, isLoading) { return }
        lastPostedProgress[tabID] = (progress, isLoading)
        NotificationCenter.default.post(
            name: Self.loadProgressDidChangeNotification,
            object: nil,
            userInfo: [
                "paneID": paneID,
                "tabID": tabID,
                "progress": progress,
                "isLoading": isLoading
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
        lastAttemptedURL[tab.id] = url.absoluteString
        showingErrorPage.remove(tab.id)
        load(url, into: webView)
        return url
    }

    /// Load `url` into `webView`. `file://` URLs go through
    /// `loadFileURL(_:allowingReadAccessTo:)` so WKWebView grants read
    /// access to the file's directory — sibling assets (`./style.css`,
    /// images) referenced by a local HTML file then resolve. Remote
    /// URLs use a normal request load.
    private func load(_ url: URL, into webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Reverse-lookup helper for `WKNavigationDelegate` callbacks —
    /// the callbacks deliver the `WKWebView` but we key everything
    /// off the tab id.
    private func tabID(for webView: WKWebView) -> UUID? {
        webViews.first(where: { $0.value === webView })?.key
    }

    /// Promote a user-typed URL bar value into something `URL` can
    /// parse. Defaults to `https://` for typical hostnames and to
    /// `http://` for local / private hosts (localhost, 127.0.0.1,
    /// `.local`, RFC 1918 ranges, single-label hosts) where dev
    /// servers usually aren't TLS-terminated. An existing scheme
    /// is left intact. Nonisolated so the reducer (which isn't
    /// always on the main actor) can call it before dispatch.
    nonisolated static func normalizeURLInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.contains("://") { return trimmed }

        // Recognise opaque schemes that don't use `://` — `data:`,
        // `javascript:`, `mailto:`, `tel:`, `about:`, `file:` and the
        // like. Distinguish a real scheme from a `host:port` pair by
        // looking at what follows the colon: a port is digits, a
        // scheme value starts with anything else. Without this, e.g.
        // `data:text/html,<h1>x</h1>` would be prefixed with
        // `https://` and never load (caught by PR #147 cua validation).
        if let colonIdx = trimmed.firstIndex(of: ":"),
           let firstChar = trimmed.first,
           firstChar.isLetter {
            let scheme = trimmed[..<colonIdx]
            let validSchemeChars = scheme.allSatisfy { ch in
                ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == "."
            }
            let afterIdx = trimmed.index(after: colonIdx)
            let afterColon = trimmed[afterIdx...]
            let looksLikePort = afterColon.first?.isNumber == true
            if validSchemeChars, !looksLikePort {
                return trimmed
            }
        }

        // Extract the host portion ("host[:port]/path?..." → "host").
        let beforePath = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let hostOnly = beforePath.split(separator: ":").first.map(String.init) ?? beforePath
        let scheme = isLocalOrInternalHost(hostOnly) ? "http" : "https"
        return "\(scheme)://\(trimmed)"
    }

    nonisolated static func isLocalOrInternalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.isEmpty { return false }
        if lower == "localhost" || lower == "127.0.0.1" || lower == "0.0.0.0" || lower == "::1" { return true }
        if lower.hasSuffix(".local") || lower.hasSuffix(".localhost") { return true }
        // Single-label (no dot) → assume internal hostname / mDNS.
        if !lower.contains(".") { return true }
        // RFC 1918 IPv4 ranges + link-local.
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 { return true }
            if parts[0] == 192, parts[1] == 168 { return true }
            if parts[0] == 172, (16 ... 31).contains(parts[1]) { return true }
            if parts[0] == 169, parts[1] == 254 { return true }
        }
        return false
    }

    @discardableResult
    func goBack(tabID: UUID) -> Bool {
        guard let webView = webViews[tabID], webView.canGoBack else { return false }
        showingErrorPage.remove(tabID)
        webView.goBack()
        return true
    }

    @discardableResult
    func goForward(tabID: UUID) -> Bool {
        guard let webView = webViews[tabID], webView.canGoForward else { return false }
        showingErrorPage.remove(tabID)
        webView.goForward()
        return true
    }

    @discardableResult
    func reload(tabID: UUID, hard: Bool = false) -> Bool {
        guard let webView = webViews[tabID] else { return false }
        // Reload while sitting on our error stub should retry the
        // original URL, not redraw the stub.
        if showingErrorPage.contains(tabID),
           let attempted = lastAttemptedURL[tabID],
           let url = URL(string: attempted) {
            showingErrorPage.remove(tabID)
            load(url, into: webView)
            return true
        }
        if hard {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
        return true
    }

    /// Step the tab's page zoom by `delta` (nil resets to 1.0),
    /// clamped to [0.5, 3.0].
    @discardableResult
    func adjustPageZoom(tabID: UUID, delta: CGFloat?) -> Bool {
        guard let webView = webViews[tabID] else { return false }
        let target = delta.map { webView.pageZoom + $0 } ?? 1.0
        webView.pageZoom = min(max(target, 0.5), 3.0)
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

    /// Evaluate a JS source string against the named tab's WKWebView
    /// and return the raw result. Thin wrapper around
    /// `WKWebView.evaluateJavaScript` that surfaces the missing-tab
    /// case as `nil` rather than throwing. Used by `WebPaneActuator`
    /// and the rebuilt `web exec`.
    func evaluateJavaScript(tabID: UUID, source: String) async -> Any? {
        guard let webView = webViews[tabID] else { return nil }
        return try? await webView.evaluateJavaScript(source)
    }

    /// Like `evaluateJavaScript` but `WKWebView.callAsyncJavaScript`
    /// wraps the source in an async function and awaits returned
    /// Promises — required for actuator methods whose JS body
    /// returns a Promise (e.g. `wait`). The plain
    /// `evaluateJavaScript` path returns the Promise *object*
    /// instead of awaiting it, which serialises to `{}`.
    func callAsyncJavaScript(tabID: UUID, source: String) async -> Any? {
        guard let webView = webViews[tabID] else { return nil }
        return try? await webView.callAsyncJavaScript(
            source,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    /// Whether the coordinator currently has a WebView for `tabID`.
    /// `WebPaneActuator` uses this to distinguish "tab gone between
    /// dispatch and evaluation" from "tab still present but the
    /// actuator reply was unparseable".
    func knowsTab(tabID: UUID) -> Bool {
        webViews[tabID] != nil
    }

    // MARK: - WKNavigationDelegate

    @preconcurrency
    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Error
    ) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor [weak self, weak webView] in
            self?.presentLoadFailure(on: webView, message: message)
        }
    }

    @preconcurrency
    nonisolated func webView(
        _ webView: WKWebView,
        didFail _: WKNavigation!,
        withError error: Error
    ) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor [weak self, weak webView] in
            self?.presentLoadFailure(on: webView, message: message)
        }
    }

    @preconcurrency
    nonisolated func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        // Any real provisional navigation (URL bar, Retry link,
        // back/forward, page-initiated nav) means the user is
        // leaving the error stub. Clear the flag so a subsequent
        // didFinish for the new load is allowed to clear
        // lastAttemptedURL. Skips clearing for the stub's own
        // navigation (identified by identity) — that load is the
        // error page itself, not a recovery attempt.
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, let tabID = tabID(for: webView) else { return }
            if let navigation, stubNavigations.remove(ObjectIdentifier(navigation)) != nil {
                return
            }
            showingErrorPage.remove(tabID)
        }
    }

    @preconcurrency
    nonisolated func webView(
        _ webView: WKWebView,
        didFinish _: WKNavigation!
    ) {
        // Successful nav clears the attempted-URL backstop so a
        // subsequent failure on a different page doesn't resurrect
        // the previous attempt. Skips clearing when the just-loaded
        // page is our own error stub — that's a "failed" page, not
        // a successful load.
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, let tabID = tabID(for: webView) else { return }
            if showingErrorPage.contains(tabID) { return }
            lastAttemptedURL.removeValue(forKey: tabID)
        }
    }

    /// Tabs that are currently displaying our inline error stub
    /// instead of real content. Used to suppress the `didFinish`
    /// clear of `lastAttemptedURL` and to skip "page reload" type
    /// behaviours that don't make sense on an error page.
    private var showingErrorPage: Set<UUID> = []

    /// Identities of `WKNavigation` instances returned by
    /// `loadHTMLString` for the error stub. `didStartProvisionalNavigation`
    /// uses these to recognise the stub's own provisional load and
    /// skip clearing `showingErrorPage` for it — every other
    /// provisional nav means the user is recovering from the error.
    private var stubNavigations: Set<ObjectIdentifier> = []

    /// Replace the WKWebView's content with a small dark error page
    /// instead of leaving a blank surface after a navigation failure.
    /// Using `baseURL = <failed URL>` makes WKWebView's `url` property
    /// report the failed URL, so the URL bar naturally stays on what
    /// the user tried (no manual re-emit shim needed).
    private func presentLoadFailure(on webView: WKWebView?, message: String) {
        guard let webView, let tabID = tabID(for: webView) else { return }
        let failedURL = lastAttemptedURL[tabID]
            ?? webView.url?.absoluteString
            ?? ""
        let html = Self.errorPageHTML(failedURL: failedURL, message: message)
        let baseURL = URL(string: failedURL)
        showingErrorPage.insert(tabID)
        if let nav = webView.loadHTMLString(html, baseURL: baseURL) {
            stubNavigations.insert(ObjectIdentifier(nav))
        }
    }

    /// Build the inline error page HTML. Plain, dark, single-file,
    /// no external assets so it always renders regardless of network
    /// state. The Retry button is a normal anchor — clicking it
    /// re-issues a navigation through the same delegate chain.
    private static func errorPageHTML(failedURL: String, message: String) -> String {
        /// Escape for HTML attribute / text. We're embedding inside
        /// a literal string so just neutralise the obvious unsafe
        /// characters.
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let displayURL = escape(failedURL.isEmpty ? "(unknown)" : failedURL)
        let displayMessage = escape(message.isEmpty ? "The page could not be loaded." : message)
        let retryHref = escape(failedURL)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Couldn't load page</title>
        <style>
        :root { color-scheme: dark; }
        html, body {
            height: 100%; margin: 0;
            background: #1c1c1e; color: #f2f2f7;
            font: 14px -apple-system, system-ui, sans-serif;
        }
        .wrap {
            min-height: 100%; display: flex;
            align-items: center; justify-content: center;
            padding: 32px;
        }
        .card {
            max-width: 480px;
            background: rgba(255,255,255,0.04);
            border: 1px solid rgba(255,255,255,0.08);
            border-radius: 10px;
            padding: 24px 28px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.4);
        }
        .icon {
            width: 32px; height: 32px;
            border-radius: 50%;
            background: rgba(255,69,58,0.18);
            color: #FF453A;
            display: flex; align-items: center; justify-content: center;
            font: 700 16px/1 -apple-system, system-ui, sans-serif;
            margin-bottom: 14px;
        }
        h1 {
            font-size: 16px; font-weight: 600;
            margin: 0 0 6px;
        }
        .url {
            font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            color: #5AC8FA;
            word-break: break-all;
            margin: 0 0 14px;
        }
        p.message {
            margin: 0 0 18px;
            color: rgba(242,242,247,0.75);
            line-height: 1.45;
        }
        .actions { display: flex; gap: 8px; }
        a.btn {
            display: inline-block;
            padding: 6px 14px;
            border-radius: 6px;
            background: #0A84FF;
            color: white;
            text-decoration: none;
            font-weight: 600;
            font-size: 12px;
        }
        a.btn.ghost {
            background: transparent;
            color: rgba(242,242,247,0.85);
            border: 1px solid rgba(255,255,255,0.18);
        }
        a.btn:hover { filter: brightness(1.1); }
        </style>
        </head>
        <body>
        <div class="wrap">
        <div class="card">
        <div class="icon">!</div>
        <h1>Couldn't load page</h1>
        <p class="url">\(displayURL)</p>
        <p class="message">\(displayMessage)</p>
        <div class="actions">
        <a class="btn" href="\(retryHref)">Retry</a>
        </div>
        </div>
        </div>
        </body>
        </html>
        """
    }

    // MARK: - Inspector arm/disarm (Phase 3)

    /// Arm the element picker for the named tab. Generates a 128-bit
    /// nonce, stashes it for validation, and tells the in-page picker
    /// to listen for the next click. `sticky: true` keeps the picker
    /// armed after each click (used by batch-annotate mode); the
    /// default single-shot path disarms automatically on the next
    /// delivered message.
    @discardableResult
    func armInspector(tabID: UUID, sticky: Bool = false) -> String? {
        guard let webView = webViews[tabID] else { return nil }
        // Disarm any previous arm first — both nonce-side and
        // page-side. This handles the "user re-fires `nex web inspect`
        // before clicking" case cleanly.
        if let prev = armedInspectorTabID, prev != tabID,
           let prevWebView = webViews[prev] {
            prevWebView.evaluateJavaScript("__nexInspectorDisable && __nexInspectorDisable();")
        }
        let nonce = Self.makeNonce()
        armedInspectorTabID = tabID
        armedInspectorNonce = nonce
        armedInspectorIsSticky = sticky
        // Escape the nonce as JS string literal. Our nonce is hex
        // only so `'\(nonce)'` is safe, but be defensive in case
        // the format ever changes.
        let stickyArg = sticky ? "true" : "false"
        let js = "window.__nexInspectorEnable && window.__nexInspectorEnable('\(nonce)', \(stickyArg));"
        webView.evaluateJavaScript(js)
        return nonce
    }

    /// Symmetric tear-down. Clears the armed-nonce state and tells
    /// the in-page picker to clean up its overlay + listeners.
    func disarmInspector() {
        let tabID = armedInspectorTabID
        armedInspectorTabID = nil
        armedInspectorNonce = nil
        armedInspectorIsSticky = false
        guard let tabID, let webView = webViews[tabID] else { return }
        webView.evaluateJavaScript("__nexInspectorDisable && __nexInspectorDisable();")
    }

    /// Generate a 128-bit hex nonce. Good enough — the channel is
    /// in-process and the nonce only needs to defend against a page
    /// JS attacker spoofing inspect messages while the picker is
    /// armed on this exact pane.
    private static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - WKScriptMessageHandler bridge (Phase 3)

    /// Handle a `nexConsole` message. Always main-actor — `userInfo`
    /// is built and posted synchronously so the reducer sees lines
    /// in the order WebKit fired them.
    fileprivate func handleConsoleMessage(tabID: UUID, body: Any) {
        guard let dict = body as? [String: Any] else { return }
        let level = (dict["level"] as? String) ?? "log"
        let message = (dict["message"] as? String) ?? ""
        let url = (dict["url"] as? String) ?? ""
        var userInfo: [AnyHashable: Any] = [
            "paneID": paneID,
            "tabID": tabID,
            "level": level,
            "message": message,
            "url": url
        ]
        if let line = dict["lineNumber"] as? Int { userInfo["lineNumber"] = line }
        if let col = dict["columnNumber"] as? Int { userInfo["columnNumber"] = col }
        NotificationCenter.default.post(
            name: Self.consoleLineNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Handle a `nexInspect` message. Validates main frame + nonce
    /// against the currently-armed state before posting; mismatched
    /// messages are dropped silently to avoid hinting to page JS
    /// that the channel exists.
    fileprivate func handleInspectMessage(tabID: UUID, body: Any, isMainFrame: Bool) {
        guard isMainFrame else { return }
        guard let armedTab = armedInspectorTabID, armedTab == tabID else { return }
        guard let armedNonce = armedInspectorNonce else { return }
        guard let dict = body as? [String: Any] else { return }
        guard let nonce = dict["nonce"] as? String, nonce == armedNonce else { return }

        // Escape hatch: picker may report a user-cancelled arm
        // (e.g. user pressed Escape). Disarm here, don't surface
        // a result.
        if (dict["cancelled"] as? Bool) == true {
            disarmInspector()
            return
        }

        // Single-shot mode disarms before posting so observers see
        // consistent post-click state. Sticky (batch) mode keeps the
        // arm live; the reducer is responsible for explicitly
        // disarming when the batch is sent or cancelled.
        let wasSticky = armedInspectorIsSticky
        if !wasSticky {
            disarmInspector()
        }

        NotificationCenter.default.post(
            name: Self.inspectResultNotification,
            object: nil,
            userInfo: [
                "paneID": paneID,
                "tabID": tabID,
                "payload": dict
            ]
        )
    }

    // MARK: - Batch markers (Phase 3.5)

    /// Push the full list of batch-annotate items to the named tab so
    /// the page renders numbered badges over each captured element.
    /// The selector is re-queried in JS on every redraw so badges
    /// follow live DOM changes (responsive layouts, post-mount React
    /// reflows, etc.) rather than the rect snapshot captured at
    /// click time.
    func syncBatchMarkers(tabID: UUID, items: [BatchMarkerInput]) {
        guard let webView = webViews[tabID] else { return }
        let dicts: [[String: Any]] = items.map {
            [
                "id": $0.id.uuidString,
                "selector": $0.selector,
                "label": $0.label,
                "comment": $0.comment
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__nexBatchSetMarkers && window.__nexBatchSetMarkers(\(json));"
        webView.evaluateJavaScript(js)
    }

    /// Hide the page popover + focus ring without removing any
    /// markers. Used when the user clicks Done / presses Esc in the
    /// popover so they can pick the next element.
    func unfocusBatch(tabID: UUID) {
        guard let webView = webViews[tabID] else { return }
        webView.evaluateJavaScript("window.__nexBatchUnfocus && window.__nexBatchUnfocus();")
    }

    /// Push a single external (panel-side) comment update into the
    /// page popover. JS no-ops the update if the textarea is being
    /// typed into, so cross-side edits don't clobber the cursor.
    func pushBatchComment(tabID: UUID, itemID: UUID, comment: String) {
        guard let webView = webViews[tabID] else { return }
        let escaped: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: [comment]),
                  let s = String(data: data, encoding: .utf8) else { return "\"\"" }
            // strip the leading "[" and trailing "]" to get the JSON string literal
            return String(s.dropFirst().dropLast())
        }()
        let js = "window.__nexBatchUpdateComment && " +
            "window.__nexBatchUpdateComment('\(itemID.uuidString)', \(escaped));"
        webView.evaluateJavaScript(js)
    }

    func clearBatchMarkers(tabID: UUID) {
        guard let webView = webViews[tabID] else { return }
        webView.evaluateJavaScript("window.__nexBatchClearMarkers && window.__nexBatchClearMarkers();")
    }

    /// Pulse the named item's badge and draw the persistent focus
    /// ring around its element. When `scrollIntoView` is true (panel-
    /// originated focus) the page also scrolls the element into view;
    /// for page-originated clicks the element is already under the
    /// user's cursor so we skip the scroll. `itemID` is the
    /// BatchInspectItem.id passed via `syncBatchMarkers`. Safe to
    /// call when the marker isn't on the page — JS no-ops.
    func highlightBatchMarker(tabID: UUID, itemID: UUID, scrollIntoView: Bool = true) {
        guard let webView = webViews[tabID] else { return }
        let scrollArg = scrollIntoView ? "true" : "false"
        let js = "window.__nexBatchHighlight && window.__nexBatchHighlight('\(itemID.uuidString)', \(scrollArg));"
        webView.evaluateJavaScript(js)
    }

    /// Handle a `nexBatchMarker` message — either a badge click or a
    /// popover textarea edit. Two envelopes:
    ///   `{ id }`                                — badge clicked
    ///   `{ commentChanged: { id, comment } }`   — popover textarea
    fileprivate func handleBatchMarkerMessage(tabID: UUID, body: Any, isMainFrame: Bool) {
        guard isMainFrame else { return }
        guard let dict = body as? [String: Any] else { return }

        // Envelope-typed branches first (more specific than the
        // bare `{ id }` badge-click form).
        if let edit = dict["commentChanged"] as? [String: Any],
           let idString = edit["id"] as? String,
           let itemID = UUID(uuidString: idString) {
            let comment = (edit["comment"] as? String) ?? ""
            NotificationCenter.default.post(
                name: Self.batchCommentEditedNotification,
                object: nil,
                userInfo: [
                    "paneID": paneID,
                    "tabID": tabID,
                    "itemID": itemID,
                    "comment": comment
                ]
            )
            return
        }
        if let dismiss = dict["dismiss"] as? [String: Any],
           let idString = dismiss["id"] as? String,
           let itemID = UUID(uuidString: idString) {
            NotificationCenter.default.post(
                name: Self.batchPopoverDismissedNotification,
                object: nil,
                userInfo: ["paneID": paneID, "tabID": tabID, "itemID": itemID]
            )
            return
        }
        if let remove = dict["remove"] as? [String: Any],
           let idString = remove["id"] as? String,
           let itemID = UUID(uuidString: idString) {
            NotificationCenter.default.post(
                name: Self.batchItemRemovedFromPopoverNotification,
                object: nil,
                userInfo: ["paneID": paneID, "tabID": tabID, "itemID": itemID]
            )
            return
        }

        guard let idString = dict["id"] as? String,
              let itemID = UUID(uuidString: idString) else { return }
        NotificationCenter.default.post(
            name: Self.batchMarkerClickedNotification,
            object: nil,
            userInfo: [
                "paneID": paneID,
                "tabID": tabID,
                "itemID": itemID
            ]
        )
    }
}

/// Bridge between WKScriptMessageHandler (which Cocoa retains
/// strongly) and `WebPaneCoordinator` (owned by `WebPaneStore`).
/// Holds a weak ref so the coordinator can deallocate when its pane
/// closes, even if WebKit hasn't torn down its content controller
/// yet.
@MainActor
private final class WebPaneScriptHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: WebPaneCoordinator?
    let tabID: UUID

    init(coordinator: WebPaneCoordinator, tabID: UUID) {
        self.coordinator = coordinator
        self.tabID = tabID
        super.init()
    }

    @preconcurrency
    nonisolated func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKScriptMessage's `name` / `body` / `frameInfo` became
        // `@MainActor`-isolated in the macOS 14+ WebKit SDK. WebKit
        // delivers this callback on the main thread, so we read +
        // dispatch inside `assumeIsolated` instead of round-tripping
        // through a Task (which would force `body: Any` across an
        // actor boundary it's not Sendable to cross).
        MainActor.assumeIsolated {
            guard let coord = coordinator else { return }
            let name = message.name
            let body = message.body
            let isMainFrame = message.frameInfo.isMainFrame
            switch name {
            case "nexConsole":
                coord.handleConsoleMessage(tabID: tabID, body: body)
            case "nexInspect":
                coord.handleInspectMessage(tabID: tabID, body: body, isMainFrame: isMainFrame)
            case "nexBatchMarker":
                coord.handleBatchMarkerMessage(tabID: tabID, body: body, isMainFrame: isMainFrame)
            default:
                break
            }
        }
    }
}

/// Sendable record passed to `syncBatchMarkers` from the reducer.
struct BatchMarkerInput: Equatable {
    let id: UUID
    let selector: String
    let label: String
    let comment: String
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
