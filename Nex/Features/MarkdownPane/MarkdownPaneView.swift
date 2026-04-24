import AppKit
import SwiftUI
import WebKit

/// Renders a markdown file in a WKWebView with live file watching.
struct MarkdownPaneView: NSViewRepresentable {
    let paneID: UUID
    let filePath: String
    let isFocused: Bool
    var backgroundColor: NSColor = .windowBackgroundColor
    var backgroundOpacity: Double = 1.0
    var fontSize: Double = 14
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

        context.coordinator.webView = webView
        context.coordinator.paneID = paneID
        context.coordinator.pendingScrollFraction = PaneFocusView.scrollFraction(for: paneID)
        context.coordinator.filePath = filePath
        context.coordinator.backgroundColor = backgroundColor
        context.coordinator.backgroundOpacity = backgroundOpacity
        context.coordinator.fontSize = fontSize
        context.coordinator.loadFile()
        context.coordinator.startWatching()

        container.embed(webView)

        if isFocused, !sidebarTextEditingActive {
            claimFirstResponder(webView)
        }
        context.coordinator.lastIsFocused = isFocused
        return container
    }

    func updateNSView(_: PaneFocusView, context: Context) {
        if context.coordinator.filePath != filePath {
            context.coordinator.stopWatching()
            context.coordinator.filePath = filePath
            context.coordinator.fontSize = fontSize
            context.coordinator.loadFile()
            context.coordinator.startWatching()
        } else if context.coordinator.fontSize != fontSize {
            context.coordinator.fontSize = fontSize
            context.coordinator.renderCurrentContent()
        }
        // Only claim on a real false→true transition so re-renders caused
        // by unrelated state changes (e.g., the user typing in the command
        // palette's TextField) don't yank first responder back.
        if isFocused, !context.coordinator.lastIsFocused, !sidebarTextEditingActive,
           let webView = context.coordinator.webView {
            claimFirstResponder(webView)
        }
        context.coordinator.lastIsFocused = isFocused
    }

    private func claimFirstResponder(_ webView: WKWebView) {
        DispatchQueue.main.async { [weak webView] in
            guard let webView, let window = webView.window else { return }
            if window.firstResponder === webView { return }
            window.makeFirstResponder(webView)
        }
    }

    static func dismantleNSView(_: PaneFocusView, coordinator: Coordinator) {
        coordinator.stopWatching()
        coordinator.webView = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var webView: WKWebView?
        var paneID: UUID?
        var filePath: String = ""
        var backgroundColor: NSColor = .windowBackgroundColor
        var backgroundOpacity: Double = 1.0
        var fontSize: Double = 14
        var lastIsFocused: Bool = false
        private var currentContent: String = ""
        /// Monotonic token: incremented before each render, checked after
        /// the async `window.scrollY` round-trip to drop stale reloads when
        /// the user holds Cmd+= / Cmd+- and multiple renders are in flight.
        private var renderToken: UInt64 = 0
        var pendingScrollFraction: CGFloat?
        nonisolated(unsafe) var fileWatcher: DispatchSourceFileSystemObject?
        nonisolated(unsafe) var fileDescriptor: Int32 = -1

        func loadFile() {
            guard !filePath.isEmpty else { return }

            let content: String
            do {
                content = try String(contentsOfFile: filePath, encoding: .utf8)
            } catch {
                content = "> Failed to load file: \(filePath)\n>\n> \(error.localizedDescription)"
            }

            guard content != currentContent else { return }
            currentContent = content
            renderAndReload(content: content)
        }

        /// Re-render the currently loaded content (e.g. after a font-size change)
        /// without touching disk.
        func renderCurrentContent() {
            guard !currentContent.isEmpty else { return }
            renderAndReload(content: currentContent)
        }

        private func renderAndReload(content: String) {
            renderToken &+= 1
            let token = renderToken
            let html = MarkdownRenderer.renderToHTML(
                content,
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity,
                baseFontSize: fontSize
            )
            let baseURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()

            // Save scroll position, reload, then restore. Drop the load if a
            // newer render has been requested in the meantime — otherwise a
            // stale callback from rapid Cmd+=/Cmd+- key repeat can overwrite
            // the current render.
            webView?.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
                guard let self, token == renderToken else { return }
                let scrollY = result as? Double ?? 0
                webView?.loadHTMLString(html, baseURL: baseURL)
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

        // MARK: - WKNavigationDelegate (scroll restore)

        @preconcurrency
        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            // Restore scroll fraction from shared store (e.g. after switching from edit mode)
            guard let paneID else { return }
            let fraction = pendingScrollFraction ?? PaneFocusView.scrollFraction(for: paneID)
            if let fraction, fraction > 0 {
                pendingScrollFraction = nil
                webView?.evaluateJavaScript(
                    "window.scrollTo(0, \(fraction) * Math.max(1, document.body.scrollHeight - window.innerHeight))"
                )
            }
        }

        func startWatching() {
            guard !filePath.isEmpty else { return }

            let fd = open(filePath, O_EVTONLY)
            guard fd >= 0 else { return }
            fileDescriptor = fd

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                let flags = source.data
                if flags.contains(.delete) || flags.contains(.rename) {
                    // File was deleted/renamed (vim-style save). Re-open after brief delay.
                    stopWatching()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.startWatching()
                        self?.loadFile()
                    }
                } else {
                    loadFile()
                }
            }

            source.setCancelHandler { [fd] in
                close(fd)
            }

            source.resume()
            fileWatcher = source
        }

        func stopWatching() {
            fileWatcher?.cancel()
            fileWatcher = nil
            fileDescriptor = -1
        }

        // MARK: - WKNavigationDelegate

        /// Intercept link clicks — open in default browser instead of navigating in-place.
        @preconcurrency
        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
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
