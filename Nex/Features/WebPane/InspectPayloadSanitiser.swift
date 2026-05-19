import CoreGraphics
import Foundation

/// Strips dangerous control characters and clamps each field of an
/// inspect payload to a sensible byte budget before it crosses the
/// PTY boundary into an agent pane.
///
/// Web content can contain ANSI escape sequences (`ESC [ ... m`) or
/// raw C0 bytes that a terminal will happily interpret — pasting an
/// element's `outerHTML` should never accidentally reposition the
/// cursor, switch palette mode, or fire OSC 52 clipboard writes on
/// the receiver. Cap sizes match the plan (Phase 3 § sanitise):
///   - outer_html   16 KB
///   - context_html  4 KB
///   - attributes per-value 1 KB
///   - selector / xpath 1 KB
///
/// Truncated fields gain a `... [truncated]` marker so the agent
/// knows the payload isn't complete.
enum InspectPayloadSanitiser {
    static let outerHTMLBudget = 16 * 1024
    static let contextHTMLBudget = 4 * 1024
    static let attributeValueBudget = 1024
    static let selectorBudget = 1024

    static let truncationMarker = "... [truncated]"

    /// Shared ISO8601 formatter for inspect/console payload timestamps.
    /// Why: `ISO8601DateFormatter()` is expensive to instantiate; this is
    /// called per-inspect-payload, per-console-line, and on every batch
    /// item, so the formatter is cached once and reused. `nonisolated(unsafe)`
    /// because the formatter isn't `Sendable` but its `string(from:)` is
    /// documented thread-safe.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Decode the raw JSON dictionary the picker JS produced into a
    /// fully sanitised `InspectResult`. Returns nil only when the
    /// payload is so malformed there's nothing to surface (missing
    /// tag / selector / url all empty).
    static func decode(_ payload: [String: Any], tabID: UUID) -> InspectResult? {
        let selector = clampField(payload["selector"] as? String ?? "", limit: selectorBudget)
        let xpath = clampField(payload["xpath"] as? String ?? "", limit: selectorBudget)
        let tag = clampField(payload["tag"] as? String ?? "", limit: 64)
        let elementID = clampField(payload["element_id"] as? String ?? "", limit: 256)
        let outerHTML = clampField(payload["outer_html"] as? String ?? "", limit: outerHTMLBudget)
        let contextHTML = clampField(payload["context_html"] as? String ?? "", limit: contextHTMLBudget)
        let text = clampField(payload["text"] as? String ?? "", limit: 1024)
        let url = clampField(payload["url"] as? String ?? "", limit: 4096)

        // Drop genuinely empty payloads (no tag, no selector, no URL —
        // probably page JS spoofing despite the nonce check on the
        // Swift side).
        if selector.isEmpty, tag.isEmpty, url.isEmpty { return nil }

        var attributes: [String: String] = [:]
        if let raw = payload["attributes"] as? [String: Any] {
            for (key, value) in raw {
                let stringValue = (value as? String) ?? String(describing: value)
                attributes[clampField(key, limit: 128)] =
                    clampField(stringValue, limit: attributeValueBudget)
            }
        }

        var rect = CGRect.zero
        if let r = payload["rect"] as? [String: Any] {
            let x = (r["x"] as? Double) ?? 0
            let y = (r["y"] as? Double) ?? 0
            let w = (r["w"] as? Double) ?? 0
            let h = (r["h"] as? Double) ?? 0
            rect = CGRect(x: x, y: y, width: w, height: h)
        }

        return InspectResult(
            tabID: tabID,
            selector: selector,
            xpath: xpath,
            tag: tag,
            elementID: elementID,
            outerHTML: outerHTML,
            attributes: attributes,
            rect: rect,
            text: text,
            contextHTML: contextHTML,
            url: url,
            capturedAt: Date()
        )
    }

    /// Format a sanitised `InspectResult` for paste delivery into an
    /// agent pane via `paneSendText`. Output is a one-line directive
    /// followed by a fenced JSON block — easy for an LLM to detect
    /// and parse but human-readable on a terminal.
    static func formatForPaste(_ result: InspectResult) -> String {
        let timestamp = isoFormatter.string(from: result.capturedAt)

        // Build the JSON payload manually so the field order is
        // stable + easy for an agent to scan.
        var json: [String: Any] = [
            "selector": result.selector,
            "xpath": result.xpath,
            "tag": result.tag,
            "id": result.elementID,
            "url": result.url,
            "text": result.text,
            "rect": [
                "x": result.rect.origin.x,
                "y": result.rect.origin.y,
                "w": result.rect.size.width,
                "h": result.rect.size.height
            ],
            "attributes": result.attributes,
            "captured_at": timestamp
        ]
        if !result.outerHTML.isEmpty { json["outer_html"] = result.outerHTML }
        if !result.contextHTML.isEmpty { json["context_html"] = result.contextHTML }

        let body: String = {
            guard let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ),
                let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()

        return """
        # nex inspect \(timestamp)
        ```json
        \(body)
        ```
        """
    }

    /// Format a batch of annotated inspect results for paste delivery.
    /// Emits a single fenced JSON array, with each entry carrying the
    /// same sanitised fields as `formatForPaste` plus the user-supplied
    /// `comment`. Header timestamp marks the moment the batch was sent.
    static func formatBatchForPaste(_ items: [BatchInspectItem]) -> String {
        let timestamp = isoFormatter.string(from: Date())

        let array: [[String: Any]] = items.map { item in
            let result = item.result
            let captured = isoFormatter.string(from: result.capturedAt)
            var entry: [String: Any] = [
                "selector": result.selector,
                "xpath": result.xpath,
                "tag": result.tag,
                "id": result.elementID,
                "url": result.url,
                "text": result.text,
                "rect": [
                    "x": result.rect.origin.x,
                    "y": result.rect.origin.y,
                    "w": result.rect.size.width,
                    "h": result.rect.size.height
                ],
                "attributes": result.attributes,
                "captured_at": captured,
                "comment": clampField(item.comment, limit: 4 * 1024)
            ]
            if !result.outerHTML.isEmpty { entry["outer_html"] = result.outerHTML }
            if !result.contextHTML.isEmpty { entry["context_html"] = result.contextHTML }
            return entry
        }

        let body: String = {
            guard let data = try? JSONSerialization.data(
                withJSONObject: array,
                options: [.prettyPrinted, .sortedKeys]
            ),
                let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }()

        return """
        # nex inspect batch \(timestamp) (\(items.count) item\(items.count == 1 ? "" : "s"))
        ```json
        \(body)
        ```
        """
    }

    // MARK: - Internals

    /// Strip ANSI escape sequences and C0 control chars (except `\n`
    /// and `\t`), then byte-clamp to `limit`, appending a truncation
    /// marker when shorter than the input.
    static func clampField(_ raw: String, limit: Int) -> String {
        let stripped = stripUnsafeControlCharacters(raw)
        if stripped.utf8.count <= limit { return stripped }
        // Trim on a UTF-8 boundary, leave room for the marker.
        let budget = max(limit - truncationMarker.utf8.count, 0)
        var truncated = stripped
        while truncated.utf8.count > budget {
            truncated.removeLast()
        }
        return truncated + truncationMarker
    }

    /// Remove ANSI escape sequences (CSI / OSC etc.) and C0 control
    /// chars except newline + tab. Keeps the output paste-safe on a
    /// terminal without mangling whitespace inside an HTML snippet.
    static func stripUnsafeControlCharacters(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var output = String()
        output.reserveCapacity(input.utf8.count)

        var iterator = input.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            // ESC at U+001B starts an ANSI sequence. Drop ESC and
            // skip the rest of the sequence per the rough ANSI
            // grammar: CSI (`ESC [`) / OSC (`ESC ]`) / two-char
            // (`ESC <byte>`).
            if scalar.value == 0x1B {
                if let next = iterator.next() {
                    if next.value == 0x5B { // ESC [ → CSI: skip until final byte 0x40–0x7E
                        while let csiByte = iterator.next() {
                            if csiByte.value >= 0x40, csiByte.value <= 0x7E { break }
                        }
                    } else if next.value == 0x5D { // ESC ] → OSC: skip until BEL or ESC \
                        while let oscByte = iterator.next() {
                            if oscByte.value == 0x07 { break } // BEL terminator
                            if oscByte.value == 0x1B { // ESC \ terminator (ST)
                                _ = iterator.next()
                                break
                            }
                        }
                    }
                    // Two-char sequence (ESC c, ESC =, etc.) — drop both.
                }
                continue
            }
            // Allow \n (0x0A), \t (0x09); strip every other C0.
            if scalar.value < 0x20, scalar.value != 0x0A, scalar.value != 0x09 {
                continue
            }
            // Strip DEL (0x7F).
            if scalar.value == 0x7F { continue }
            output.unicodeScalars.append(scalar)
        }
        return output
    }
}
