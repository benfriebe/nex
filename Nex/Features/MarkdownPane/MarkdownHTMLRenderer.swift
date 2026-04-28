import AppKit
import Foundation
import Markdown

/// Converts a swift-markdown AST into HTML.
struct MarkdownHTMLRenderer: MarkupVisitor {
    typealias Result = String

    private static let urlDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Only auto-link matches whose source text starts with one of these
    /// schemes. NSDataDetector also matches schemeless domains like
    /// `example.com` and bare emails like `foo@example.com`, which we
    /// deliberately leave as plain text — terminal-style "make pasted
    /// URLs clickable" behaviour, not GitHub-style fuzzy linkification.
    private static let allowedSchemePrefixes: [String] = [
        "http://", "https://", "ftp://", "file://", "mailto:"
    ]

    private var isInTableHead = false
    private var skipAutolinkDepth = 0

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined()
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let content = heading.children.map { visit($0) }.joined()
        return "<h\(heading.level)>\(content)</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let content = paragraph.children.map { visit($0) }.joined()
        return "<p>\(content)</p>\n"
    }

    mutating func visitText(_ text: Text) -> String {
        if skipAutolinkDepth > 0 {
            return escapeHTML(text.string)
        }
        return autolinkText(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        let content = emphasis.children.map { visit($0) }.joined()
        return "<em>\(content)</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        let content = strong.children.map { visit($0) }.joined()
        return "<strong>\(content)</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        let content = strikethrough.children.map { visit($0) }.joined()
        return "<del>\(content)</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(escapeHTML(inlineCode.code))</code>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = codeBlock.language ?? ""
        let langAttr = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
        let code = escapeHTML(codeBlock.code)
        return "<pre><code\(langAttr)>\(code)</code></pre>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        let items = list.children.map { visit($0) }.joined()
        return "<ul>\n\(items)</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let start = list.startIndex
        let startAttr = start != 1 ? " start=\"\(start)\"" : ""
        let items = list.children.map { visit($0) }.joined()
        return "<ol\(startAttr)>\n\(items)</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        let content = item.children.map { visit($0) }.joined()
        if let checkbox = item.checkbox {
            let checked = checkbox == .checked ? " checked disabled" : " disabled"
            return "<li><input type=\"checkbox\"\(checked)> \(content)</li>\n"
        }
        return "<li>\(content)</li>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        skipAutolinkDepth += 1
        let content = link.children.map { visit($0) }.joined()
        skipAutolinkDepth -= 1
        let dest = escapeHTML(link.destination ?? "")
        return "<a href=\"\(dest)\">\(content)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        skipAutolinkDepth += 1
        let alt = image.children.map { visit($0) }.joined()
        skipAutolinkDepth -= 1
        let src = escapeHTML(image.source ?? "")
        let titleAttr = image.title.map { " title=\"\(escapeHTML($0))\"" } ?? ""
        return "<img src=\"\(src)\" alt=\"\(alt)\"\(titleAttr)>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        let content = blockQuote.children.map { visit($0) }.joined()
        return "<blockquote>\n\(content)</blockquote>\n"
    }

    mutating func visitThematicBreak(_: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitSoftBreak(_: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        html.rawHTML
    }

    // MARK: - GFM Tables

    mutating func visitTable(_ table: Table) -> String {
        let content = table.children.map { visit($0) }.joined()
        return "<table>\n\(content)</table>\n"
    }

    mutating func visitTableHead(_ head: Table.Head) -> String {
        isInTableHead = true
        let content = head.children.map { visit($0) }.joined()
        isInTableHead = false
        return "<thead>\n\(content)</thead>\n"
    }

    mutating func visitTableBody(_ body: Table.Body) -> String {
        let content = body.children.map { visit($0) }.joined()
        return "<tbody>\n\(content)</tbody>\n"
    }

    mutating func visitTableRow(_ row: Table.Row) -> String {
        let content = row.children.map { visit($0) }.joined()
        return "<tr>\(content)</tr>\n"
    }

    mutating func visitTableCell(_ cell: Table.Cell) -> String {
        let content = cell.children.map { visit($0) }.joined()
        let tag = isInTableHead ? "th" : "td"
        return "<\(tag)>\(content)</\(tag)>"
    }

    // MARK: - Helpers

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Wrap any URLs detected in plain text with `<a>` tags so bare links
    /// (e.g. `https://example.com`) are clickable, matching terminal behaviour.
    /// swift-markdown only auto-detects `<>`-wrapped URLs and `[text](url)`
    /// syntax — bare URLs in text reach us as plain `Text` nodes.
    private func autolinkText(_ text: String) -> String {
        guard let detector = Self.urlDetector else {
            return escapeHTML(text)
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return escapeHTML(text)
        }
        var result = ""
        var cursor = 0
        for match in matches {
            let urlText = nsText.substring(with: match.range)
            let lower = urlText.lowercased()
            let hasAllowedScheme = Self.allowedSchemePrefixes.contains(where: lower.hasPrefix)
            // Skip schemeless domains and bare emails — let them render as
            // plain text so they fall through into the surrounding escape.
            guard hasAllowedScheme else { continue }
            if match.range.location > cursor {
                let preLen = match.range.location - cursor
                result += escapeHTML(nsText.substring(with: NSRange(location: cursor, length: preLen)))
            }
            let href = match.url?.absoluteString ?? urlText
            result += "<a href=\"\(escapeHTML(href))\">\(escapeHTML(urlText))</a>"
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tailLen = nsText.length - cursor
            result += escapeHTML(nsText.substring(with: NSRange(location: cursor, length: tailLen)))
        }
        return result
    }
}

// MARK: - Public API

enum MarkdownRenderer {
    /// Parse markdown text and return a full HTML document string.
    static func renderToHTML(
        _ markdown: String,
        backgroundColor: NSColor = .windowBackgroundColor,
        backgroundOpacity: Double = 1.0,
        baseFontSize: Double = 14
    ) -> String {
        let (yaml, body) = FrontMatterExtractor.extract(markdown)
        let document = Document(parsing: body)
        var visitor = MarkdownHTMLRenderer()
        let bodyHTML = visitor.visit(document)
        let fmHTML = yaml.map(FrontMatterRenderer.render) ?? ""
        let bgCSS = cssBackground(color: backgroundColor, opacity: backgroundOpacity)
        let isDark = isDarkBackground(color: backgroundColor)
        return wrapInHTMLDocument(
            fmHTML + bodyHTML,
            backgroundCSS: bgCSS,
            isDark: isDark,
            baseFontSize: baseFontSize
        )
    }

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
        <div id="content">
        \(body)
        </div>
        </body>
        </html>
        """
    }

    // MARK: - Stylesheet

    private static func css(backgroundCSS: String, baseFontSize: Double) -> String {
        let codeFontSize = max(baseFontSize - 1, 6)
        return """
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            font-size: \(baseFontSize)px;
            line-height: 1.6;
            padding: 20px 28px;
            margin: 0;
            color: #1f2328;
            \(backgroundCSS)
        }
        .dark body { color: #e6edf3; }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 1.5em;
            margin-bottom: 0.5em;
            font-weight: 600;
        }
        h1 { font-size: 2em; border-bottom: 1px solid #d1d9e0; padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid #d1d9e0; padding-bottom: 0.3em; }
        h3 { font-size: 1.25em; }
        .dark h1, .dark h2 { border-bottom-color: #3d444d; }
        p { margin: 0.5em 0 1em; }
        a { color: #0969da; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .dark a { color: #58a6ff; }
        pre {
            background: #f6f8fa;
            padding: 16px;
            border-radius: 6px;
            overflow-x: auto;
            font-size: \(codeFontSize)px;
            line-height: 1.45;
        }
        .dark pre { background: #161b22; }
        code {
            font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 0.9em;
        }
        :not(pre) > code {
            background: #eff1f3;
            padding: 2px 6px;
            border-radius: 4px;
        }
        .dark :not(pre) > code { background: #262c36; }
        blockquote {
            border-left: 4px solid #d1d9e0;
            padding: 0 16px;
            color: #656d76;
            margin: 0.5em 0 1em;
        }
        .dark blockquote { border-left-color: #3d444d; color: #9198a1; }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 0.5em 0 1em;
        }
        th, td {
            border: 1px solid #d1d9e0;
            padding: 8px 12px;
            text-align: left;
        }
        th { font-weight: 600; background: #f6f8fa; }
        .dark th, .dark td { border-color: #3d444d; }
        .dark th { background: #161b22; }
        ul, ol { padding-left: 2em; margin: 0.5em 0; }
        li { margin: 0.25em 0; }
        li > input[type="checkbox"] { margin-right: 0.5em; }
        hr {
            border: none;
            border-top: 1px solid #d1d9e0;
            margin: 2em 0;
        }
        .dark hr { border-top-color: #3d444d; }
        img { max-width: 100%; border-radius: 4px; }
        del { color: #656d76; }
        .dark del { color: #9198a1; }
        table.frontmatter {
            margin: 0 0 1.5em;
            border: 1px solid #d1d9e0;
            border-radius: 6px;
            border-collapse: separate;
            border-spacing: 0;
            width: auto;
            min-width: 40%;
            max-width: 100%;
            font-size: 0.9em;
            overflow: hidden;
        }
        .dark table.frontmatter { border-color: #3d444d; }
        table.frontmatter th,
        table.frontmatter td {
            border: none;
            border-bottom: 1px solid #d1d9e0;
            padding: 6px 12px;
            text-align: start;
            vertical-align: top;
        }
        .dark table.frontmatter th,
        .dark table.frontmatter td { border-bottom-color: #3d444d; }
        table.frontmatter tr:last-child th,
        table.frontmatter tr:last-child td { border-bottom: none; }
        table.frontmatter th {
            font-weight: 600;
            color: #656d76;
            background: #f6f8fa;
            white-space: nowrap;
            width: 1%;
        }
        .dark table.frontmatter th { background: #161b22; color: #9198a1; }
        table.frontmatter td {
            font-family: 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 0.95em;
            word-break: break-word;
        }
        pre.frontmatter-raw,
        pre.frontmatter-nested {
            margin: 0;
            padding: 8px 10px;
            background: transparent;
            border: none;
            font-size: 0.85em;
            white-space: pre-wrap;
        }
        pre.frontmatter-raw {
            border-left: 3px solid #d1d9e0;
            padding-left: 10px;
            margin: 0 0 1.5em;
        }
        .dark pre.frontmatter-raw { border-left-color: #3d444d; }
        """
    }
}
