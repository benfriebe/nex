import AppKit
import Foundation
@testable import Nex
import Testing

struct MarkdownHTMLRendererTests {
    // MARK: - @ mentions

    @Test func atMentionMidSentence() {
        let html = MarkdownRenderer.renderToHTML("Hello @claude how are you")
        #expect(html.contains("@claude"))
    }

    @Test func atMentionAtStartOfLine() {
        let html = MarkdownRenderer.renderToHTML("@claude please review this")
        #expect(html.contains("@claude"))
    }

    @Test func atMentionInListItem() {
        let html = MarkdownRenderer.renderToHTML("- assign to @claude")
        #expect(html.contains("@claude"))
    }

    @Test func atMentionStandaloneOnLine() {
        let html = MarkdownRenderer.renderToHTML("@claude")
        #expect(html.contains("@claude"))
    }

    // MARK: - Bare URL autolinking

    @Test func bareHTTPSURLAutolinked() {
        let html = MarkdownRenderer.renderToHTML("See https://example.com for details.")
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }

    @Test func bareURLAtStartOfLineAutolinked() {
        let html = MarkdownRenderer.renderToHTML("https://example.com is the home page")
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }

    @Test func bareURLAtEndOfLineAutolinked() {
        let html = MarkdownRenderer.renderToHTML("Visit us at https://example.com")
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }

    @Test func multipleBareURLsAllAutolinked() {
        let html = MarkdownRenderer.renderToHTML("See https://a.com and https://b.com today.")
        #expect(html.contains("<a href=\"https://a.com\">https://a.com</a>"))
        #expect(html.contains("<a href=\"https://b.com\">https://b.com</a>"))
    }

    @Test func bareURLInListItemAutolinked() {
        let html = MarkdownRenderer.renderToHTML("- See https://example.com for details")
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }

    @Test func explicitMarkdownLinkNotDoubleWrapped() {
        // [text](url) must produce exactly one <a> tag — no nested anchor from autolinking the visible text.
        let html = MarkdownRenderer.renderToHTML("[https://example.com](https://example.com)")
        let anchorCount = html.components(separatedBy: "<a ").count - 1
        #expect(anchorCount == 1)
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }

    @Test func bareURLInImageAltNotAutolinked() {
        // The alt text becomes an HTML attribute; injecting <a> there would break the tag.
        let html = MarkdownRenderer.renderToHTML("![see https://example.com](pic.png)")
        #expect(!html.contains("alt=\"see <a"))
    }

    @Test func plainTextWithoutURLUnchanged() {
        let html = MarkdownRenderer.renderToHTML("Just some plain text with no links.")
        #expect(!html.contains("<a "))
        #expect(html.contains("<p>Just some plain text with no links.</p>"))
    }

    @Test func trailingPunctuationNotPartOfURL() {
        // NSDataDetector strips trailing sentence punctuation so the period stays as text.
        let html = MarkdownRenderer.renderToHTML("Visit https://example.com.")
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>."))
    }

    @Test func bareURLInsideInlineCodeNotAutolinked() {
        // Inline code goes through a different path and must remain literal.
        let html = MarkdownRenderer.renderToHTML("Use `https://example.com` literally.")
        #expect(html.contains("<code>https://example.com</code>"))
    }

    @Test func schemelessDomainNotAutolinked() {
        // NSDataDetector matches `example.com` as a link, but we deliberately
        // require an explicit scheme so prose mentions of a domain stay text.
        let html = MarkdownRenderer.renderToHTML("Visit example.com today.")
        #expect(!html.contains("<a "))
        #expect(html.contains("Visit example.com today."))
    }

    @Test func schemelessWWWDomainNotAutolinked() {
        let html = MarkdownRenderer.renderToHTML("Try www.example.com.")
        #expect(!html.contains("<a "))
        #expect(html.contains("Try www.example.com."))
    }

    @Test func bareEmailNotAutolinked() {
        // NSDataDetector turns `foo@example.com` into a `mailto:` URL, but
        // the source text has no scheme so it should render as plain text.
        let html = MarkdownRenderer.renderToHTML("Email foo@example.com please.")
        #expect(!html.contains("<a "))
        #expect(html.contains("Email foo@example.com please."))
    }

    @Test func explicitMailtoSchemeAutolinked() {
        // `mailto:` prefix is in the allowed list, so it links.
        let html = MarkdownRenderer.renderToHTML("Reach mailto:foo@example.com.")
        #expect(html.contains("<a href=\"mailto:foo@example.com\">mailto:foo@example.com</a>"))
    }

    @Test func ftpAndFileSchemesAutolinked() {
        let html = MarkdownRenderer.renderToHTML("ftp://x.example/y and file:///etc/hosts")
        #expect(html.contains("<a href=\"ftp://x.example/y\">ftp://x.example/y</a>"))
        #expect(html.contains("<a href=\"file:///etc/hosts\">file:///etc/hosts</a>"))
    }

    @Test func mixedSchemedAndBareURLsAutolinkOnlyTheSchemed() {
        let html = MarkdownRenderer.renderToHTML("See example.com and https://anthropic.com.")
        // Schemed URL becomes a link; schemeless one stays text.
        #expect(html.contains("<a href=\"https://anthropic.com\">https://anthropic.com</a>"))
        #expect(html.contains("example.com and "))
        // Exactly one anchor.
        let anchorCount = html.components(separatedBy: "<a ").count - 1
        #expect(anchorCount == 1)
    }

    // MARK: - Basic rendering sanity

    @Test func headingRendered() {
        let html = MarkdownRenderer.renderToHTML("# Title")
        #expect(html.contains("<h1>Title</h1>"))
    }

    @Test func paragraphRendered() {
        let html = MarkdownRenderer.renderToHTML("Hello world")
        #expect(html.contains("<p>Hello world</p>"))
    }

    // MARK: - Front matter

    @Test func frontMatterBasicRendersAsTable() {
        let html = MarkdownRenderer.renderToHTML("---\ntitle: Hello\n---\n# Body")
        #expect(html.contains("<table class=\"frontmatter\">"))
        #expect(html.contains("<th scope=\"row\">title</th>"))
        #expect(html.contains("<td>Hello</td>"))
        #expect(html.contains("<h1>Body</h1>"))
    }

    @Test func frontMatterStrippedFromBody() {
        let html = MarkdownRenderer.renderToHTML("---\ntitle: Hello\n---\nAfter")
        // The literal "title: Hello" must not appear as body text.
        #expect(!html.contains("<p>title: Hello</p>"))
        #expect(html.contains("<p>After</p>"))
    }

    @Test func frontMatterInlineArrayBecomesCommaList() {
        let html = MarkdownRenderer.renderToHTML("---\ntags: [a, b, c]\n---\n")
        #expect(html.contains("<td>a, b, c</td>"))
    }

    @Test func frontMatterBlockListBecomesCommaList() {
        let yaml = "---\ntags:\n  - a\n  - b\n---\n"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(html.contains("<td>a, b</td>"))
    }

    @Test func frontMatterBoolAndNumberRendered() {
        let html = MarkdownRenderer.renderToHTML("---\ndraft: true\ncount: 42\n---\n")
        #expect(html.contains("<td>true</td>"))
        #expect(html.contains("<td>42</td>"))
    }

    @Test func frontMatterQuotedStringPreservesColon() {
        let html = MarkdownRenderer.renderToHTML("---\ntitle: \"Hello: world\"\n---\n")
        #expect(html.contains("<td>Hello: world</td>"))
    }

    @Test func frontMatterKeyOrderPreserved() {
        let html = MarkdownRenderer.renderToHTML("---\na: 1\nb: 2\nc: 3\n---\n")
        guard let aRange = html.range(of: ">a</th>"),
              let bRange = html.range(of: ">b</th>"),
              let cRange = html.range(of: ">c</th>") else {
            Issue.record("expected all three keys in output")
            return
        }
        #expect(aRange.lowerBound < bRange.lowerBound)
        #expect(bRange.lowerBound < cRange.lowerBound)
    }

    @Test func frontMatterNestedMappingUsesNestedPre() {
        let yaml = "---\nauthor:\n  name: Jane\n  email: j@e.com\n---\n"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(html.contains("<pre class=\"frontmatter-nested\">"))
        #expect(html.contains("name: Jane"))
        #expect(html.contains("email: j@e.com"))
    }

    @Test func frontMatterNonStringKeyCoerced() {
        let html = MarkdownRenderer.renderToHTML("---\n1: one\n2: two\n---\n")
        #expect(html.contains("<th scope=\"row\">1</th>"))
        #expect(html.contains("<th scope=\"row\">2</th>"))
    }

    @Test func frontMatterCRLFLineEndings() {
        let html = MarkdownRenderer.renderToHTML("---\r\ntitle: x\r\n---\r\n# Body")
        #expect(html.contains("<table class=\"frontmatter\">"))
        #expect(html.contains("<td>x</td>"))
        #expect(html.contains("<h1>Body</h1>"))
    }

    @Test func frontMatterLeadingBOMTolerated() {
        let html = MarkdownRenderer.renderToHTML("\u{FEFF}---\ntitle: x\n---\n# Body")
        #expect(html.contains("<table class=\"frontmatter\">"))
        #expect(html.contains("<td>x</td>"))
    }

    @Test func frontMatterAbsentDoesNotRenderTable() {
        let html = MarkdownRenderer.renderToHTML("# Just a heading\n\nA paragraph.")
        #expect(!html.contains("class=\"frontmatter\""))
    }

    @Test func frontMatterMissingClosingFenceIsRegularMarkdown() {
        // Without a closing ---, swift-markdown should see the opening --- as
        // a thematic break (hr) followed by body content.
        let html = MarkdownRenderer.renderToHTML("---\ntitle: x\n# Heading")
        #expect(!html.contains("class=\"frontmatter\""))
        #expect(html.contains("<hr>"))
    }

    @Test func frontMatterEmptyMappingEmitsNothing() {
        let html = MarkdownRenderer.renderToHTML("---\n---\n# Body")
        #expect(!html.contains("class=\"frontmatter\""))
        #expect(html.contains("<h1>Body</h1>"))
    }

    @Test func frontMatterExceedingSizeCapTreatedAsAbsent() {
        // Build a front-matter block > 64 KiB. Each line is ~72 bytes, so 1000
        // lines ≈ 72 KiB — comfortably over the cap.
        let padding = String(repeating: "x", count: 64)
        var yaml = "---\n"
        for i in 0 ..< 1000 {
            yaml += "k\(i): \(padding)\n"
        }
        yaml += "---\n# Body"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(!html.contains("class=\"frontmatter\""))
    }

    @Test func frontMatterMalformedYAMLFallsBackEscaped() {
        // Malformed YAML with an embedded <script>; should show raw-fallback
        // pre AND the script tag must be escaped.
        let yaml = "---\ntitle: [unclosed <script>alert(1)</script>\n---\n# Body"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(html.contains("<pre class=\"frontmatter-raw\">"))
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test func frontMatterInjectionInValueEscaped() {
        let yaml = "---\ntitle: \"<script>alert(1)</script>\"\n---\n"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test func frontMatterInjectionInKeyEscaped() {
        // A key containing HTML must be escaped inside <th>.
        let yaml = "---\n\"<b>evil</b>\": x\n---\n"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(!html.contains("<th scope=\"row\"><b>evil</b></th>"))
        #expect(html.contains("&lt;b&gt;evil&lt;/b&gt;"))
    }

    @Test func frontMatterDarkThemeCSSPresent() {
        let html = MarkdownRenderer.renderToHTML(
            "---\ntitle: x\n---\n",
            backgroundColor: .black
        )
        #expect(html.contains("<html class=\"dark\">"))
        #expect(html.contains(".dark table.frontmatter"))
    }

    @Test func frontMatterOpeningFenceRejectsLeadingWhitespace() {
        // An indented `---` must NOT be treated as an opening fence.
        let html = MarkdownRenderer.renderToHTML("  ---\ntitle: x\n---\n# Body")
        #expect(!html.contains("class=\"frontmatter\""))
    }

    @Test func frontMatterClosingFenceRejectsLeadingWhitespace() {
        // An indented `---` must NOT be treated as a closing fence.
        let html = MarkdownRenderer.renderToHTML("---\ntitle: x\n  ---\n# Body")
        #expect(!html.contains("class=\"frontmatter\""))
    }

    @Test func frontMatterClosingFenceAllowsTrailingWhitespace() {
        let html = MarkdownRenderer.renderToHTML("---\ntitle: x\n---  \n# Body")
        #expect(html.contains("<table class=\"frontmatter\">"))
        #expect(html.contains("<td>x</td>"))
    }

    @Test func frontMatterDotDotDotClosingFence() {
        let html = MarkdownRenderer.renderToHTML("---\ntitle: x\n...\n# Body")
        #expect(html.contains("<table class=\"frontmatter\">"))
        #expect(html.contains("<td>x</td>"))
    }

    @Test func frontMatterBlockScalarPreservesNewlines() {
        // A `|` literal scalar must survive in a pre, not get flattened.
        let yaml = "---\ndescription: |\n  Line 1\n  Line 2\n---\n"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(html.contains("<pre class=\"frontmatter-nested\">"))
        #expect(html.contains("Line 1"))
        #expect(html.contains("Line 2"))
    }

    @Test func frontMatterNullValuedKey() {
        let html = MarkdownRenderer.renderToHTML("---\nkey:\n---\n# Body")
        // The table is emitted with the key row (value is empty or "null").
        #expect(html.contains("<table class=\"frontmatter\">"))
        #expect(html.contains("<th scope=\"row\">key</th>"))
        #expect(html.contains("<h1>Body</h1>"))
    }

    @Test func frontMatterSizeCapBailsMidScan() {
        // No closing fence; block is huge. The scanner must bail while
        // scanning, not after. We don't measure time here — this is a
        // correctness guard that the "no-fm" path is taken.
        let padding = String(repeating: "x", count: 64)
        var yaml = "---\n"
        for i in 0 ..< 2000 {
            yaml += "k\(i): \(padding)\n"
        }
        // Intentionally no closing ---; just body text that looks YAML-like.
        yaml += "# Body"
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(!html.contains("class=\"frontmatter\""))
    }

    @Test func frontMatterMultilineScalarInSequenceGoesToPre() {
        // A sequence where one element is a multiline block scalar must NOT
        // comma-collapse — newlines would disappear.
        let yaml = """
        ---
        items:
          - one
          - |
            two line one
            two line two
        ---
        """
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(html.contains("<pre class=\"frontmatter-nested\">"))
        #expect(html.contains("two line one"))
        #expect(html.contains("two line two"))
    }

    @Test func frontMatterAliasResolvedByYamsCompose() {
        // Yams.compose resolves aliases to their anchored value, so an alias
        // reference surfaces as the target's content. Both cells should render
        // as "hello"; a bare "b" identifier must never appear alone.
        let yaml = """
        ---
        base: &b hello
        other: *b
        ---
        """
        let html = MarkdownRenderer.renderToHTML(yaml)
        #expect(html.contains("<td>hello</td>"))
        #expect(!html.contains("<td>b</td>"))
    }
}
