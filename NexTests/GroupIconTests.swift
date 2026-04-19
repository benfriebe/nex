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

    @Test func isGraphemeEmojiRejectsPlainText() {
        #expect(Character("a").isGraphemeEmoji == false)
        #expect(Character("1").isGraphemeEmoji == false)
        #expect(Character("!").isGraphemeEmoji == false)
        #expect(Character(" ").isGraphemeEmoji == false)
    }
}
