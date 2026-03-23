import SwiftUI
import WebKit

/// Renders a markdown file in a WKWebView with live file watching.
struct MarkdownPaneView: NSViewRepresentable {
    let paneID: UUID
    let filePath: String
    let isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.filePath = filePath
        context.coordinator.loadFile()
        context.coordinator.startWatching()

        return webView
    }

    func updateNSView(_: WKWebView, context: Context) {
        if context.coordinator.filePath != filePath {
            context.coordinator.stopWatching()
            context.coordinator.filePath = filePath
            context.coordinator.loadFile()
            context.coordinator.startWatching()
        }
    }

    static func dismantleNSView(_: WKWebView, coordinator: Coordinator) {
        coordinator.stopWatching()
        coordinator.webView = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        var filePath: String = ""
        private var currentContent: String = ""
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

            let html = MarkdownRenderer.renderToHTML(content)
            let baseURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()

            // Save scroll position, reload, then restore
            webView?.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
                let scrollY = result as? Double ?? 0
                self?.webView?.loadHTMLString(html, baseURL: baseURL)
                if scrollY > 0 {
                    self?.webView?.evaluateJavaScript("window.scrollTo(0, \(scrollY))")
                }
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
