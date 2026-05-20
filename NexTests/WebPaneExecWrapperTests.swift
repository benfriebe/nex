import Foundation
@testable import Nex
import Testing

struct WebPaneExecWrapperTests {
    // MARK: - expression mode

    @Test func singleExpressionWrappedAsReturn() {
        let body = WebPaneExecWrapper.wrap("document.title")
        #expect(body.contains("return (document.title);"))
        #expect(body.contains("window.__nexAct.find.bind(window.__nexAct)"))
        #expect(body.contains("window.__nexAct.findAll.bind(window.__nexAct)"))
    }

    @Test func expressionWithTrailingSemicolonStripped() {
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
        #expect(body.contains(#"return nex.text("[role=alert]").text;"#))
        #expect(!body.contains(#"return (await nex.click"#))
    }

    @Test func multilineSourceWithoutReturnStillWrapsAsExpression() {
        let source = """
        $$("li")
            .map(e => e.textContent)
        """
        let body = WebPaneExecWrapper.wrap(source)
        #expect(body.contains("return ("))
        #expect(body.contains(#"$$("li")"#))
    }

    @Test func oneLineSemicolonDelimitedStatementsKeptAsStatementBody() {
        let body = WebPaneExecWrapper.wrap(#"await nex.click("text:Add"); return document.title"#)
        #expect(body.contains(#"await nex.click("text:Add"); return document.title"#))
        #expect(!body.contains(#"return (await nex.click"#))
    }

    @Test func oneLineDeclarationThenReturnKeptAsStatementBody() {
        let body = WebPaneExecWrapper.wrap("const t = document.title; return t.toUpperCase()")
        #expect(body.contains("const t = document.title; return t.toUpperCase()"))
        #expect(!body.contains("return (const"))
    }

    @Test func oneLineThrowAfterSemicolonKeptAsStatementBody() {
        let body = WebPaneExecWrapper.wrap(#"await nex.click("x"); throw new Error("done")"#)
        #expect(body.contains(#"await nex.click("x"); throw new Error("done")"#))
        #expect(!body.contains(#"return (await nex.click"#))
    }

    /// Keywords inside string literals must not flip the wrapper to
    /// statement mode — the author wrote an expression, the value would
    /// be silently discarded.
    @Test func keywordInStringLiteralStaysExpression() {
        let body = WebPaneExecWrapper.wrap(#""if you continue, return now""#)
        #expect(body.contains(#"return ("if you continue, return now");"#))
    }

    @Test func keywordInTrailingCommentStaysExpression() {
        let body = WebPaneExecWrapper.wrap("document.title // returns the page title")
        #expect(body.contains("return (document.title"))
    }

    @Test func keywordAsArgumentInsideMethodCallStaysExpression() {
        let body = WebPaneExecWrapper.wrap(#"document.body.textContent.includes("try again")"#)
        #expect(body.contains(#"return (document.body.textContent.includes("try again"));"#))
    }

    @Test func keywordInsideRegexLiteralStaysExpression() {
        let body = WebPaneExecWrapper.wrap("/return/.test(text)")
        #expect(body.contains("return (/return/.test(text));"))
    }

    // MARK: - envelope structure

    @Test func wrapEmitsActuatorPresenceGuard() {
        let body = WebPaneExecWrapper.wrap("1 + 1")
        #expect(body.contains("if (!window.__nexAct)"))
        #expect(body.contains("'actuator not installed'"))
    }

    @Test func wrapCatchesAndStructuresJSExceptions() {
        let body = WebPaneExecWrapper.wrap("throwSomething()")
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
        #expect(body.contains("async ($, $$, nex)"))
        #expect(body.contains("window.__nexAct.find.bind(window.__nexAct),"))
        #expect(body.contains("window.__nexAct.findAll.bind(window.__nexAct),"))
        #expect(body.contains("window.__nexAct"))
    }

    // MARK: - whitespace handling

    @Test func wrapTrimsLeadingAndTrailingWhitespace() {
        let body = WebPaneExecWrapper.wrap("   document.title   ")
        #expect(body.contains("return (document.title);"))
        #expect(!body.contains("return (   document.title   );"))
    }
}
