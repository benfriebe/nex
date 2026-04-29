import AppKit
import Foundation
@testable import Nex
import Testing

struct MarkdownCheckboxRenderingTests {
    @Test func uncheckedItemEmitsTaskListClassesAndDisabledInput() {
        let html = MarkdownRenderer.renderToHTML("- [ ] todo item")
        #expect(html.contains("<li class=\"task-list-item\">"))
        #expect(html.contains("<input type=\"checkbox\""))
        #expect(html.contains("class=\"task-list-item-checkbox\""))
        #expect(html.contains(" disabled>"))
        #expect(html.contains("todo item"))
        // Must not have the `checked` attribute on an unchecked item.
        #expect(!html.contains(" checked "))
    }

    @Test func checkedItemEmitsCheckedAttribute() {
        let html = MarkdownRenderer.renderToHTML("- [x] done item")
        #expect(html.contains("<li class=\"task-list-item\">"))
        #expect(html.contains("class=\"task-list-item-checkbox\""))
        #expect(html.contains(" checked disabled>"))
        #expect(html.contains("done item"))
    }

    @Test func capitalXAlsoChecked() {
        // GFM tasklist accepts [X] as well as [x].
        let html = MarkdownRenderer.renderToHTML("- [X] done")
        #expect(html.contains(" checked disabled>"))
    }

    @Test func plainListItemKeepsBulletAndNoTaskClass() {
        // A regular list item must not pick up the task-list-item class.
        let html = MarkdownRenderer.renderToHTML("- regular item")
        #expect(html.contains("<li><p>regular item</p>"))
        #expect(!html.contains("<li class=\"task-list-item\">"))
        #expect(!html.contains("<input"))
    }

    @Test func mixedListPreservesPerItemClassing() {
        let html = MarkdownRenderer.renderToHTML("- [ ] task\n- regular")
        // The checkbox item gets the class; the regular item does not.
        #expect(html.contains("<li class=\"task-list-item\">"))
        #expect(html.contains("<li><p>regular</p>"))
    }

    @Test func cssHidesBulletForTaskListItem() {
        let html = MarkdownRenderer.renderToHTML("- [ ] x")
        #expect(html.contains("li.task-list-item { list-style-type: none; }"))
    }

    @Test func cssInlinesLeadingParagraph() {
        // Without this rule the checkbox would sit on its own line because the
        // list item content is wrapped in a block `<p>`. :first-of-type covers
        // both single- and multi-paragraph items: the trailing <p>s remain
        // block and pick up their own top margin to space themselves.
        let html = MarkdownRenderer.renderToHTML("- [ ] x")
        #expect(html.contains("li.task-list-item > p:first-of-type"))
        // Must NOT use :only-of-type — that fails to inline the leading <p>
        // in loose lists where there are two siblings.
        #expect(!html.contains("p:only-of-type { display: inline"))
    }

    @Test func multiParagraphTaskItemInlinesLeadingParagraph() {
        // Loose task item with two <p>s. The leading <p> must still match the
        // inline rule so the checkbox sits beside its label; the second <p>
        // remains block. This test would fail with `p:only-of-type` because
        // neither <p> is the only one of its type.
        let md = "- [ ] first\n\n  second\n"
        let html = MarkdownRenderer.renderToHTML(md)
        // Both paragraphs render inside the task item.
        #expect(html.contains("first"))
        #expect(html.contains("second"))
        #expect(html.contains("<li class=\"task-list-item\">"))
        // The CSS selector must match BOTH the single-paragraph case AND
        // the loose case. :first-of-type does, :only-of-type does not.
        #expect(html.contains("li.task-list-item > p:first-of-type { display: inline; }"))
    }

    @Test func escapedCheckboxBracketsAreNotATaskItem() {
        // `\[ \]` escapes the brackets so this is a plain list item. The CSS
        // block always contains `task-list-item` rules — assert on the body
        // marker instead.
        let html = MarkdownRenderer.renderToHTML(#"- \[ \] not a checkbox"#)
        #expect(!html.contains("<li class=\"task-list-item\">"))
        #expect(!html.contains("<input"))
        #expect(html.contains("[ ]"))
    }

    @Test func orderedListCheckboxAlsoSupported() {
        // swift-markdown applies the same checkbox model to ordered lists.
        // We treat them identically; the number is hidden by the same
        // `list-style-type: none` rule. This test pins that behavior.
        let html = MarkdownRenderer.renderToHTML("1. [ ] item")
        #expect(html.contains("<ol"))
        #expect(html.contains("<li class=\"task-list-item\">"))
        #expect(html.contains("class=\"task-list-item-checkbox\""))
    }

    @Test func bracketSyntaxInPlainParagraphIsNotACheckbox() {
        // `[x]` outside a list-item leading position must NOT become a checkbox.
        let html = MarkdownRenderer.renderToHTML("plain [x] text in a paragraph")
        #expect(!html.contains("<li class=\"task-list-item\">"))
        #expect(!html.contains("<input"))
        #expect(html.contains("plain [x] text in a paragraph"))
    }

    @Test func bracketSyntaxMidListItemIsNotACheckbox() {
        // `[x]` must be at the START of a list item to be a task marker.
        let html = MarkdownRenderer.renderToHTML("- not a [x] task")
        #expect(!html.contains("<li class=\"task-list-item\">"))
        #expect(!html.contains("<input"))
    }

    @Test func blockquotedTaskListIsAnUpstreamLimitation() {
        // Pin current behaviour: swift-markdown's tasklist extension does not
        // fire for `- [x]` inside a blockquote — the brackets reach us as
        // plain text. If this starts producing a checkbox after a future
        // swift-markdown bump, flip this test to assert task-list-item is
        // present.
        let html = MarkdownRenderer.renderToHTML("> - [x] inside a quote")
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<ul>"))
        #expect(!html.contains("<li class=\"task-list-item\">"))
        #expect(html.contains("[x] inside a quote"))
    }

    @Test func nestedCheckboxRendersAsTaskItem() {
        let md = """
        - parent
          - [ ] child task
        """
        let html = MarkdownRenderer.renderToHTML(md)
        #expect(html.contains("<li class=\"task-list-item\">"))
        #expect(html.contains("child task"))
    }

    @Test func checkboxItemTextEscapesAmpersand() {
        // Plain-text content inside a checkbox item must still go through the
        // standard escape path (verifies we didn't accidentally bypass
        // visitText when adding the task-list classes).
        let html = MarkdownRenderer.renderToHTML("- [ ] a & b")
        #expect(html.contains("a &amp; b"))
    }

    @Test func checkboxItemPreservesInlineMarkdown() {
        // Bold/italic inside a checkbox label must still render.
        let html = MarkdownRenderer.renderToHTML("- [ ] **bold** task")
        #expect(html.contains("<strong>bold</strong>"))
    }
}
