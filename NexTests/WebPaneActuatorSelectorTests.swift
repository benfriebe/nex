import Foundation
@testable import Nex
import Testing
import WebKit

/// Drives the JS-side selector parser inside a hidden WKWebView so the
/// rules in `WebPaneActuatorScript.source` are tested against a real
/// document tree. Tests cover all three prefix forms (css:, text:,
/// role:) plus auto-detect.
@MainActor
struct WebPaneActuatorSelectorTests {
    // MARK: - css:

    @Test func cssPrefixMatchesElement() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <button class="primary">Hello</button>
        <button class="secondary">World</button>
        """)
        let tag = try await host.eval("__nexAct.find('css:button.primary')?.textContent")
        #expect(tag as? String == "Hello")
    }

    @Test func cssPrefixFindAllReturnsAll() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <li>a</li><li>b</li><li>c</li>
        """)
        let count = try await host.eval("__nexAct.findAll('css:li').length")
        #expect(count as? Int == 3)
    }

    @Test func cssPrefixInvalidSelectorReturnsNull() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        let result = try await host.eval("__nexAct.find('css:???invalid???')")
        // Bad selectors are swallowed — agents get null rather than
        // a JS exception bubbling up.
        #expect(result is NSNull)
    }

    // MARK: - text:

    @Test func textPrefixExactMatch() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <div>Other text</div>
        <button>Add to order</button>
        """)
        let tag = try await host.eval("__nexAct.find('text:Add to order')?.tagName")
        #expect(tag as? String == "BUTTON")
    }

    @Test func textPrefixTrimsWhitespace() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <button>
            Submit
        </button>
        """)
        let tag = try await host.eval("__nexAct.find('text:Submit')?.tagName")
        #expect(tag as? String == "BUTTON")
    }

    @Test func textPrefixRegex() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <a href="#">Add to cart</a>
        """)
        let tag = try await host.eval(
            "__nexAct.find('text:/^Add to (cart|order)$/i')?.tagName"
        )
        #expect(tag as? String == "A")
    }

    @Test func textPrefixSkipsScriptAndStyleSubtrees() async throws {
        // textContent of <script> is "Add to order" but the actuator
        // must skip it (otherwise <script>$.fn.add = '...' kind of
        // pages get false positives).
        let host = try await ActuatorTestHost.make(html: """
        <script>var x = 'Add to order';</script>
        <p>Visible text</p>
        """)
        let result = try await host.eval("__nexAct.find('text:Add to order')")
        #expect(result is NSNull)
    }

    // MARK: - role:

    @Test func rolePrefixExplicitRole() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <div role="alert">Toast</div>
        """)
        let text = try await host.eval("__nexAct.find('role:alert')?.textContent")
        #expect(text as? String == "Toast")
    }

    @Test func rolePrefixImplicitButtonRole() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <button>Confirm</button>
        """)
        let text = try await host.eval("__nexAct.find('role:button')?.textContent")
        #expect(text as? String == "Confirm")
    }

    @Test func rolePrefixWithAccessibleName() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <button aria-label="Close dialog">X</button>
        <button>Confirm</button>
        """)
        let text = try await host.eval(
            "__nexAct.find('role:button:name=Close dialog')?.textContent"
        )
        #expect(text as? String == "X")
    }

    @Test func rolePrefixAccessibleNameMissDoesNotMatch() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <button aria-label="Confirm">OK</button>
        """)
        let result = try await host.eval(
            "__nexAct.find('role:button:name=Cancel')"
        )
        #expect(result is NSNull)
    }

    // MARK: - auto-detect (bare)

    @Test func bareDotRoutesToCSS() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <div class="foo">x</div>
        """)
        let tag = try await host.eval("__nexAct.find('.foo')?.tagName")
        #expect(tag as? String == "DIV")
    }

    @Test func bareHashRoutesToCSS() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <span id="lonely">y</span>
        """)
        let tag = try await host.eval("__nexAct.find('#lonely')?.tagName")
        #expect(tag as? String == "SPAN")
    }

    @Test func bareAttributeRoutesToCSS() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <div data-x="present">y</div>
        """)
        let tag = try await host.eval("__nexAct.find('[data-x]')?.tagName")
        #expect(tag as? String == "DIV")
    }

    @Test func bareWordRoutesToText() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <div>Other</div>
        <button>Add to order</button>
        """)
        let tag = try await host.eval("__nexAct.find('Add to order')?.tagName")
        #expect(tag as? String == "BUTTON")
    }

    // MARK: - implicit role allowlist (input[type])

    @Test func implicitRoleHiddenInputDoesNotMatchTextbox() async throws {
        // Regression: hidden CSRF inputs that precede a visible textbox
        // must not be returned for `role:textbox`.
        let host = try await ActuatorTestHost.make(html: """
        <form>
            <input type="hidden" name="csrf" value="abc">
            <input type="text" name="email">
        </form>
        """)
        let name = try await host.eval(
            "__nexAct.find('role:textbox')?.getAttribute('name')"
        )
        #expect(name as? String == "email")
    }

    @Test func implicitRolePasswordInputIsNotTextbox() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <input type="password" name="pw">
        """)
        let result = try await host.eval("__nexAct.find('role:textbox')")
        #expect(result is NSNull)
    }

    @Test func implicitRoleNumberInputIsSpinbutton() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <input type="number" name="qty">
        """)
        let tag = try await host.eval("__nexAct.find('role:spinbutton')?.tagName")
        #expect(tag as? String == "INPUT")
    }

    @Test func implicitRoleEmailInputIsTextbox() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <input type="email" name="email">
        """)
        let name = try await host.eval(
            "__nexAct.find('role:textbox')?.getAttribute('name')"
        )
        #expect(name as? String == "email")
    }

    // MARK: - text-regex with stateful flags (g / y)

    @Test func textRegexGlobalFlagFindsAllMatches() async throws {
        // Regression: with /g flag, RegExp.test() mutates lastIndex.
        // Reusing the same regex across tree-walker candidates skips
        // alternate matches. The actuator must reset lastIndex per call.
        let host = try await ActuatorTestHost.make(html: """
        <span>Item</span>
        <span>Item</span>
        <span>Item</span>
        <span>Item</span>
        """)
        let count = try await host.eval(
            "__nexAct.findAll('text:/^Item$/g').length"
        )
        #expect(count as? Int == 4)
    }

    @Test func textRegexStickyFlagFindsAllMatches() async throws {
        let host = try await ActuatorTestHost.make(html: """
        <span>X</span><span>X</span><span>X</span>
        """)
        let count = try await host.eval(
            "__nexAct.findAll('text:/^X$/y').length"
        )
        #expect(count as? Int == 3)
    }

    // MARK: - auto-detect with leading whitespace

    @Test func autoDetectIgnoresLeadingWhitespaceForCSSLead() async throws {
        // Leading whitespace before a CSS-leading char must still route
        // to CSS; otherwise '  .foo' silently becomes a text query for
        // the literal '  .foo' string.
        let host = try await ActuatorTestHost.make(html: """
        <div class="foo">hit</div>
        """)
        let text = try await host.eval("__nexAct.find('  .foo')?.textContent")
        #expect(text as? String == "hit")
    }

    @Test func autoDetectWhitespaceOnlyRejected() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        let kind = try await host.eval("__nexAct._parseSelector('   ').kind")
        #expect(kind as? String == "invalid")
    }

    // MARK: - parse-only diagnostics (parser surface)

    @Test func parseSelectorRejectsEmptyString() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        let kind = try await host.eval("__nexAct._parseSelector('').kind")
        #expect(kind as? String == "invalid")
    }

    @Test func parseSelectorTextRegexBadPatternReportsInvalid() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        // Unterminated quantifier — invalid regex, must surface as
        // 'invalid' not a thrown exception.
        let kind = try await host.eval("__nexAct._parseSelector('text:/(/').kind")
        #expect(kind as? String == "invalid")
    }

    // MARK: - idempotency

    @Test func reinjectionLeavesNamespaceUntouched() async throws {
        let host = try await ActuatorTestHost.make(html: "<div></div>")
        // Stamp the namespace, manually re-run the script, verify the
        // stamp survives (idempotency guard prevents clobber).
        _ = try await host.eval("window.__nexAct.__stamp = 42")
        // Manually re-run the script body (replicates a navigation
        // that triggers document-start injection a second time).
        _ = try await host.eval(WebPaneActuatorScript.source)
        let stamp = try await host.eval("window.__nexAct.__stamp")
        #expect(stamp as? Int == 42)
    }
}

// MARK: - test host

/// Hidden WKWebView preloaded with `WebPaneActuatorScript` as a
/// document-start user script. Tests load HTML via `loadHTMLString`,
/// wait for navigation completion, then run JS against the resulting
/// document.
@MainActor
private final class ActuatorTestHost: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var didFinish: CheckedContinuation<Void, Error>?

    static func make(html: String) async throws -> ActuatorTestHost {
        let host = ActuatorTestHost()
        try await host.load(html: html)
        return host
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: WebPaneActuatorScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            didFinish = cc
            webView.loadHTMLString(
                "<!doctype html><html><body>\(html)</body></html>",
                baseURL: nil
            )
        }
    }

    func eval(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    nonisolated func webView(
        _: WKWebView,
        didFinish _: WKNavigation!
    ) {
        Task { @MainActor in
            self.didFinish?.resume()
            self.didFinish = nil
        }
    }

    nonisolated func webView(
        _: WKWebView,
        didFail _: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.didFinish?.resume(throwing: error)
            self.didFinish = nil
        }
    }

    nonisolated func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.didFinish?.resume(throwing: error)
            self.didFinish = nil
        }
    }
}
