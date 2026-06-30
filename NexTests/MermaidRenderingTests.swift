import AppKit
import Foundation
@testable import Nex
import Testing

/// Renderer-level coverage for ```mermaid fenced blocks. The JS-side SVG
/// rendering (MarkdownMermaidScript) needs a JavaScript engine and is
/// exercised visually in the cua VM, not here.
struct MermaidRenderingTests {
    @Test func mermaidBlockEmitsHydrationPlaceholder() {
        let md = """
        ```mermaid
        graph TD
          A --> B
        ```
        """
        let result = MarkdownRenderer.render(md)
        #expect(result.containsMermaid)
        #expect(result.html.contains("class=\"mermaid-block\" data-nex-mermaid"))
        #expect(result.html.contains("<pre class=\"mermaid-source\">"))
        // The diagram source survives into the hidden source element.
        #expect(result.html.contains("graph TD"))
        // It must NOT fall through to the standard code-block + copy button.
        #expect(!result.html.contains("class=\"language-mermaid\""))
    }

    @Test func mermaidBlockHasNoCopyButton() {
        let html = MarkdownRenderer.renderToHTML("```mermaid\ngraph TD\n  A --> B\n```")
        #expect(!html.contains("class=\"code-copy-btn\""))
    }

    @Test func mermaidLanguageIsCaseInsensitive() {
        let result = MarkdownRenderer.render("```Mermaid\ngraph TD\n  A --> B\n```")
        #expect(result.containsMermaid)
        #expect(result.html.contains("data-nex-mermaid"))
    }

    @Test func mermaidInfoStringWithExtraTokensStillMatches() {
        // A fenced info string may carry more than the language token.
        let result = MarkdownRenderer.render("```mermaid title=\"flow\"\ngraph TD\n  A --> B\n```")
        #expect(result.containsMermaid)
        #expect(result.html.contains("data-nex-mermaid"))
    }

    @Test func mermaidSourceIsHTMLEscaped() {
        // Diagram source is untrusted file content — it must be escaped so it
        // can't inject markup into the preview document.
        let result = MarkdownRenderer.render("```mermaid\n<script>alert(1)</script>\n```")
        #expect(result.html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!result.html.contains("<script>alert(1)"))
    }

    @Test func nonMermaidCodeBlockUnaffected() {
        // Regression: a normal fenced block still renders the copy-button
        // wrapper and does not set the mermaid flag.
        let result = MarkdownRenderer.render("```swift\nlet x = 1\n```")
        #expect(!result.containsMermaid)
        #expect(result.html.contains("<div class=\"code-block\">"))
        #expect(result.html.contains("class=\"language-swift\""))
        #expect(result.html.contains("class=\"code-copy-btn\""))
        #expect(!result.html.contains("data-nex-mermaid"))
    }

    @Test func plainProseDoesNotSetMermaidFlag() {
        // The flag comes from an actual fenced block, not substring sniffing —
        // prose mentioning the marker must not trip it.
        let result = MarkdownRenderer.render("A paragraph mentioning data-nex-mermaid in passing.")
        #expect(!result.containsMermaid)
    }

    @Test func multipleMermaidBlocksEachEmitPlaceholder() {
        // The JS renders blocks sequentially keyed by document order, so each
        // fence must produce its own placeholder.
        let md = """
        ```mermaid
        graph TD
          A --> B
        ```

        Some prose between diagrams.

        ```mermaid
        sequenceDiagram
          Alice->>Bob: Hi
        ```
        """
        let result = MarkdownRenderer.render(md)
        #expect(result.containsMermaid)
        let count = result.html.components(separatedBy: "data-nex-mermaid").count - 1
        #expect(count == 2)
    }

    @Test func emptyMermaidBlockStillEmitsPlaceholder() {
        // An empty fence sets the flag and emits a placeholder (the JS renders
        // nothing for it rather than showing an error note).
        let result = MarkdownRenderer.render("```mermaid\n```")
        #expect(result.containsMermaid)
        #expect(result.html.contains("data-nex-mermaid"))
    }

    @Test func indentedCodeBlockIsNotMermaid() {
        // A 4-space indented code block has no language info string, so it can
        // never be mistaken for a mermaid block.
        let result = MarkdownRenderer.render("    graph TD\n    A --> B")
        #expect(!result.containsMermaid)
        #expect(!result.html.contains("data-nex-mermaid"))
    }

    @Test func placeholderClassContractIsStable() {
        // Locks the exact class/attribute strings the injected JS
        // (MarkdownMermaidScript / MarkdownFindScript) selects on. If the
        // renderer renames these, this fails and forces the JS to be updated
        // in lockstep.
        let html = MarkdownRenderer.renderToHTML("```mermaid\ngraph TD\n  A --> B\n```")
        #expect(html.contains("class=\"mermaid-block\" data-nex-mermaid"))
        #expect(html.contains("class=\"mermaid-source\""))
    }
}
