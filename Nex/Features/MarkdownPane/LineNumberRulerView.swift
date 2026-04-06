import AppKit

/// A ruler view that draws line numbers in the gutter of an NSTextView.
final class LineNumberRulerView: NSRulerView {
    private let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let gutterPadding: CGFloat = 8
    private let textPadding: CGFloat = 4
    private let minimumThickness: CGFloat = 36

    /// Cached newline offsets for O(1) line-number lookup during scroll.
    /// Index i holds the string index of the start of line i+1.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = minimumThickness
        rebuildLineStarts()
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Call when the text content changes programmatically (e.g. loading a new file).
    func invalidateLineCount() {
        rebuildLineStarts()
        updateThickness()
        needsDisplay = true
    }

    // MARK: - Line start cache

    private func rebuildLineStarts() {
        guard let string = (clientView as? NSTextView)?.string else {
            lineStarts = [0]
            return
        }
        var starts = [0]
        let nsString = string as NSString
        var index = 0
        while index < nsString.length {
            if nsString.character(at: index) == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        lineStarts = starts
    }

    /// Binary search for the line number (1-based) containing `charIndex`.
    private func lineNumber(for charIndex: Int) -> Int {
        var lo = 0
        var hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= charIndex {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo // 1-based because lineStarts[0] == 0 and we return lo after overshoot
    }

    // MARK: - Thickness

    private func updateThickness() {
        let totalLines = lineStarts.count
        let maxStr = "\(totalLines)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: lineNumberFont]
        let needed = maxStr.size(withAttributes: attrs).width + gutterPadding + textPadding
        let newThickness = max(needed, minimumThickness)
        if abs(newThickness - ruleThickness) > 1 {
            ruleThickness = newThickness
        }
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in _: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView!.contentView.bounds
        let textInset = textView.textContainerInset

        let attrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let string = textView.string as NSString
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // O(log n) lookup instead of scanning from the start
        var lineNumber = lineNumber(for: charRange.location)

        // Walk visible lines and draw their numbers
        var charIndex = charRange.location
        while charIndex < NSMaxRange(charRange) {
            let lineRange = string.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)

            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.y += textInset.height - visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let size = numStr.size(withAttributes: attrs)
            let x = ruleThickness - size.width - textPadding
            let y = lineRect.origin.y + (lineRect.height - size.height) / 2

            numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }

        // Handle the empty last line (after trailing newline) or empty document
        if string.length == 0 || (string.length > 0 && string.character(at: string.length - 1) == 0x0A) {
            if charIndex == string.length, charIndex <= NSMaxRange(charRange) || string.length == 0 {
                var lineRect: NSRect
                if string.length == 0 {
                    // No glyphs exist yet so lineFragmentRect returns .zero.
                    // Use the layout manager's own default line height so the
                    // "1" sits at exactly the same y as after the first keystroke.
                    let font = textView.font ?? lineNumberFont
                    let lineHeight = layoutManager.defaultLineHeight(for: font)
                    lineRect = NSRect(x: 0, y: 0, width: 0, height: lineHeight)
                } else {
                    let glyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
                    lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                    lineRect.origin.y += lineRect.height
                }
                lineRect.origin.y += textInset.height - visibleRect.origin.y

                let numStr = "\(lineNumber)" as NSString
                let size = numStr.size(withAttributes: attrs)
                let x = ruleThickness - size.width - textPadding
                let y = lineRect.origin.y + (lineRect.height - size.height) / 2

                numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            }
        }
    }
}
