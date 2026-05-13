import AppKit
import SwiftUI
import WebKit

/// `userInfo` keys for `MarkdownPaneView.copyRequestNotification`:
/// `paneID` (UUID) identifies the target pane and `kind`
/// (`MarkdownPaneView.CopyKind` raw value) selects markdown vs. rich.
enum MarkdownCopyKind: String {
    case markdown
    case richText
}

/// Renders a markdown file in a WKWebView with live file watching.
struct MarkdownPaneView: NSViewRepresentable {
    /// Posted by the pane header's Copy button to ask the matching
    /// Coordinator to write the file's contents to the pasteboard.
    /// userInfo: `{"paneID": UUID, "kind": MarkdownCopyKind.rawValue}`.
    static let copyRequestNotification = Notification.Name(
        "MarkdownPaneView.copyRequest"
    )

    let paneID: UUID
    let filePath: String
    let isFocused: Bool
    var backgroundColor: NSColor = .windowBackgroundColor
    var backgroundOpacity: Double = 1.0
    var fontSize: Double = Pane.defaultMarkdownFontSize
    @Environment(\.sidebarTextEditingActive) private var sidebarTextEditingActive

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PaneFocusView {
        let container = PaneFocusView(paneID: paneID)

        let config = WKWebViewConfiguration()
        let handler = context.coordinator
        config.userContentController.add(handler, name: "scrollHandler")
        config.userContentController.add(handler, name: "nexFind")
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
        config.userContentController.addUserScript(WKUserScript(
            source: MarkdownFindScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = MarkdownPreviewWebView(frame: .zero, configuration: config)
        webView.coordinator = context.coordinator
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
        context.coordinator.startObservingCopyRequests()
        MarkdownFindController.shared.register(paneID: paneID, coordinator: context.coordinator)

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
        coordinator.stopObservingCopyRequests()
        if let id = coordinator.paneID {
            MarkdownFindController.shared.unregister(paneID: id)
        }
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
        var fontSize: Double = Pane.defaultMarkdownFontSize
        var lastIsFocused: Bool = false
        private var currentContent: String = ""
        /// Tracks whether the last `loadFile` actually read the file. When
        /// false, `currentContent` is the synthetic "Failed to load…"
        /// blockquote and the copy actions should bail.
        private var didLoadSuccessfully: Bool = false
        /// Monotonic token: incremented before each render, checked after
        /// the async `window.scrollY` round-trip to drop stale reloads when
        /// the user holds Cmd+= / Cmd+- and multiple renders are in flight.
        private var renderToken: UInt64 = 0
        var pendingScrollFraction: CGFloat?
        nonisolated(unsafe) var fileWatcher: DispatchSourceFileSystemObject?
        nonisolated(unsafe) var fileDescriptor: Int32 = -1
        private var copyObserver: NSObjectProtocol?

        func loadFile() {
            guard !filePath.isEmpty else { return }

            let content: String
            let loaded: Bool
            do {
                content = try String(contentsOfFile: filePath, encoding: .utf8)
                loaded = true
            } catch {
                content = "> Failed to load file: \(filePath)\n>\n> \(error.localizedDescription)"
                loaded = false
            }

            // Set the load-success flag before the unchanged-content
            // guard so an initially-empty file (where content == "" ==
            // currentContent) is still marked loaded — otherwise the
            // copy actions would silently bail.
            didLoadSuccessfully = loaded
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
            guard let paneID else { return }
            switch message.name {
            case "scrollHandler":
                guard let fraction = message.body as? Double else { return }
                PaneFocusView.saveScrollFraction(CGFloat(fraction), for: paneID)
            case "nexFind":
                guard let payload = message.body as? [String: Any],
                      let total = payload["total"] as? Int,
                      let current = payload["current"] as? Int else { return }
                NotificationCenter.default.post(
                    name: .markdownFindResult,
                    object: nil,
                    userInfo: ["paneID": paneID, "total": total, "current": current]
                )
            default:
                break
            }
        }

        // MARK: - Find-in-page (called by MarkdownFindController)

        func runFindUpdate(needle: String) {
            guard let webView else { return }
            let escaped = MarkdownFindScript.encodeNeedle(needle)
            webView.evaluateJavaScript("window.__nexFind && window.__nexFind.search(\(escaped));")
        }

        func runFindNavigate(forward: Bool) {
            guard let webView else { return }
            let fn = forward ? "next" : "prev"
            webView.evaluateJavaScript("window.__nexFind && window.__nexFind.\(fn)();")
        }

        func runFindClose() {
            guard let webView else { return }
            webView.evaluateJavaScript("window.__nexFind && window.__nexFind.clear();")
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
            // The reload wiped any active find marks. Re-apply if a needle is still set.
            MarkdownFindController.shared.reapply(paneID: paneID)
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

        // MARK: - Copy request observer

        func startObservingCopyRequests() {
            copyObserver = NotificationCenter.default.addObserver(
                forName: MarkdownPaneView.copyRequestNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let target = note.userInfo?["paneID"] as? UUID,
                      target == paneID,
                      let raw = note.userInfo?["kind"] as? String,
                      let kind = MarkdownCopyKind(rawValue: raw)
                else { return }
                MainActor.assumeIsolated {
                    switch kind {
                    case .markdown:
                        self.copyAsMarkdown()
                    case .richText:
                        self.copyAsRichText()
                    }
                }
            }
        }

        func stopObservingCopyRequests() {
            if let copyObserver {
                NotificationCenter.default.removeObserver(copyObserver)
            }
            copyObserver = nil
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

        // MARK: - Copy actions

        /// Copy the whole document's source markdown (front-matter
        /// stripped) to the pasteboard. Selection-aware copy was
        /// abandoned — the block-level source map couldn't represent
        /// partial-block selections faithfully, and the resulting
        /// behaviour was inconsistent enough that the simpler
        /// whole-file contract is preferable.
        func copyAsMarkdown() {
            guard didLoadSuccessfully else { return }
            let body = FrontMatterExtractor.extract(currentContent).body
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(body, forType: .string)
        }

        /// Copy the whole rendered document as rich text. Front-matter
        /// is stripped (its table makes `NSAttributedString.rtf(from:)`
        /// return nil, which silently drops RTF from the pasteboard).
        ///
        /// Relative URLs in the rendered HTML (e.g. `src="diagram.png"`
        /// for an inline image alongside the markdown file) are
        /// resolved against the file's parent directory before the
        /// HTML→RTF import, so the resulting rich-text paste keeps
        /// working image and link references. Without this rewrite,
        /// AppKit's HTML importer treats relative paths as relative to
        /// nothing and the resources disappear in the paste target.
        func copyAsRichText() {
            guard didLoadSuccessfully else { return }
            let baseURL = filePath.isEmpty
                ? nil
                : URL(fileURLWithPath: filePath).deletingLastPathComponent()
            let js = """
            (function() {
                var content = document.getElementById('content');
                if (!content) { return document.body.innerHTML; }
                var clone = content.cloneNode(true);
                var fm = clone.querySelectorAll(
                    '.frontmatter, .frontmatter-raw, .frontmatter-nested'
                );
                for (var i = 0; i < fm.length; i++) {
                    fm[i].parentNode.removeChild(fm[i]);
                }
                return clone.innerHTML;
            })();
            """
            webView?.evaluateJavaScript(js) { result, _ in
                guard let html = result as? String, !html.isEmpty,
                      let data = html.data(using: .utf8) else { return }
                var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ]
                if let baseURL {
                    options[.baseURL] = baseURL
                }
                guard let attr = try? NSAttributedString(
                    data: data, options: options, documentAttributes: nil
                ) else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(attr.string, forType: .string)
                if let rtf = attr.rtf(from: NSRange(location: 0, length: attr.length)) {
                    pasteboard.setData(rtf, forType: .rtf)
                }
                pasteboard.setString(html, forType: .html)
            }
        }
    }
}

// MARK: - MarkdownPreviewWebView

/// `WKWebView` subclass that augments the macOS context menu with
/// "Copy as Markdown" and "Copy as Rich Text" entries at the top.
final class MarkdownPreviewWebView: WKWebView {
    weak var coordinator: MarkdownPaneView.Coordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // Defensive: WKWebView is expected to hand us a fresh menu per
        // invocation, but if the same NSMenu is ever reused across openings
        // we don't want our items duplicated on each right-click.
        if menu.item(withTitle: "Copy as Markdown") != nil { return }

        let copyMd = NSMenuItem(
            title: "Copy as Markdown",
            action: #selector(copyAsMarkdownAction(_:)),
            keyEquivalent: ""
        )
        copyMd.target = self

        let copyRtf = NSMenuItem(
            title: "Copy as Rich Text",
            action: #selector(copyAsRichTextAction(_:)),
            keyEquivalent: ""
        )
        copyRtf.target = self

        menu.insertItem(copyMd, at: 0)
        menu.insertItem(copyRtf, at: 1)
        menu.insertItem(NSMenuItem.separator(), at: 2)
    }

    @objc private func copyAsMarkdownAction(_: Any?) {
        coordinator?.copyAsMarkdown()
    }

    @objc private func copyAsRichTextAction(_: Any?) {
        coordinator?.copyAsRichText()
    }
}
