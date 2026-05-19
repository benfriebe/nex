import CoreGraphics
import Foundation
@testable import Nex
import Testing

struct InspectPayloadSanitiserTests {
    private static let tabID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - stripUnsafeControlCharacters

    @Test func stripsCSIEscapeSequence() {
        // ESC [ 31 m (red) text ESC [ 0 m
        let input = "\u{1B}[31mhello\u{1B}[0m"
        let stripped = InspectPayloadSanitiser.stripUnsafeControlCharacters(input)
        #expect(stripped == "hello")
    }

    @Test func stripsOSCEscapeSequenceWithBEL() {
        // ESC ] 52;c;... BEL — clipboard write the receiver shouldn't honour.
        let input = "before\u{1B}]52;c;abc\u{07}after"
        let stripped = InspectPayloadSanitiser.stripUnsafeControlCharacters(input)
        #expect(stripped == "beforeafter")
    }

    @Test func stripsOSCEscapeSequenceWithST() {
        // ESC ] 0;title ESC \ — terminal title set (ST = ESC + backslash).
        let input = "x\u{1B}]0;evil\u{1B}\\y"
        let stripped = InspectPayloadSanitiser.stripUnsafeControlCharacters(input)
        #expect(stripped == "xy")
    }

    @Test func stripsTwoCharEscape() {
        // ESC c (full reset)
        let input = "x\u{1B}cy"
        let stripped = InspectPayloadSanitiser.stripUnsafeControlCharacters(input)
        #expect(stripped == "xy")
    }

    @Test func keepsNewlineAndTab() {
        let input = "line1\nline2\tcol"
        let stripped = InspectPayloadSanitiser.stripUnsafeControlCharacters(input)
        #expect(stripped == "line1\nline2\tcol")
    }

    @Test func stripsOtherC0() {
        // BEL alone, vertical tab, etc.
        let input = "a\u{07}b\u{0B}c\u{00}d"
        let stripped = InspectPayloadSanitiser.stripUnsafeControlCharacters(input)
        #expect(stripped == "abcd")
    }

    @Test func stripsDEL() {
        let input = "a\u{7F}b"
        let stripped = InspectPayloadSanitiser.stripUnsafeControlCharacters(input)
        #expect(stripped == "ab")
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(InspectPayloadSanitiser.stripUnsafeControlCharacters("") == "")
    }

    // MARK: - clampField

    @Test func clampUnderLimitReturnsUnchanged() {
        let input = "short"
        #expect(InspectPayloadSanitiser.clampField(input, limit: 100) == "short")
    }

    @Test func clampAtLimitReturnsUnchanged() {
        let input = String(repeating: "a", count: 16)
        #expect(InspectPayloadSanitiser.clampField(input, limit: 16) == input)
    }

    @Test func clampOverLimitAppendsMarker() {
        let input = String(repeating: "a", count: 200)
        let clamped = InspectPayloadSanitiser.clampField(input, limit: 64)
        #expect(clamped.utf8.count == 64)
        #expect(clamped.hasSuffix(InspectPayloadSanitiser.truncationMarker))
    }

    @Test func clampStripsBeforeMeasuring() {
        // Stripped length fits the budget so no truncation should happen.
        let input = "\u{1B}[31mhello\u{1B}[0m"
        #expect(InspectPayloadSanitiser.clampField(input, limit: 16) == "hello")
    }

    @Test func clampMultiByteStaysOnUTF8Boundary() {
        // Each emoji is 4 UTF-8 bytes. Limit forces truncation
        // partway through; clamped output must still decode.
        let input = String(repeating: "🚀", count: 10) // 40 bytes
        let clamped = InspectPayloadSanitiser.clampField(input, limit: 32)
        #expect(clamped.utf8.count <= 32)
        // Should decode round-trip to a valid string ending in the marker.
        #expect(clamped.hasSuffix(InspectPayloadSanitiser.truncationMarker))
        let strippedPrefix = clamped.dropLast(InspectPayloadSanitiser.truncationMarker.count)
        // All remaining graphemes should be the rocket emoji (no broken
        // partial code unit).
        #expect(strippedPrefix.allSatisfy { $0 == "🚀" })
    }

    @Test func clampLimitSmallerThanMarkerStillBounded() {
        // When the budget can't fit the marker, the helper still
        // shouldn't crash — it should return at most a marker-sized
        // output without exceeding any growth.
        let input = String(repeating: "a", count: 100)
        let clamped = InspectPayloadSanitiser.clampField(input, limit: 4)
        // No precondition: just that it returns something and didn't trap.
        #expect(clamped.hasSuffix(InspectPayloadSanitiser.truncationMarker))
    }

    // MARK: - decode

    @Test func decodeReturnsNilForEmptyPayload() {
        // No selector, no tag, no url → nothing useful to surface.
        let payload: [String: Any] = ["outer_html": ""]
        #expect(InspectPayloadSanitiser.decode(payload, tabID: Self.tabID) == nil)
    }

    @Test func decodeAcceptsMinimalPayload() {
        let payload: [String: Any] = ["tag": "div", "selector": "#foo"]
        let result = InspectPayloadSanitiser.decode(payload, tabID: Self.tabID)
        #expect(result?.tag == "div")
        #expect(result?.selector == "#foo")
        #expect(result?.tabID == Self.tabID)
    }

    @Test func decodeClampsOversizedOuterHTML() {
        let huge = String(repeating: "x", count: 32 * 1024)
        let payload: [String: Any] = ["tag": "div", "selector": "#foo", "outer_html": huge]
        let result = InspectPayloadSanitiser.decode(payload, tabID: Self.tabID)
        #expect(result?.outerHTML.utf8.count == InspectPayloadSanitiser.outerHTMLBudget)
        #expect(result?.outerHTML.hasSuffix(InspectPayloadSanitiser.truncationMarker) == true)
    }

    @Test func decodeStripsAnsiFromAttributes() {
        let payload: [String: Any] = [
            "tag": "div",
            "selector": "#foo",
            "attributes": ["data-x": "\u{1B}[31mred\u{1B}[0m"]
        ]
        let result = InspectPayloadSanitiser.decode(payload, tabID: Self.tabID)
        #expect(result?.attributes["data-x"] == "red")
    }

    @Test func decodeParsesRect() {
        let payload: [String: Any] = [
            "tag": "button",
            "selector": "button",
            "rect": ["x": 1.5, "y": 2.5, "w": 100.0, "h": 30.0]
        ]
        let result = InspectPayloadSanitiser.decode(payload, tabID: Self.tabID)
        #expect(result?.rect == CGRect(x: 1.5, y: 2.5, width: 100.0, height: 30.0))
    }

    // MARK: - formatForPaste

    @Test func formatForPasteIncludesFencedJSON() {
        let result = InspectResult(
            tabID: Self.tabID,
            selector: "#foo",
            xpath: "/html/body/div[1]",
            tag: "div",
            elementID: "foo",
            outerHTML: "<div id=\"foo\">hi</div>",
            attributes: ["class": "bar"],
            rect: CGRect(x: 0, y: 0, width: 10, height: 10),
            text: "hi",
            contextHTML: "<body><div id=\"foo\">hi</div></body>",
            url: "https://example.com",
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let formatted = InspectPayloadSanitiser.formatForPaste(result)
        #expect(formatted.contains("# nex inspect"))
        #expect(formatted.contains("```json"))
        #expect(formatted.contains("\"selector\""))
        #expect(formatted.contains("\"#foo\""))
    }

    @Test func formatBatchForPasteIncludesEachComment() {
        let r = InspectResult(
            tabID: Self.tabID, selector: "#a", xpath: "/", tag: "div",
            elementID: "", outerHTML: "", attributes: [:],
            rect: .zero, text: "", contextHTML: "", url: "",
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let items = [
            BatchInspectItem(result: r, comment: "first comment"),
            BatchInspectItem(result: r, comment: "second comment")
        ]
        let formatted = InspectPayloadSanitiser.formatBatchForPaste(items)
        #expect(formatted.contains("(2 items)"))
        #expect(formatted.contains("first comment"))
        #expect(formatted.contains("second comment"))
    }

    @Test func inspectResultDefaultCommentIsEmpty() {
        // Single-shot picker captures should never carry a comment;
        // the field is purely a batch-mode annotation slot.
        let payload: [String: Any] = ["tag": "div", "selector": "#x"]
        let result = InspectPayloadSanitiser.decode(payload, tabID: Self.tabID)
        #expect(result?.comment == "")
    }

    @Test func formatBatchSingularItemHeader() {
        let r = InspectResult(
            tabID: Self.tabID, selector: "#a", xpath: "/", tag: "div",
            elementID: "", outerHTML: "", attributes: [:],
            rect: .zero, text: "", contextHTML: "", url: "",
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let formatted = InspectPayloadSanitiser.formatBatchForPaste([
            BatchInspectItem(result: r, comment: "")
        ])
        #expect(formatted.contains("(1 item)"))
        #expect(!formatted.contains("(1 items)"))
    }
}
