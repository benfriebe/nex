import Foundation
@testable import Nex
import Testing

/// Tests for `WrappedPathReconstructor` — reconstructing a markdown path that
/// a TUI split across non-soft-wrapped terminal rows (issue #107).
struct WrappedPathReconstructionTests {
    /// Split a path into physical rows of `columns` width, last row short —
    /// mirroring how a column-boundary wrap lays a path onto the grid and how
    /// libghostty's read returns rows (trailing blanks omitted).
    private func wrapIntoRows(_ path: String, columns: Int) -> [String] {
        var rows: [String] = []
        var remaining = Substring(path)
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex,
                offsetBy: min(columns, remaining.count)
            )
            rows.append(String(remaining[remaining.startIndex ..< end]))
            remaining = remaining[end...]
        }
        return rows
    }

    @Test func singleRowPathReturnsNil() {
        // A path that fits on one row is libghostty's job, not ours.
        let rows = ["/tmp/notes.md"]
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: 20, clickRowIndex: 0, clickColumn: 3
        ) == nil)
    }

    @Test func twoRowJoinFromFirstRow() {
        let columns = 20
        let path = "/Users/ben/notes/wrapped-readme.md"
        let rows = wrapIntoRows(path, columns: columns)
        #expect(rows.count == 2)
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: columns, clickRowIndex: 0, clickColumn: 5
        ) == path)
    }

    @Test func twoRowJoinFromContinuationRow() {
        let columns = 20
        let path = "/Users/ben/notes/wrapped-readme.md"
        let rows = wrapIntoRows(path, columns: columns)
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: columns, clickRowIndex: 1, clickColumn: 2
        ) == path)
    }

    @Test func threeRowJoinFromAnyRow() {
        // The "seed from any row" property: clicking any row of a multi-row
        // path reconstructs the whole path. This is what makes an off-by-one
        // cell estimate harmless.
        let columns = 20
        let path = "/Users/ben/code/nex/Sources/App/deep/wrapped-file.md"
        let rows = wrapIntoRows(path, columns: columns)
        #expect(rows.count == 3)
        for clickRow in rows.indices {
            #expect(
                WrappedPathReconstructor.reconstruct(
                    rows: rows, columns: columns, clickRowIndex: clickRow, clickColumn: 2
                ) == path,
                "seeding from row \(clickRow) should reconstruct the whole path"
            )
        }
    }

    @Test func noPathUnderClickReturnsNil() {
        // Click lands on the space between two words.
        let rows = ["hello world there"]
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: 20, clickRowIndex: 0, clickColumn: 5
        ) == nil)
    }

    @Test func continuationWithShortRowAboveDoesNotJoin() {
        // The row above is not full to the right edge, so a path-looking token
        // on the row below must not be joined upward.
        let columns = 40
        let rows = ["short line", "looks/like/a/path.md"]
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: columns, clickRowIndex: 1, clickColumn: 2
        ) == nil)
    }

    @Test func gutterPrefixOnContinuationDoesNotJoin() {
        // A gutter glyph (box-drawing) before the continuation means the path
        // is not the leading content of its row, so no upward join.
        let columns = 20
        let full = String(repeating: "a", count: columns)
        let rows = [full, "│ ted-segment.md"]
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: columns, clickRowIndex: 1, clickColumn: 4
        ) == nil)
    }

    @Test func trailingDotIsTrimmed() {
        // Mirrors libghostty's trailing-dot trimming for a path at the end of
        // a sentence.
        let columns = 20
        let rows = ["/Users/ben/notes/wra", "pped.md."]
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: columns, clickRowIndex: 0, clickColumn: 5
        ) == "/Users/ben/notes/wrapped.md")
    }

    @Test func paddedUpperRowStillJoins() {
        // libghostty reads with trim=false, so a TUI's written trailing-space
        // padding is present in the row. The reconstructor must right-trim it
        // (and the 1-col fuzz tolerates the path ending one cell short) so the
        // join still happens — this is the exact Ink/Claude Code case.
        let columns = 20
        let rows = ["/Users/ben/notes/wr ", "apped.md"] // 19 path chars + 1 pad space
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: columns, clickRowIndex: 0, clickColumn: 5
        ) == "/Users/ben/notes/wrapped.md")
    }

    @Test func unrelatedFullWidthRowsAreJoinedByPureFunction() {
        // Documented limitation: the text alone carries no soft-wrap signal, so
        // two unrelated full-width rows that happen to abut path-like content
        // ARE joined into a bogus path. Runtime safety comes from the `.md`
        // suffix check and the FileManager.fileExists guard in openFileAtPath —
        // a fabricated path that doesn't exist never opens a pane.
        let columns = 20
        let rows = ["ERROR at /var/log/ab", "cd/unrelated.md done"]
        #expect(WrappedPathReconstructor.reconstruct(
            rows: rows, columns: columns, clickRowIndex: 0, clickColumn: 15
        ) == "/var/log/abcd/unrelated.md")
    }
}
