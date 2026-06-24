import Foundation

/// Reconstructs a file path that a terminal application split across
/// multiple physical rows *without* the soft-wrap flag (issue #107).
///
/// Ink-based TUIs such as Claude Code pre-wrap their text to the terminal
/// width and emit each visual row as a separate logical line, so the rows
/// are never linked by the terminal soft-wrap flag. libghostty's own link
/// detection (`selectLine`) only joins rows that *are* soft-wrap-linked, so
/// for these pre-wrapped paths it recovers just the fragment on the clicked
/// row — Cmd+click then either does nothing (first row, no `.md` suffix) or
/// opens a broken relative path (continuation row).
///
/// This reconstructs the full path by joining the contiguous path-character
/// runs across physically-adjacent, full-width rows. It operates purely on
/// the already-read row strings so it can be unit tested without a live
/// surface.
///
/// Limits (intentional): paths containing spaces are not reconstructed, and
/// only genuine multi-row joins are returned — a single-row path is left to
/// libghostty, which already opens those correctly.
enum WrappedPathReconstructor {
    /// Characters allowed in a path, mirroring libghostty's `url.zig`
    /// `path_chars` set (`[\w\-.~:/?#@!$&*+;=%]`) for ASCII. Space is excluded
    /// (paths with spaces aren't reconstructed), as are non-ASCII `\w` letters.
    static let pathCharacters: Set<Character> = {
        var set = Set("abcdefghijklmnopqrstuvwxyz")
        set.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.formUnion("0123456789")
        set.formUnion("-.~:/?#@!$&*+;=%_")
        return set
    }()

    /// Reconstruct the full path under a click.
    ///
    /// - Parameters:
    ///   - rows: physical visual rows as read from the terminal, top to
    ///     bottom, with trailing blanks already omitted (matching how
    ///     libghostty's `read_text` returns them).
    ///   - columns: terminal width in cells.
    ///   - clickRowIndex: index into `rows` of the clicked row.
    ///   - clickColumn: 0-based column of the click.
    /// - Returns: the joined path *only* when it spans more than the clicked
    ///   row (a genuine multi-row join); `nil` for a single-row path or when
    ///   the click is not on a path.
    static func reconstruct(
        rows: [String],
        columns: Int,
        clickRowIndex: Int,
        clickColumn: Int
    ) -> String? {
        guard columns > 0, rows.indices.contains(clickRowIndex) else { return nil }

        // libghostty reads with trim=false, so a row's *written* trailing
        // spaces are emitted (Ink/TUIs often pad rows for background styling).
        // Right-trim them so "fills to the right edge" is measured against the
        // last real content cell, not the padding.
        let trimmed = rows.map { Array(rightTrimmingSpaces($0)) }

        let seed = trimmed[clickRowIndex]
        guard !seed.isEmpty else { return nil }
        let clamped = min(max(clickColumn, 0), seed.count - 1)
        guard let seedRun = pathRun(in: seed, containing: clamped) else { return nil }

        var pieces = [String(seed[seedRun])]
        var didJoin = false

        // Extend upward: the current top piece must be the leading content of
        // its row, and the row above must fill to the right edge ending in a
        // path char — the column-boundary wrap signature.
        var topRow = clickRowIndex
        var topRunStart = seedRun.lowerBound
        while topRow > 0, isLeadingContent(trimmed[topRow], runStart: topRunStart) {
            let above = trimmed[topRow - 1]
            guard rowFillsToEnd(above, columns: columns),
                  let aboveRun = trailingPathRun(in: above)
            else { break }
            pieces.insert(String(above[aboveRun]), at: 0)
            topRow -= 1
            topRunStart = aboveRun.lowerBound
            didJoin = true
        }

        // Extend downward: the current bottom piece must reach the right edge
        // of its row, and the row below must lead with a path char.
        var bottomRow = clickRowIndex
        var bottomRunEnd = seedRun.upperBound
        while bottomRow < trimmed.count - 1,
              runReachesEnd(trimmed[bottomRow], runEnd: bottomRunEnd, columns: columns) {
            let below = trimmed[bottomRow + 1]
            guard let belowRun = leadingPathRun(in: below) else { break }
            pieces.append(String(below[belowRun]))
            bottomRow += 1
            bottomRunEnd = belowRun.upperBound
            didJoin = true
        }

        guard didJoin else { return nil }

        var path = pieces.joined()
        // Mirror libghostty's trailing-dot trimming (a path at the end of a
        // sentence, e.g. "see foo.md.").
        while path.hasSuffix(".") {
            path.removeLast()
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Helpers

    /// Drop trailing ASCII spaces from a row (libghostty emits written padding
    /// spaces because it reads with trim=false).
    private static func rightTrimmingSpaces(_ row: String) -> Substring {
        var sub = Substring(row)
        while sub.last == " " {
            sub = sub.dropLast()
        }
        return sub
    }

    private static func isPathChar(_ c: Character) -> Bool {
        pathCharacters.contains(c)
    }

    /// The contiguous path-character run covering `index`, or nil if the
    /// character at `index` is not a path character.
    private static func pathRun(in chars: [Character], containing index: Int) -> Range<Int>? {
        guard chars.indices.contains(index), isPathChar(chars[index]) else { return nil }
        var start = index
        while start > 0, isPathChar(chars[start - 1]) {
            start -= 1
        }
        var end = index + 1
        while end < chars.count, isPathChar(chars[end]) {
            end += 1
        }
        return start ..< end
    }

    /// The path-character run that begins the row's content (after any
    /// leading spaces). Nil if the first non-space character is not a path
    /// character — this guards against gutters / box-drawing prefixes.
    private static func leadingPathRun(in chars: [Character]) -> Range<Int>? {
        var start = 0
        while start < chars.count, chars[start] == " " {
            start += 1
        }
        guard start < chars.count, isPathChar(chars[start]) else { return nil }
        var end = start
        while end < chars.count, isPathChar(chars[end]) {
            end += 1
        }
        return start ..< end
    }

    /// The path-character run that ends the row, or nil if the last character
    /// is not a path character.
    private static func trailingPathRun(in chars: [Character]) -> Range<Int>? {
        guard let last = chars.last, isPathChar(last) else { return nil }
        var start = chars.count - 1
        while start > 0, isPathChar(chars[start - 1]) {
            start -= 1
        }
        return start ..< chars.count
    }

    /// Whether everything before `runStart` on the row is whitespace, i.e. the
    /// path run is the first content on the row.
    private static func isLeadingContent(_ chars: [Character], runStart: Int) -> Bool {
        guard runStart <= chars.count else { return false }
        return chars[0 ..< runStart].allSatisfy { $0 == " " }
    }

    /// Whether the row's content reaches the right edge. Reads omit trailing
    /// blanks, so a full row's character count equals `columns`; a 1-column
    /// fuzz tolerates a possible right-edge border cell.
    private static func rowFillsToEnd(_ chars: [Character], columns: Int) -> Bool {
        chars.count >= columns - 1
    }

    /// Whether a run ending at `runEnd` reaches the right edge of its row.
    private static func runReachesEnd(_ chars: [Character], runEnd: Int, columns: Int) -> Bool {
        runEnd == chars.count && rowFillsToEnd(chars, columns: columns)
    }
}
