import Foundation

/// Builds the JS body that `nex web exec` evaluates via
/// `WKWebView.callAsyncJavaScript`. The author writes plain JS; the
/// wrapper handles three jobs:
///
/// 1. **Alias bindings** — `$` / `$$` / `nex` are bound to
///    `__nexAct.find` / `__nexAct.findAll` / `__nexAct` so author
///    scripts stay terse: `$$("li.product").map(...)`,
///    `await nex.click("text:Confirm")`.
/// 2. **Async wrapper** — the author body lives inside an
///    `async ($, $$, nex) => { ... }` IIFE so `await` works
///    naturally for both actuator methods (Promise-returning) and
///    direct `fetch(...)` calls.
/// 3. **Implicit return** — a single trailing expression returns its
///    value without ceremony (`nex web exec 'document.title'`). The
///    presence of a `return` keyword switches the wrapper into
///    statement-body mode, where the author is responsible for
///    explicitly returning the result.
///
/// Reply envelope matches the actuator verbs:
///   `{ok: true, result: <json>}` on success
///   `{ok: false, error: <message>, js_error: {name, message, line, column}}`
/// on a page-side exception. `result === undefined` is normalised to
/// `null` so the JSON envelope is always well-formed.
enum WebPaneExecWrapper {
    /// Word-boundary detector for keywords that can only appear inside
    /// a statement body — `return` and `throw` are the load-bearing
    /// ones; the rest catch the obvious cases where wrapping as
    /// `return (source)` would produce a SyntaxError. Presence of any
    /// of these switches the wrapper into statement-body mode.
    ///
    /// False positives (nested function bodies, regex literals
    /// containing one of these words) are harmless — the author just
    /// needs an explicit top-level `return` if they want a value
    /// surfaced, which is what they'd write anyway.
    private static let statementKeywordRegex = try! NSRegularExpression(
        pattern: #"\b(return|throw|if|for|while|switch|try|do|let|const|var)\b"#,
        options: []
    )

    static func wrap(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let isStatementBody = statementKeywordRegex.firstMatch(
            in: trimmed, range: range
        ) != nil
        if isStatementBody {
            body = trimmed
        } else {
            // Expression mode: `return (X);` is valid JS; strip a
            // trailing `;` from the author's source so the wrap
            // doesn't produce `return (expr;)` (a SyntaxError).
            let stripped = trimmed.hasSuffix(";")
                ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                : trimmed
            body = "return (\(stripped));"
        }
        // The outer body runs inside `async function() { ... }`
        // courtesy of `callAsyncJavaScript`. We:
        //   * guard against a missing actuator (idempotent reinjection
        //     should have ensured it's present, but a freshly loaded
        //     iframe / about:blank tab may not have it),
        //   * await the inner IIFE so Promises resolve before we
        //     serialise,
        //   * JSON-stringify the envelope on the JS side so the Swift
        //     receiver always gets a String (matches the actuator-verb
        //     wrapper).
        //
        // The inner IIFE is an arrow function so the author body
        // doesn't accidentally rebind `this` to something surprising.
        return """
        if (!window.__nexAct) {
            return JSON.stringify({ok: false, error: 'actuator not installed'});
        }
        try {
            var result = await (async ($, $$, nex) => {
                \(body)
            })(
                window.__nexAct.find.bind(window.__nexAct),
                window.__nexAct.findAll.bind(window.__nexAct),
                window.__nexAct
            );
            return JSON.stringify({
                ok: true,
                result: result === undefined ? null : result
            });
        } catch (e) {
            return JSON.stringify({
                ok: false,
                error: (e && e.message) ? e.message : String(e),
                js_error: e ? {
                    name: e.name || 'Error',
                    message: e.message || String(e),
                    line: e.lineNumber || null,
                    column: e.columnNumber || null
                } : null
            });
        }
        """
    }
}
