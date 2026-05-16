import Foundation
@testable import Nex
import Testing

struct CmdClickPathResolverTests {
    // MARK: - findContainingMarkdownPath (single-string regex behaviour)

    @Test func returnsAbsolutePathWhenClickIsInsideIt() {
        let line = "open /Users/ben/notes/foo.md please"
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "notes")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == "/Users/ben/notes/foo.md")
    }

    @Test func returnsHomePathWhenClickIsInsideIt() {
        let line = "see ~/Documents/spec.md for details"
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "spec")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == "~/Documents/spec.md")
    }

    @Test func returnsNilWhenClickIsOutsideAllMatches() {
        let line = "  /Users/ben/notes/foo.md   "
        // Click in the trailing whitespace, well past the path.
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: line.count - 2)
        #expect(path == nil)
    }

    @Test func returnsNilWhenLineHasNoMarkdownPath() {
        let line = "hello world https://example.com no markdown here"
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: 5)
        #expect(path == nil)
    }

    @Test func picksContainingPathWhenMultiplePathsOnSameLine() {
        let line = "/tmp/a.md and /tmp/long/b.md again"
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "b.md")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == "/tmp/long/b.md")
    }

    @Test func extractsPathFromMarkdownLinkSyntax() {
        // The trailing `)` must not be consumed by the path match.
        let line = "see [the spec](/Users/ben/notes/spec.md) for details"
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "spec.md")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == "/Users/ben/notes/spec.md")
    }

    @Test func clickOnFinalCharacterStillResolves() {
        let line = "/tmp/file.md"
        // Click on the final `d` (last char in the path) — inclusive containment.
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: line.count - 1)
        #expect(path == "/tmp/file.md")
    }

    @Test func handlesRelativeDotPaths() {
        let line = "open ./notes/today.md"
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "today")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == "./notes/today.md")
    }

    @Test func handlesParentDirRelativePaths() {
        let line = "see ../shared/index.md"
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "index")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == "../shared/index.md")
    }

    @Test func doesNotMatchMdInsideBakSuffix() {
        // Without the path-terminator lookahead, /tmp/foo.md.bak would
        // backtrack to expose `.md` and cmd+click on `foo` would open a
        // bogus `/tmp/foo.md`. With the lookahead, no .md path is matched.
        let line = "edit /tmp/foo.md.bak now"
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "foo")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == nil)
    }

    @Test func doesNotMatchPathFollowedByPeriod() {
        // Trade-off: requiring a non-`.` terminator after `.md` is what blocks
        // the .md.bak false-match. The cost is that a sentence-ending period
        // immediately after `.md` (no space between) doesn't match either.
        // Acceptable: this case is rare; the bak case is common.
        let line = "/tmp/file.md."
        let clickOffset = line.distance(from: line.startIndex, to: line.range(of: "file")!.lowerBound)
        let path = CmdClickPathResolver.findContainingMarkdownPath(in: line, clickOffset: clickOffset)
        #expect(path == nil)
    }

    @Test func resolvesPathFollowedByCommaOrColon() {
        // Compiler/lint output frequently emits `path.md:42` or `a.md, b.md`.
        let line1 = "see /tmp/foo.md:42 here"
        let off1 = line1.distance(from: line1.startIndex, to: line1.range(of: "foo")!.lowerBound)
        #expect(CmdClickPathResolver.findContainingMarkdownPath(in: line1, clickOffset: off1) == "/tmp/foo.md")

        let line2 = "/tmp/a.md, /tmp/b.md"
        let off2 = line2.distance(from: line2.startIndex, to: line2.range(of: "a.md")!.lowerBound)
        #expect(CmdClickPathResolver.findContainingMarkdownPath(in: line2, clickOffset: off2) == "/tmp/a.md")
    }

    // MARK: - findMarkdownPath (full viewport-aware flow)

    /// Builds a viewport text mock matching libghostty's
    /// selectionString(unwrap=true, trim=false) shape:
    /// - Wrap-chained rows are always full (`cols` chars). The caller asserts
    ///   this by passing wraps[i]=true; we precondition that row.count==cols.
    /// - The last row of any logical line may be partial. libghostty drops
    ///   trailing blank cells (formatter resets blank_cells on row end), so
    ///   we emit the row literally with no padding.
    /// - Hard breaks insert `\n` between chunks; the trailing chunk has no
    ///   trailing newline.
    private func makeViewport(rows: [String], cols: Int, wraps: [Bool]) -> String {
        precondition(rows.count == wraps.count, "wraps array must match rows")
        var out = ""
        for (idx, row) in rows.enumerated() {
            if wraps[idx] {
                precondition(row.count == cols, "wrap-chained row must be exactly cols chars")
                out.append(row)
            } else {
                // Last row of a logical line: emit as-is (libghostty drops
                // trailing blank cells; trailing spaces from explicit ` `
                // writes would survive but partial rows in tests are usually
                // shorter than `cols`).
                out.append(row)
                if idx != rows.count - 1 {
                    out.append("\n")
                }
            }
        }
        return out
    }

    @Test func resolvesSingleLineMarkdownPath() {
        let cols = 40
        let viewport = makeViewport(
            rows: ["see /tmp/foo.md please"],
            cols: cols,
            wraps: [false]
        )
        let clickCol = "see ".count + 4 // somewhere inside "/tmp/foo.md"
        let path = CmdClickPathResolver.findMarkdownPath(
            in: viewport,
            firstRow: 0,
            cols: cols,
            clickRow: 0,
            clickCol: clickCol
        )
        #expect(path == "/tmp/foo.md")
    }

    @Test func resolvesPathThatWrapsAcrossTwoRowsClickedOnFirstRow() {
        // 30-col terminal. Path is "/Users/ben/notes/very-long-name.md".
        // Row 0 holds "see /Users/ben/notes/very-lon" (29 chars + 1 pad).
        // We need the path to actually fill row 0 to force wrap, so build by
        // hand with enough leading text.
        let cols = 20
        let path = "/Users/ben/notes/spec.md"
        // Row 0 (20 cols): "abc /Users/ben/notes" -> 20 chars exactly.
        let row0 = "abc " + String(path.prefix(16)) // "abc /Users/ben/notes" = 20 chars
        // Row 1 (20 cols): "/spec.md            " -> "/spec.md" + padding.
        let row1 = String(path.suffix(path.count - 16)) // "/spec.md" = 8 chars
        let viewport = makeViewport(rows: [row0, row1], cols: cols, wraps: [true, false])
        // Click on row 0, col where "Users" starts (col 5).
        let path1 = CmdClickPathResolver.findMarkdownPath(
            in: viewport, firstRow: 0, cols: cols, clickRow: 0, clickCol: 5
        )
        #expect(path1 == path)
    }

    @Test func resolvesPathThatWrapsAcrossTwoRowsClickedOnSecondRow() {
        let cols = 20
        let path = "/Users/ben/notes/spec.md"
        let row0 = "abc " + String(path.prefix(16))
        let row1 = String(path.suffix(path.count - 16))
        let viewport = makeViewport(rows: [row0, row1], cols: cols, wraps: [true, false])
        // Click on row 1, col 2 (inside "/spec.md").
        let path2 = CmdClickPathResolver.findMarkdownPath(
            in: viewport, firstRow: 0, cols: cols, clickRow: 1, clickCol: 2
        )
        #expect(path2 == path)
    }

    @Test func returnsNilWhenClickRowOutsideViewport() {
        let viewport = makeViewport(rows: ["/tmp/foo.md"], cols: 20, wraps: [false])
        let path = CmdClickPathResolver.findMarkdownPath(
            in: viewport, firstRow: 0, cols: 20, clickRow: 5, clickCol: 0
        )
        #expect(path == nil)
    }

    @Test func returnsNilWhenClickRowOnDifferentLogicalLineFromPath() {
        // Two non-wrapping rows: row 0 has the path, row 1 doesn't. Clicking
        // on row 1 should not match the row 0 path.
        let viewport = makeViewport(
            rows: ["/tmp/foo.md", "no path here"],
            cols: 20,
            wraps: [false, false]
        )
        let path = CmdClickPathResolver.findMarkdownPath(
            in: viewport, firstRow: 0, cols: 20, clickRow: 1, clickCol: 5
        )
        #expect(path == nil)
    }

    @Test func resolvesWrappedPathInWindowStartingMidViewport() {
        // The caller may pass a non-zero firstRow when reading a window
        // around the click; row indexing must offset accordingly.
        let cols = 20
        let path = "/long/wrapped/file.md"
        // Wrap path across 2 rows, starting at viewport row 3.
        let row3 = String(path.prefix(20)) // 20 chars: "/long/wrapped/file.m"
        let row4 = String(path.suffix(path.count - 20)) // "d"
        let viewport = makeViewport(rows: [row3, row4], cols: cols, wraps: [true, false])
        // Click on viewport row 4, col 0 (the trailing 'd').
        let path1 = CmdClickPathResolver.findMarkdownPath(
            in: viewport, firstRow: 3, cols: cols, clickRow: 4, clickCol: 0
        )
        #expect(path1 == path)
    }

    @Test func returnsNilForZeroCols() {
        // Pathological: cols = 0 should not crash.
        let path = CmdClickPathResolver.findMarkdownPath(
            in: "anything", firstRow: 0, cols: 0, clickRow: 0, clickCol: 0
        )
        #expect(path == nil)
    }
}
