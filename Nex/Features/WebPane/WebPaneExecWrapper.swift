import Foundation

enum WebPaneExecWrapper {
    /// Two anchors that together catch statement bodies without firing
    /// on keywords inside strings, regex literals, or comments:
    ///   1. A keyword at the start of any line — covers multi-line
    ///      statement bodies (`await x();\nreturn y`).
    ///   2. A keyword immediately after `;` — covers one-line multi-
    ///      statement bodies like `await x(); return y` that CLI users
    ///      pass as a single quoted argument.
    /// Keyword-inside-string remains a false positive only for the
    /// rare `"...; return ..."` shape; everything else (`"if you..."`,
    /// `/return/.test(...)`, `// returns x`) stays expression mode.
    private static let statementKeywordRegex = try! NSRegularExpression(
        pattern: #"(?m)(?:^\s*|;\s*)(return|throw|if|for|while|switch|try|do|let|const|var)\b"#,
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
            // `return (expr;);` is a SyntaxError — strip a trailing `;`.
            let stripped = trimmed.hasSuffix(";")
                ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                : trimmed
            body = "return (\(stripped));"
        }
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
