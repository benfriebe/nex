import Foundation
@testable import Nex
import Testing

struct GroupIconTests {
    @Test func systemNameStorageRoundTrip() {
        let icon: GroupIcon = .systemName("star.fill")
        #expect(icon.storageString == "system:star.fill")
        #expect(GroupIcon(storageString: "system:star.fill") == icon)
    }

    @Test func emojiStorageRoundTrip() {
        let icon: GroupIcon = .emoji("🔥")
        #expect(icon.storageString == "emoji:🔥")
        #expect(GroupIcon(storageString: "emoji:🔥") == icon)
    }

    @Test func unknownPrefixReturnsNil() {
        #expect(GroupIcon(storageString: "bogus:whatever") == nil)
    }

    @Test func emptyPayloadReturnsNil() {
        // Empty after the prefix is meaningless — a missing name or
        // missing emoji would render nothing, so drop back to folder.
        #expect(GroupIcon(storageString: "system:") == nil)
        #expect(GroupIcon(storageString: "emoji:") == nil)
    }

    // MARK: - Character.isGraphemeEmoji

    @Test func isGraphemeEmojiAcceptsEmoji() {
        #expect(Character("🎨").isGraphemeEmoji)
        #expect(Character("🔥").isGraphemeEmoji)
        #expect(Character("❤️").isGraphemeEmoji) // U+2764 + U+FE0F
        #expect(Character("1️⃣").isGraphemeEmoji) // keycap
        #expect(Character("👨‍👩‍👧‍👦").isGraphemeEmoji) // ZWJ family
    }

    @Test func isGraphemeEmojiAcceptsBareTextPresentationEmoji() {
        // Emoji=Yes scalars whose default presentation is text; the
        // palette usually appends U+FE0F but bare pastes must pass too.
        #expect(Character("✂").isGraphemeEmoji) // U+2702
        #expect(Character("ℹ").isGraphemeEmoji) // U+2139
        #expect(Character("©").isGraphemeEmoji) // U+00A9
        #expect(Character("☂︎").isGraphemeEmoji) // U+2602 + text selector U+FE0E
    }

    @Test func isGraphemeEmojiAcceptsNonEmojiPictographs() {
        // No Unicode emoji properties at all, but offered by the macOS
        // character palette — the issue #254 regression class.
        #expect(Character("⛙").isGraphemeEmoji) // U+26D9, the issue's char
        #expect(Character("♞").isGraphemeEmoji) // U+265E chess knight
        #expect(Character("→").isGraphemeEmoji) // U+2192, math symbol
        #expect(Character("⌘").isGraphemeEmoji) // U+2318
        #expect(Character("£").isGraphemeEmoji) // U+00A3, currency symbol
        #expect(Character("°").isGraphemeEmoji) // U+00B0
    }

    @Test func isGraphemeEmojiRejectsPlainText() {
        #expect(Character("a").isGraphemeEmoji == false)
        #expect(Character("1").isGraphemeEmoji == false)
        #expect(Character("!").isGraphemeEmoji == false)
        #expect(Character(" ").isGraphemeEmoji == false)
        // ASCII with Emoji=Yes — the ASCII guard must beat tier 2.
        #expect(Character("#").isGraphemeEmoji == false)
        #expect(Character("*").isGraphemeEmoji == false)
        // ASCII Symbol categories — the ASCII guard must beat tier 3.
        #expect(Character("$").isGraphemeEmoji == false)
        #expect(Character("=").isGraphemeEmoji == false)
        #expect(Character("+").isGraphemeEmoji == false)
    }

    @Test func isGraphemeEmojiRejectsNonASCIILettersAndDigits() {
        #expect(Character("Ω").isGraphemeEmoji == false)
        #expect(Character("あ").isGraphemeEmoji == false)
        #expect(Character("７").isGraphemeEmoji == false) // fullwidth digit
        #expect(Character("¡").isGraphemeEmoji == false) // non-ASCII punctuation
    }

    @Test func isGraphemeEmojiRejectsInvisiblesAndBareMarks() {
        // A lone variation selector is invisible; persisting it would
        // render an empty avatar.
        #expect(Character("\u{FE0F}").isGraphemeEmoji == false)
        #expect(Character("\u{200D}").isGraphemeEmoji == false) // lone ZWJ
        #expect(Character("\u{0301}").isGraphemeEmoji == false) // combining accent
        // Keycap without the U+FE0F the palette inserts: first scalar
        // is ASCII "1", so it stays rejected — a documented limitation
        // (the palette always emits the U+FE0F form).
        #expect(Character("1\u{20E3}").isGraphemeEmoji == false)
    }

    @Test func isGraphemeEmojiRejectsVS16OnNonEmojiBase() {
        // U+FE0F only counts on an emoji-capable base — tacking a
        // variation selector onto a letter must not smuggle it past
        // the letter/digit rejection.
        #expect(Character("a\u{FE0F}").isGraphemeEmoji == false)
        #expect(Character("!\u{FE0F}").isGraphemeEmoji == false)
        #expect(Character("Ω\u{FE0F}").isGraphemeEmoji == false)
        #expect(Character("\u{FE0F}\u{20E3}").isGraphemeEmoji == false) // headless keycap
        // Digits carry Emoji=Yes, so a digit + VS16 is a valid Unicode
        // emoji presentation sequence and stays accepted.
        #expect(Character("1\u{FE0F}").isGraphemeEmoji)
        // A skin-tone modifier glued to a letter forms one grapheme;
        // anchoring tier 1 on the base scalar keeps it out.
        #expect(Character("a\u{1F3FB}").isGraphemeEmoji == false)
        // Sk spacing accents are excluded from the symbol tier.
        #expect(Character("´").isGraphemeEmoji == false)
    }
}
