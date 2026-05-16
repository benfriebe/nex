import Foundation

/// Finds the markdown file path under a cmd+click in a terminal pane, including
/// paths that wrap across multiple terminal rows.
///
/// libghostty's own link detection is supposed to span soft-wraps, but in
/// practice cmd+click on a wrapped path drops the file open (issue #107). The
/// observed failure mode is that libghostty matches the visual fragment on the
/// clicked row instead of the full wrapped path. This resolver is invoked by
/// SurfaceView before forwarding the click and short-circuits the markdown
/// open path when we can identify a `.md` file under the click.
enum CmdClickPathResolver {
    /// Find the markdown path at the given click cell.
    ///
    /// `viewportText` is the result of reading the viewport via
    /// `ghostty_surface_read_text`, which uses `selectionString(unwrap=true)`:
    /// soft-wrapped rows are joined directly (no separator) and hard line
    /// breaks become `\n`. Wrap-chained rows are full (cols characters each)
    /// because the wrap fired only because content exceeded width. The trailing
    /// row of a logical line may be partial — libghostty drops trailing blank
    /// cells. The chunk-row math here uses ceil(chunk.count / cols) so a
    /// partial trailing row still counts as one row.
    ///
    /// ASCII-path assumption: clickCol → character offset uses
    /// `(clickRow - chunkStartRow) * cols + clickCol`, which is exact for
    /// single-byte/single-cell content. Wide CJK or wide-emoji surrounding
    /// text will misalign the click within the chunk; markdown paths in
    /// practice are ASCII so this is acceptable scope.
    ///
    /// `firstRow` is the viewport row index of the first row included in
    /// `viewportText`. `cols` is the terminal width in cells. `clickRow` and
    /// `clickCol` are 0-based viewport cell coordinates.
    ///
    /// Returns the matched markdown path (trimmed), or nil if none was found.
    static func findMarkdownPath(
        in viewportText: String,
        firstRow: Int,
        cols: Int,
        clickRow: Int,
        clickCol: Int
    ) -> String? {
        guard cols > 0 else { return nil }
        // Split into logical lines: each chunk is a sequence of soft-wrapped
        // rows joined together, separated from the next chunk by a hard break.
        let chunks = viewportText.components(separatedBy: "\n")
        var rowCursor = firstRow
        for chunk in chunks {
            // ceil(chunk.count / cols) — wrap-chained rows are full (=cols),
            // the trailing row may be partial. Empty chunk still occupies 1
            // physical row (a blank line in the viewport).
            let rowsInChunk = max(1, (chunk.count + cols - 1) / cols)
            let chunkStartRow = rowCursor
            let chunkEndRow = chunkStartRow + rowsInChunk - 1
            defer { rowCursor = chunkEndRow + 1 }
            guard clickRow >= chunkStartRow, clickRow <= chunkEndRow else { continue }

            let clickOffsetInChunk = (clickRow - chunkStartRow) * cols + clickCol
            return findContainingMarkdownPath(in: chunk, clickOffset: clickOffsetInChunk)
        }
        return nil
    }

    /// Find a `.md` path in `line` that contains `clickOffset`. Returns the
    /// matched path (trimmed of trailing `.` and surrounding whitespace) or
    /// nil if no .md path covers the click position.
    static func findContainingMarkdownPath(in line: String, clickOffset: Int) -> String? {
        // Path candidates: must end with `.md` (case-insensitive) followed by
        // a path-terminator (whitespace / paren / bracket / angle / quote /
        // colon / comma / end-of-string). Without the terminator anchor the
        // greedy `[^\s...]+` would match `foo.md.bak` then backtrack to expose
        // `.md`, opening a non-existent `foo.md`. Anchored, `foo.md.bak` does
        // not match at all.
        // Roots accepted: `/`, `~`, `./`, `../`. Bare relatives (`notes/x.md`)
        // are out of scope — libghostty already handles those via its own
        // regex when the path doesn't wrap.
        let pattern = #"(?:[/~]|\.{1,2}/)[^\s\(\)\[\]<>"'\\]+?\.[mM][dD](?=[\s\(\)\[\]<>"',:]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        for match in matches {
            // Inclusive containment: clicking on the very last char of a path
            // (the final 'd' in `.md`) should still resolve.
            let start = match.range.location
            let end = match.range.location + match.range.length
            guard clickOffset >= start, clickOffset < end else { continue }
            let raw = nsLine.substring(with: match.range)
            return cleanupPath(raw)
        }
        return nil
    }

    /// Strip trailing dots and whitespace, mirroring what
    /// `GhosttyApp.handleAction(GHOSTTY_ACTION_OPEN_URL)` does to the URL it
    /// receives from libghostty.
    private static func cleanupPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") {
            s.removeLast()
        }
        return s
    }
}
