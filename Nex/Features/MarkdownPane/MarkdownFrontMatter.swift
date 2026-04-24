import Foundation
import Yams

/// Maximum size of a YAML front-matter block we'll try to parse. Files with a
/// larger block fall through as "no front-matter" to guard against
/// pathological / YAML-bomb inputs.
private let frontMatterSizeCapBytes = 64 * 1024

enum FrontMatterExtractor {
    /// Returns `(yaml, body)`. `yaml` is nil when the markdown does not begin
    /// with a well-formed `---\n...\n---\n` block (or the block exceeds the
    /// size cap). `body` is the markdown with the front-matter block removed.
    static func extract(_ markdown: String) -> (yaml: String?, body: String) {
        var input = markdown
        // Strip a single leading BOM.
        if input.first == "\u{FEFF}" {
            input.removeFirst()
        }

        // In Swift, "\r\n" is one extended grapheme cluster — a single Character
        // — so we match any of \n, \r\n, or \r as a line terminator.
        let isLineEnd: (Character) -> Bool = { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }

        // A fence line is `---` or `...` at column 0, optionally followed by
        // spaces/tabs, and nothing else. Leading whitespace disqualifies — we
        // don't want an indented `---` inside body prose to be interpreted as
        // a fence.
        let isFence: (Substring, String) -> Bool = { line, marker in
            guard line.hasPrefix(marker) else { return false }
            let rest = line.dropFirst(marker.count)
            return rest.allSatisfy { $0 == " " || $0 == "\t" }
        }

        // Opening fence: the very first line must be `---` (+ trailing ws).
        guard let firstNewline = input.firstIndex(where: isLineEnd) else {
            return (nil, markdown)
        }
        let firstLine = input[input.startIndex ..< firstNewline]
        guard isFence(firstLine, "---") else {
            return (nil, markdown)
        }

        // Scan subsequent lines for a closing fence of `---` or `...`, tracking
        // UTF-8 bytes so we bail on pathological input before materializing the
        // YAML substring.
        var cursor = input.index(after: firstNewline)
        var bytesScanned = 0
        while cursor < input.endIndex {
            let lineEnd = input[cursor...].firstIndex(where: isLineEnd) ?? input.endIndex
            let line = input[cursor ..< lineEnd]
            if isFence(line, "---") || isFence(line, "...") {
                let yamlStart = input.index(after: firstNewline)
                let yamlEnd = cursor
                // Drop the trailing newline between last YAML line and fence.
                let yaml = String(input[yamlStart ..< yamlEnd]).trimmingTrailingNewline()

                // Body = everything after the closing fence's newline.
                let afterFence: String.Index = if lineEnd < input.endIndex {
                    input.index(after: lineEnd)
                } else {
                    input.endIndex
                }
                let body = String(input[afterFence...])
                return (yaml, body)
            }
            // +1 accounts for the newline that ended this line (not present
            // only when we hit end-of-input, in which case we'll break below).
            bytesScanned += line.utf8.count + 1
            if bytesScanned > frontMatterSizeCapBytes {
                return (nil, markdown)
            }
            if lineEnd == input.endIndex { break }
            cursor = input.index(after: lineEnd)
        }

        return (nil, markdown)
    }
}

enum FrontMatterRenderer {
    /// Renders a YAML front-matter block as HTML. Returns `""` when the block
    /// is empty or produces an empty mapping.
    ///
    /// - Well-formed mapping → styled `<table class="frontmatter">`.
    /// - Malformed YAML or non-mapping root → `<pre class="frontmatter-raw">`
    ///   with the raw (escaped) YAML.
    static func render(_ yaml: String) -> String {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            return rawFallback(yaml)
        }
        guard let node, let mapping = node.mapping else {
            return rawFallback(yaml)
        }
        if mapping.isEmpty { return "" }

        var rows = ""
        for (keyNode, valueNode) in mapping {
            let keyText = keyNode.scalar?.string ?? String(describing: keyNode)
            let key = escapeHTML(keyText)
            let value = renderValue(valueNode)
            rows += "<tr><th scope=\"row\">\(key)</th><td>\(value)</td></tr>\n"
        }
        return "<table class=\"frontmatter\">\n<tbody>\n\(rows)</tbody>\n</table>\n"
    }

    private static func renderValue(_ node: Node) -> String {
        switch node {
        case let .scalar(scalar):
            // Multi-line scalars (block `|`, folded `>`, or any value that
            // contains a newline) would otherwise collapse in a <td>; route
            // them to a pre so line breaks survive.
            if scalar.string.contains("\n") {
                return nestedPre(node)
            }
            return escapeHTML(scalar.string)
        case let .sequence(seq):
            // Only comma-join if every child is a SINGLE-LINE scalar; a
            // multiline block scalar inside the sequence would otherwise
            // collapse inside the <td>.
            let allSingleLineScalars = seq.allSatisfy {
                if let s = $0.scalar?.string { return !s.contains("\n") }
                return false
            }
            if allSingleLineScalars {
                let parts = seq.map { escapeHTML($0.scalar?.string ?? "") }
                return parts.joined(separator: ", ")
            }
            return nestedPre(node)
        case .mapping:
            return nestedPre(node)
        case let .alias(alias):
            // Show the YAML alias source form (`*name`) rather than a bare
            // identifier that would look like an orphaned word.
            return escapeHTML("*\(alias.anchor.rawValue)")
        }
    }

    private static func nestedPre(_ node: Node) -> String {
        let serialized = (try? Yams.serialize(node: node)) ?? ""
        let cleaned = serialized.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<pre class=\"frontmatter-nested\">\(escapeHTML(cleaned))</pre>"
    }

    private static func rawFallback(_ yaml: String) -> String {
        "<pre class=\"frontmatter-raw\">\(escapeHTML(yaml))</pre>\n"
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension String {
    /// Drops a single trailing newline grapheme (`\n`, `\r\n`, or `\r`) so the
    /// YAML text doesn't carry the newline that precedes the closing fence.
    /// Swift treats `\r\n` as a single extended grapheme cluster, hence one
    /// `dropLast()` call covers all three forms.
    func trimmingTrailingNewline() -> String {
        if let last, last == "\n" || last == "\r\n" || last == "\r" {
            return String(dropLast())
        }
        return self
    }
}
