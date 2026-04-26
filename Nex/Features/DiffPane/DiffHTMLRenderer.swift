import AppKit
import Foundation

/// Renders raw `git diff` output into a styled HTML document. Mirrors the
/// background-color and dark-mode pattern used by `MarkdownHTMLRenderer`
/// so diff panes blend with surrounding terminal panes.
enum DiffHTMLRenderer {
    static func renderToHTML(
        diffText: String,
        backgroundColor: NSColor = .windowBackgroundColor,
        backgroundOpacity: Double = 1.0,
        baseFontSize: Double = 13
    ) -> String {
        let bgCSS = cssBackground(color: backgroundColor, opacity: backgroundOpacity)
        let isDark = isDarkBackground(color: backgroundColor)
        let body: String = if diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "<div class=\"empty\">No changes</div>"
        } else {
            renderLines(diffText)
        }
        return wrapInHTMLDocument(
            body,
            backgroundCSS: bgCSS,
            isDark: isDark,
            baseFontSize: baseFontSize
        )
    }

    // MARK: - Line classification

    private static func renderLines(_ diff: String) -> String {
        let chunks = splitIntoFileChunks(diff)
        var html = "<div class=\"diff\">"
        for chunk in chunks {
            html += renderChunk(chunk)
        }
        html += "</div>"
        return html
    }

    /// A run of lines belonging to a single file (or the leading preamble
    /// before any `diff --git` line). `headerLine` is `nil` for the preamble.
    private struct FileChunk {
        var headerLine: String?
        var lines: [String]
    }

    private static func splitIntoFileChunks(_ diff: String) -> [FileChunk] {
        var chunks: [FileChunk] = []
        var current = FileChunk(headerLine: nil, lines: [])
        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                if !current.lines.isEmpty || current.headerLine != nil {
                    chunks.append(current)
                }
                current = FileChunk(headerLine: line, lines: [line])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.isEmpty || current.headerLine != nil {
            chunks.append(current)
        }
        return chunks
    }

    private static func renderChunk(_ chunk: FileChunk) -> String {
        // No `diff --git` header: render lines loose (no <details>).
        guard chunk.headerLine != nil else {
            return chunk.lines
                .map { "<div class=\"line line-\(classify($0))\">\(escape($0))</div>" }
                .joined()
        }

        let status = detectStatus(chunk)
        let counts = countChanges(chunk)
        let path = displayPath(for: chunk, status: status)

        var html = "<details class=\"file\" open>"
        html += "<summary class=\"file-summary\">"
        html += "<span class=\"caret\"></span>"
        html += "<span class=\"file-path\">\(escape(path))</span>"
        html += "<span class=\"file-status status-\(status.cssClass)\">\(status.label)</span>"
        if counts.additions > 0 || counts.deletions > 0 {
            html += "<span class=\"diff-stats\">"
            html += "<span class=\"stat-add\">+\(counts.additions)</span>"
            html += "<span class=\"stat-del\">-\(counts.deletions)</span>"
            html += "</span>"
        }
        html += "</summary>"
        // Per-file horizontal scroll: `.hunks` clips, `.hunks-inner` sizes to
        // widest line so backgrounds extend across the full diff width while
        // the outer summary stays pinned at viewport width.
        html += "<div class=\"hunks\"><div class=\"hunks-inner\">"
        for line in chunk.lines {
            html += "<div class=\"line line-\(classify(line))\">\(escape(line))</div>"
        }
        html += "</div></div>"
        html += "</details>"
        return html
    }

    // MARK: - Per-file derivation

    private enum FileStatus {
        case added
        case deleted
        case modified
        case renamed(from: String)
        case binary
        case modeChange

        var label: String {
            switch self {
            case .added: "added"
            case .deleted: "deleted"
            case .modified: "modified"
            case .renamed: "renamed"
            case .binary: "binary"
            case .modeChange: "mode"
            }
        }

        var cssClass: String {
            switch self {
            case .added: "added"
            case .deleted: "deleted"
            case .modified: "modified"
            case .renamed: "renamed"
            case .binary: "binary"
            case .modeChange: "mode"
            }
        }
    }

    private static func detectStatus(_ chunk: FileChunk) -> FileStatus {
        var hasNewFileMode = false
        var hasDeletedFileMode = false
        var renameFrom: String?
        var hasRenameTo = false
        var hasBinary = false
        var hasContentChange = false
        var hasModeChange = false

        for line in chunk.lines {
            if line.hasPrefix("new file mode") { hasNewFileMode = true }
            if line.hasPrefix("deleted file mode") { hasDeletedFileMode = true }
            if line.hasPrefix("rename from ") {
                renameFrom = String(line.dropFirst("rename from ".count))
            }
            if line.hasPrefix("rename to ") { hasRenameTo = true }
            if line.hasPrefix("Binary files") { hasBinary = true }
            if line.hasPrefix("old mode") || line.hasPrefix("new mode") { hasModeChange = true }
            if line.hasPrefix("@@") { hasContentChange = true }
        }

        // Content change wins over mode-only changes, so a chmod+edit shows as modified.
        if hasNewFileMode { return .added }
        if hasDeletedFileMode { return .deleted }
        if let from = renameFrom, hasRenameTo { return .renamed(from: from) }
        if hasBinary { return .binary }
        if hasModeChange, !hasContentChange { return .modeChange }
        return .modified
    }

    private static func countChanges(_ chunk: FileChunk) -> (additions: Int, deletions: Int) {
        var add = 0
        var del = 0
        for line in chunk.lines {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { add += 1 }
            if line.hasPrefix("-") { del += 1 }
        }
        return (add, del)
    }

    private static func displayPath(for chunk: FileChunk, status: FileStatus) -> String {
        let dest = extractFilePath(from: chunk.headerLine ?? "")
        if case .renamed(let from) = status {
            return "\(from) → \(dest)"
        }
        return dest
    }

    /// Extract the destination path from a `diff --git a/<path> b/<path>` line.
    /// Uses the last " b/" occurrence so paths with spaces or unusual prefixes
    /// still work for the common case.
    private static func extractFilePath(from diffGitLine: String) -> String {
        if let bRange = diffGitLine.range(of: " b/", options: .backwards) {
            return String(diffGitLine[bRange.upperBound...])
        }
        return diffGitLine
    }

    private static func classify(_ line: String) -> String {
        // File-header markers must be checked before +/- because of +++/---.
        if line.hasPrefix("diff --git ") ||
            line.hasPrefix("index ") ||
            line.hasPrefix("--- ") ||
            line.hasPrefix("+++ ") ||
            line.hasPrefix("new file mode") ||
            line.hasPrefix("deleted file mode") ||
            line.hasPrefix("similarity index") ||
            line.hasPrefix("rename ") ||
            line.hasPrefix("copy ") ||
            line.hasPrefix("Binary files") ||
            line.hasPrefix("old mode") ||
            line.hasPrefix("new mode") {
            return "file-header"
        }
        if line.hasPrefix("@@") {
            return "hunk"
        }
        if line.hasPrefix("+") {
            return "add"
        }
        if line.hasPrefix("-") {
            return "del"
        }
        return "context"
    }

    // MARK: - Background detection (mirrors MarkdownHTMLRenderer)

    private static func isDarkBackground(color: NSColor) -> Bool {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance < 0.5
    }

    private static func cssBackground(color: NSColor, opacity: Double) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return "background-color: rgba(\(r), \(g), \(b), \(opacity));"
    }

    private static func wrapInHTMLDocument(
        _ body: String,
        backgroundCSS: String,
        isDark: Bool,
        baseFontSize: Double
    ) -> String {
        """
        <!DOCTYPE html>
        <html class="\(isDark ? "dark" : "light")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(css(backgroundCSS: backgroundCSS, baseFontSize: baseFontSize))
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Stylesheet

    private static func css(backgroundCSS: String, baseFontSize: Double) -> String {
        """
        html, body {
            margin: 0;
            padding: 0;
        }
        body {
            font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
            font-size: \(baseFontSize)px;
            line-height: 1.45;
            color: #1f2328;
            \(backgroundCSS)
            overflow-y: auto;
            overflow-x: hidden;
        }
        .dark body { color: #e6edf3; }
        .diff {
            padding-bottom: 8px;
        }
        details.file { display: block; }
        .hunks {
            overflow-x: auto;
        }
        .hunks-inner {
            display: inline-block;
            min-width: 100%;
        }
        details.file > summary {
            position: sticky;
            top: 0;
            z-index: 2;
            list-style: none;
            cursor: pointer;
            user-select: none;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-weight: 600;
            color: #1f2328;
            background: #f6f8fa;
            border-top: 1px solid #d1d9e0;
            border-bottom: 1px solid #d1d9e0;
            padding: 6px 16px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        details.file > summary::-webkit-details-marker { display: none; }
        details.file:first-child > summary { border-top: none; }
        .dark details.file > summary {
            background: #161b22;
            color: #e6edf3;
            border-top-color: #3d444d;
            border-bottom-color: #3d444d;
        }
        .caret {
            display: inline-block;
            width: 10px;
            color: #8b949e;
            transition: transform 0.12s ease;
        }
        .caret::before { content: "\\25B6"; font-size: 9px; }
        details[open] > summary .caret { transform: rotate(90deg); }
        .file-path {
            font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
            font-weight: 500;
        }
        .file-status {
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 10px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.04em;
            padding: 1px 6px;
            border-radius: 3px;
        }
        .status-added { background: rgba(46, 160, 67, 0.18); color: #1a7f37; }
        .dark .status-added { color: #4ac26b; background: rgba(46, 160, 67, 0.22); }
        .status-deleted { background: rgba(248, 81, 73, 0.18); color: #cf222e; }
        .dark .status-deleted { color: #ff7b72; background: rgba(248, 81, 73, 0.22); }
        .status-modified { background: rgba(56, 139, 253, 0.18); color: #0969da; }
        .dark .status-modified { color: #58a6ff; background: rgba(56, 139, 253, 0.22); }
        .status-renamed { background: rgba(163, 113, 247, 0.18); color: #8250df; }
        .dark .status-renamed { color: #d2a8ff; background: rgba(163, 113, 247, 0.22); }
        .status-binary, .status-mode {
            background: rgba(101, 109, 118, 0.18);
            color: #57606a;
        }
        .dark .status-binary, .dark .status-mode {
            color: #8b949e;
            background: rgba(139, 148, 158, 0.18);
        }
        .diff-stats {
            margin-left: auto;
            font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 12px;
            display: inline-flex;
            gap: 8px;
        }
        .stat-add { color: #1a7f37; font-weight: 600; }
        .dark .stat-add { color: #4ac26b; }
        .stat-del { color: #cf222e; font-weight: 600; }
        .dark .stat-del { color: #ff7b72; }
        .line {
            display: block;
            padding: 0 16px;
            white-space: pre;
        }
        .line:empty::before { content: "\\00a0"; }
        .line-add {
            background: #e6ffec;
            color: #1a7f37;
        }
        .dark .line-add {
            background: rgba(46, 160, 67, 0.15);
            color: #4ac26b;
        }
        .line-del {
            background: #ffebe9;
            color: #cf222e;
        }
        .dark .line-del {
            background: rgba(248, 81, 73, 0.15);
            color: #ff7b72;
        }
        .line-hunk {
            background: #ddf4ff;
            color: #57606a;
        }
        .dark .line-hunk {
            background: rgba(56, 139, 253, 0.15);
            color: #8b949e;
        }
        .line-file-header {
            color: #57606a;
            font-size: 0.92em;
            padding-top: 2px;
            padding-bottom: 2px;
        }
        .dark .line-file-header { color: #8b949e; }
        .empty {
            text-align: center;
            color: #57606a;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: 14px;
            padding: 80px 20px;
        }
        .dark .empty { color: #8b949e; }
        """
    }

    // MARK: - HTML escaping

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
