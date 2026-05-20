import Foundation
@testable import Nex
import Testing

/// Tests for `WebPaneExecWrapper.wrap` — the pure-Swift template that
/// turns author-supplied JS into the body passed to `callAsyncJavaScript`.
/// These are string-shape assertions, not behavioural tests; the
/// behavioural side (alias bindings actually resolve, the IIFE awaits
/// the inner Promise, etc.) is covered by the live JS-fixture tests
/// in WebPaneActuatorActionTests.
struct WebPaneExecWrapperTests {
    // MARK: - expression mode

    @Test func singleExpressionWrappedAsReturn() {
        let body = WebPaneExecWrapper.wrap("document.title")
        // Expression source has no `return` → wrapper inserts one.
        #expect(body.contains("return (document.title);"))
        #expect(body.contains("window.__nexAct.find.bind(window.__nexAct)"))
        #expect(body.contains("window.__nexAct.findAll.bind(window.__nexAct)"))
    }

    @Test func expressionWithTrailingSemicolonStripped() {
        // `return (expr;);` is a SyntaxError, so the wrapper must drop
        // a trailing semicolon when entering expression mode.
        let body = WebPaneExecWrapper.wrap("document.title;")
        #expect(body.contains("return (document.title);"))
        #expect(!body.contains("return (document.title;);"))
    }

    @Test func jQueryStyleExpression() {
        let body = WebPaneExecWrapper.wrap(#"$$("li.product").map(e => e.dataset.sku)"#)
        #expect(body.contains(#"return ($$("li.product").map(e => e.dataset.sku));"#))
    }

    // MARK: - statement mode

    @Test func sourceContainingReturnKeptAsStatementBody() {
        let source = """
        await nex.click("text:Add");
        return nex.text("[role=alert]").text;
        """
        let body = WebPaneExecWrapper.wrap(source)
        // Statement-mode keeps the body verbatim.
        #expect(body.contains(#"return nex.text("[role=alert]").text;"#))
        // No outer `return (...)` wrap.
        #expect(!body.contains(#"return (await nex.click"#))
    }

    @Test func multilineSourceWithoutReturnStillWrapsAsExpression() {
        // Author who writes a multi-line expression without `return`
        // is opting in to expression mode. The wrapper trusts the
        // heuristic — JS will report a SyntaxError at evaluation time
        // if the body isn't a valid single expression.
        let source = """
        $$("li")
            .map(e => e.textContent)
        """
        let body = WebPaneExecWrapper.wrap(source)
        #expect(body.contains("return ("))
        #expect(body.contains(#"$$("li")"#))
    }

    // MARK: - envelope structure

    @Test func wrapEmitsActuatorPresenceGuard() {
        let body = WebPaneExecWrapper.wrap("1 + 1")
        #expect(body.contains("if (!window.__nexAct)"))
        #expect(body.contains("'actuator not installed'"))
    }

    @Test func wrapCatchesAndStructuresJSExceptions() {
        let body = WebPaneExecWrapper.wrap("throwSomething()")
        // Verify the catch branch produces a structured error
        // envelope with the optional js_error fields the CLI displays.
        #expect(body.contains("catch (e)"))
        #expect(body.contains("js_error"))
        #expect(body.contains("lineNumber"))
        #expect(body.contains("columnNumber"))
    }

    @Test func wrapNormalisesUndefinedReturnToNull() {
        let body = WebPaneExecWrapper.wrap("void 0")
        #expect(body.contains("result === undefined ? null : result"))
    }

    @Test func wrapBindsThreeAliases() {
        let body = WebPaneExecWrapper.wrap("nex.find('css:body')")
        // The inner IIFE is an arrow function with ($, $$, nex) as
        // arguments, called with the matching actuator references.
        #expect(body.contains("async ($, $$, nex)"))
        #expect(body.contains("window.__nexAct.find.bind(window.__nexAct),"))
        #expect(body.contains("window.__nexAct.findAll.bind(window.__nexAct),"))
        #expect(body.contains("window.__nexAct"))
    }

    // MARK: - whitespace handling

    @Test func wrapTrimsLeadingAndTrailingWhitespace() {
        let body = WebPaneExecWrapper.wrap("   document.title   ")
        // Trimmed source is what's wrapped, so the literal indented
        // version of the source must not appear.
        #expect(body.contains("return (document.title);"))
        #expect(!body.contains("return (   document.title   );"))
    }
}
