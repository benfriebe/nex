import AppKit
import ComposableArchitecture
import SwiftUI
import WebKit

/// Renders the output of `git diff` in a WKWebView. Mirrors `MarkdownPaneView`
/// but without edit mode or file watching — refresh is triggered by pane focus
/// regaining and by external `refreshToken` bumps from the header refresh button.
struct DiffPaneView: NSViewRepresentable {
    let paneID: UUID
    let repoPath: String
    let targetPath: String?
    let isFocused: Bool
    let refreshToken: UInt64
    var backgroundColor: NSColor = .windowBackgroundColor
    var backgroundOpacity: Double = 1.0
    var fontSize: Double = 13
    @Environment(\.sidebarTextEditingActive) private var sidebarTextEditingActive

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PaneFocusView {
        let container = PaneFocusView(paneID: paneID)

        let config = WKWebViewConfiguration()
        let scrollHandler = context.coordinator
        config.userContentController.add(scrollHandler, name: "scrollHandler")
        config.userContentController.addUserScript(WKUserScript(
            source: """
            window.addEventListener('scroll', function() {
                var maxScroll = document.body.scrollHeight - window.innerHeight;
                var fraction = maxScroll > 0 ? window.scrollY / maxScroll : 0;
                window.webkit.messageHandlers.scrollHandler.postMessage(fraction);
            });
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator

        let coord = context.coordinator
        coord.webView = webView
        coord.paneID = paneID
        coord.pendingScrollFraction = PaneFocusView.scrollFraction(for: paneID)
        coord.repoPath = repoPath
        coord.targetPath = targetPath
        coord.backgroundColor = backgroundColor
        coord.backgroundOpacity = backgroundOpacity
        coord.fontSize = fontSize
        coord.lastRefreshToken = refreshToken
        coord.loadDiff()

        container.embed(webView)

        if isFocused, !sidebarTextEditingActive {
            claimFirstResponder(webView)
        }
        coord.lastIsFocused = isFocused
        return container
    }

    func updateNSView(_: PaneFocusView, context: Context) {
        let coord = context.coordinator
        let pathChanged = coord.repoPath != repoPath || coord.targetPath != targetPath
        let tokenBumped = coord.lastRefreshToken != refreshToken
        let focusGained = isFocused && !coord.lastIsFocused
        let fontChanged = coord.fontSize != fontSize

        coord.repoPath = repoPath
        coord.targetPath = targetPath
        coord.fontSize = fontSize
        coord.backgroundColor = backgroundColor
        coord.backgroundOpacity = backgroundOpacity

        if pathChanged || tokenBumped || focusGained {
            coord.lastRefreshToken = refreshToken
            coord.loadDiff()
        } else if fontChanged {
            coord.renderCurrent()
        }

        if isFocused, !coord.lastIsFocused, !sidebarTextEditingActive,
           let webView = coord.webView {
            claimFirstResponder(webView)
        }
        coord.lastIsFocused = isFocused
    }

    private func claimFirstResponder(_ webView: WKWebView) {
        DispatchQueue.main.async { [weak webView] in
            guard let webView, let window = webView.window else { return }
            if window.firstResponder === webView { return }
            window.makeFirstResponder(webView)
        }
    }

    static func dismantleNSView(_: PaneFocusView, coordinator: Coordinator) {
        coordinator.cancelInFlight()
        coordinator.webView = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Dependency(\.gitService) var gitService

        var webView: WKWebView?
        var paneID: UUID?
        var repoPath: String = ""
        var targetPath: String?
        var backgroundColor: NSColor = .windowBackgroundColor
        var backgroundOpacity: Double = 1.0
        var fontSize: Double = 13
        var lastIsFocused: Bool = false
        var lastRefreshToken: UInt64 = 0
        var pendingScrollFraction: CGFloat?

        private var currentDiffText: String = ""
        private var inFlightTask: Task<Void, Never>?

        func loadDiff() {
            guard !repoPath.isEmpty else { return }
            cancelInFlight()
            let repo = repoPath
            let target = targetPath
            inFlightTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let text: String
                do {
                    text = try await gitService.getDiff(repo, target)
                } catch {
                    text = "Failed to run git diff in \(repo):\n\(error.localizedDescription)"
                }
                guard !Task.isCancelled else { return }
                currentDiffText = text
                renderAndReload(text)
            }
        }

        func renderCurrent() {
            renderAndReload(currentDiffText)
        }

        func cancelInFlight() {
            inFlightTask?.cancel()
            inFlightTask = nil
        }

        private func renderAndReload(_ diffText: String) {
            let html = DiffHTMLRenderer.renderToHTML(
                diffText: diffText,
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity,
                baseFontSize: fontSize
            )
            webView?.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
                guard let self else { return }
                let scrollY = result as? Double ?? 0
                webView?.loadHTMLString(html, baseURL: nil)
                if scrollY > 0 {
                    pendingScrollFraction = nil
                    webView?.evaluateJavaScript("window.scrollTo(0, \(scrollY))")
                }
            }
        }

        // MARK: - WKScriptMessageHandler

        @preconcurrency
        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let fraction = message.body as? Double, let paneID else { return }
            PaneFocusView.saveScrollFraction(CGFloat(fraction), for: paneID)
        }

        // MARK: - WKNavigationDelegate

        @preconcurrency
        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            guard let paneID else { return }
            let fraction = pendingScrollFraction ?? PaneFocusView.scrollFraction(for: paneID)
            if let fraction, fraction > 0 {
                pendingScrollFraction = nil
                webView?.evaluateJavaScript(
                    "window.scrollTo(0, \(fraction) * Math.max(1, document.body.scrollHeight - window.innerHeight))"
                )
            }
        }

        @preconcurrency
        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // Right-click → Reload (and ⌘R) on a `loadHTMLString` page has no
            // source URL to reload from, which lands on about:blank. Map any
            // such reload back to our own re-fetch.
            if navigationAction.navigationType == .reload {
                decisionHandler(.cancel)
                loadDiff()
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
