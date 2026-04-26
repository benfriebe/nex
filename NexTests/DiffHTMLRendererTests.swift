import AppKit
import Foundation
@testable import Nex
import Testing

struct DiffHTMLRendererTests {
    @Test func emptyDiffRendersNoChangesPlaceholder() {
        let html = DiffHTMLRenderer.renderToHTML(diffText: "")
        #expect(html.contains("class=\"empty\""))
        #expect(html.contains("No changes"))
    }

    @Test func whitespaceOnlyDiffRendersPlaceholder() {
        let html = DiffHTMLRenderer.renderToHTML(diffText: "\n\n   \n")
        #expect(html.contains("class=\"empty\""))
    }

    @Test func addedLineGetsAddClass() {
        let diff = "+let added = 1"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"line line-add\""))
    }

    @Test func deletedLineGetsDelClass() {
        let diff = "-let removed = 1"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"line line-del\""))
    }

    @Test func contextLineGetsContextClass() {
        let diff = " unchanged context line"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"line line-context\""))
    }

    @Test func hunkHeaderGetsHunkClass() {
        let diff = "@@ -10,5 +10,6 @@ func foo() {"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"line line-hunk\""))
    }

    @Test func diffGitHeaderGetsFileHeaderClass() {
        let diff = "diff --git a/foo.swift b/foo.swift"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"line line-file-header\""))
    }

    @Test func tripleDashAndPlusAreFileHeadersNotDelOrAdd() {
        let diff = """
        --- a/foo.swift
        +++ b/foo.swift
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        // Both should be file-header, not line-del / line-add.
        let headerCount = html.components(separatedBy: "class=\"line line-file-header\"").count - 1
        #expect(headerCount == 2)
        #expect(!html.contains("class=\"line line-add\""))
        #expect(!html.contains("class=\"line line-del\""))
    }

    @Test func realisticHunkProducesExpectedClassMix() {
        let diff = """
        diff --git a/x.swift b/x.swift
        index 1234567..89abcde 100644
        --- a/x.swift
        +++ b/x.swift
        @@ -1,3 +1,4 @@
         func foo() {
        -    let y = 2
        +    let y = 3
        +    let z = 4
         }
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"line line-hunk\""))
        #expect(html.contains("class=\"line line-add\""))
        #expect(html.contains("class=\"line line-del\""))
        #expect(html.contains("class=\"line line-context\""))
        #expect(html.contains("class=\"line line-file-header\""))
    }

    @Test func htmlSpecialsAreEscaped() {
        let diff = "+let cmp = a < b && b > c"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("&lt;"))
        #expect(html.contains("&gt;"))
        #expect(html.contains("&amp;"))
    }

    @Test func darkBackgroundProducesDarkHTMLClass() {
        let html = DiffHTMLRenderer.renderToHTML(
            diffText: "+x",
            backgroundColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        )
        #expect(html.contains("<html class=\"dark\">"))
    }

    @Test func lightBackgroundProducesLightHTMLClass() {
        let html = DiffHTMLRenderer.renderToHTML(
            diffText: "+x",
            backgroundColor: NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        )
        #expect(html.contains("<html class=\"light\">"))
    }

    @Test func backgroundColorEmittedAsRGBA() {
        let html = DiffHTMLRenderer.renderToHTML(
            diffText: "+x",
            backgroundColor: NSColor(red: 1, green: 0, blue: 0, alpha: 1),
            backgroundOpacity: 0.5
        )
        #expect(html.contains("rgba(255, 0, 0, 0.5)"))
    }

    // MARK: - Sticky / collapsible file headers

    @Test func diffGitOpensDetailsBlockWithFilePath() {
        let diff = """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("<details class=\"file\" open>"))
        #expect(html.contains("class=\"file-summary\""))
        #expect(html.contains("class=\"file-path\">Sources/Foo.swift</span>"))
        #expect(html.contains("</details>"))
    }

    @Test func multipleFilesProduceMultipleDetailsBlocks() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        @@ -1 +1 @@
        -a
        +b
        diff --git a/bar.swift b/bar.swift
        @@ -1 +1 @@
        -c
        +d
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        let openCount = html.components(separatedBy: "<details class=\"file\" open>").count - 1
        let closeCount = html.components(separatedBy: "</details>").count - 1
        #expect(openCount == 2)
        #expect(closeCount == 2)
        #expect(html.contains(">foo.swift</span>"))
        #expect(html.contains(">bar.swift</span>"))
    }

    @Test func summaryHasStickyCSSAndCursorPointer() {
        let html = DiffHTMLRenderer.renderToHTML(diffText: "diff --git a/x b/x\n@@ -1 +1 @@\n+a")
        #expect(html.contains("position: sticky"))
        #expect(html.contains("cursor: pointer"))
    }

    @Test func hunksAreWrappedInPerFileScrollContainer() {
        // The summary must sit OUTSIDE the horizontally-scrolling hunks
        // wrapper so it stays at viewport width when long lines force the
        // hunks to scroll horizontally.
        let diff = "diff --git a/x b/x\n@@ -1 +1 @@\n+a very long line indeed"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"hunks\""))
        #expect(html.contains("class=\"hunks-inner\""))
        // CSS: body must clip horizontally so per-file scroll handles it.
        #expect(html.contains("overflow-x: hidden"))
        // Order: <summary> ... </summary> ... <div class="hunks">
        if let sumEnd = html.range(of: "</summary>"),
           let hunksStart = html.range(of: "<div class=\"hunks\"") {
            #expect(sumEnd.upperBound <= hunksStart.lowerBound)
        } else {
            Issue.record("Expected <summary> to precede <div class=\"hunks\">")
        }
    }

    @Test func renamedFileExtractsDestinationPath() {
        let diff = "diff --git a/old/path.swift b/new/path.swift\n@@ -1 +1 @@\n+x"
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains(">new/path.swift</span>"))
    }

    @Test func diffWithoutDiffGitLineStillRenders() {
        // Edge case: lines without any `diff --git` header (e.g. raw hunk).
        // Should render as plain lines without any <details> wrapper.
        let html = DiffHTMLRenderer.renderToHTML(diffText: "+just an add")
        #expect(!html.contains("<details"))
        #expect(html.contains("class=\"line line-add\""))
    }

    // MARK: - Status badges + line counts

    @Test func modifiedFileShowsModifiedBadgeAndCounts() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        index 1..2 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,3 +1,4 @@
         keep
        -gone
        +new1
        +new2
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("status-modified"))
        #expect(html.contains(">modified</span>"))
        #expect(html.contains("class=\"stat-add\">+2</span>"))
        #expect(html.contains("class=\"stat-del\">-1</span>"))
    }

    @Test func addedFileShowsAddedBadge() {
        let diff = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        index 0000000..1234567
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,2 @@
        +line one
        +line two
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("status-added"))
        #expect(html.contains(">added</span>"))
        #expect(html.contains("class=\"stat-add\">+2</span>"))
    }

    @Test func deletedFileShowsDeletedBadge() {
        let diff = """
        diff --git a/gone.swift b/gone.swift
        deleted file mode 100644
        index 1234567..0000000
        --- a/gone.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -line one
        -line two
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("status-deleted"))
        #expect(html.contains(">deleted</span>"))
        #expect(html.contains("class=\"stat-del\">-2</span>"))
    }

    @Test func renamedFileShowsRenamedBadgeAndArrow() {
        let diff = """
        diff --git a/old.swift b/new.swift
        similarity index 95%
        rename from old.swift
        rename to new.swift
        index 1..2 100644
        --- a/old.swift
        +++ b/new.swift
        @@ -1 +1 @@
        -tweak
        +tweaked
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("status-renamed"))
        #expect(html.contains(">renamed</span>"))
        // Arrow uses → (U+2192) which gets escaped as a literal char in the HTML.
        #expect(html.contains("old.swift → new.swift"))
    }

    @Test func binaryFileShowsBinaryBadgeWithoutCounts() {
        let diff = """
        diff --git a/icon.png b/icon.png
        index 1..2 100644
        Binary files a/icon.png and b/icon.png differ
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("status-binary"))
        #expect(html.contains(">binary</span>"))
        #expect(!html.contains("class=\"diff-stats\""))
    }

    @Test func tripleDashAndPlusNotCountedAsAddOrDel() {
        // Sanity: `+++ b/path` and `--- a/path` lines must not inflate counts.
        let diff = """
        diff --git a/x b/x
        index 1..2 100644
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -old
        +new
        """
        let html = DiffHTMLRenderer.renderToHTML(diffText: diff)
        #expect(html.contains("class=\"stat-add\">+1</span>"))
        #expect(html.contains("class=\"stat-del\">-1</span>"))
    }
}
