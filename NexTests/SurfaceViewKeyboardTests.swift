import AppKit
@testable import Nex
import Testing

@MainActor
struct SurfaceViewKeyboardTests {
    private func keyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String = "",
        charactersIgnoringModifiers: String = ""
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test func optionIsNotConsumedWhenTranslationDropsOption() {
        let event = keyEvent(
            keyCode: 3,
            modifierFlags: .option,
            characters: "ƒ",
            charactersIgnoringModifiers: "f"
        )

        let key = SurfaceView.keyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            translationFlags: []
        )

        #expect(key.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(key.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue == 0)
    }

    @Test func optionIsConsumedWhenTranslationKeepsOption() {
        let event = keyEvent(
            keyCode: 3,
            modifierFlags: .option,
            characters: "ƒ",
            charactersIgnoringModifiers: "f"
        )

        let key = SurfaceView.keyEvent(from: event, action: GHOSTTY_ACTION_PRESS)

        #expect(key.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(key.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
    }

    @Test func rightOptionSetsAltSideBit() {
        let rightOption = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK)
        )

        let mods = SurfaceView.mods(fromFlags: rightOption)

        #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue != 0)
    }

    @Test func eventModifierFlagsConvertsVisibleGhosttyMods() {
        let mods = ghostty_input_mods_e(
            rawValue: GHOSTTY_MODS_SHIFT.rawValue
                | GHOSTTY_MODS_CTRL.rawValue
                | GHOSTTY_MODS_ALT.rawValue
                | GHOSTTY_MODS_SUPER.rawValue
                | GHOSTTY_MODS_CAPS.rawValue
        )

        let flags = SurfaceView.eventModifierFlags(fromMods: mods)

        #expect(flags.contains(.shift))
        #expect(flags.contains(.control))
        #expect(flags.contains(.option))
        #expect(flags.contains(.command))
        #expect(flags.contains(.capsLock))
    }

    @Test func ghosttyCharactersPassesThroughPrintableText() {
        let event = keyEvent(
            keyCode: 3,
            characters: "f",
            charactersIgnoringModifiers: "f"
        )

        #expect(SurfaceView.ghosttyCharacters(from: event) == "f")
    }

    @Test func ghosttyCharactersStripsControlForCtrlJ() {
        // Ctrl+J produces U+000A (newline). ghostty handles control-character
        // encoding internally, so we return the un-controlled character ("j")
        // and let ghostty re-encode it based on terminal mode.
        let event = keyEvent(
            keyCode: 0x26,
            modifierFlags: .control,
            characters: "\n",
            charactersIgnoringModifiers: "j"
        )

        #expect(SurfaceView.ghosttyCharacters(from: event) == "j")
    }

    @Test func ghosttyCharactersReturnsNilForPUAFunctionKey() {
        // F1 lives in NSEvent's PUA range (U+F704). Returning it as text would
        // poison ghostty's input; we expect nil so the keycode path handles it.
        let event = keyEvent(
            keyCode: 0x7A,
            characters: "\u{F704}",
            charactersIgnoringModifiers: "\u{F704}"
        )

        #expect(SurfaceView.ghosttyCharacters(from: event) == nil)
    }

    @Test func ghosttyCharactersPassesThroughMultiCharacterStrings() {
        // Multi-scalar strings (dead-key composition, surrogate pairs, etc.)
        // skip the single-character special cases and pass through verbatim.
        let event = keyEvent(
            keyCode: 0,
            characters: "é",
            charactersIgnoringModifiers: "e"
        )

        #expect(SurfaceView.ghosttyCharacters(from: event) == "é")
    }

    // MARK: - ghosttyText (text filter for libghostty key.text)

    @Test func ghosttyTextFiltersBackTabControlByte() {
        // Shift+Tab gives us NSBackTabCharacter (0x19). libghostty's keymap must
        // encode it as CSI Z, so we strip the raw text and rely on keycode+mods.
        #expect(SurfaceView.ghosttyText(from: "\u{19}") == nil)
    }

    @Test func ghosttyTextFiltersReturnControlByte() {
        // Ctrl+Enter's text (0x0D) — upstream's motivating example for this filter.
        #expect(SurfaceView.ghosttyText(from: "\r") == nil)
    }

    @Test func ghosttyTextFiltersTabControlByte() {
        // Plain Tab (0x09). Pre-filter we'd send "\t" as text; post-filter we
        // rely on the keymap, which produces the same byte on the PTY.
        #expect(SurfaceView.ghosttyText(from: "\t") == nil)
    }

    @Test func ghosttyTextPassesThroughDelete() {
        // 0x7F (DEL) is not < 0x20 and intentionally flows through as text.
        // Matches upstream Ghostty's threshold — pinning to document the choice.
        #expect(SurfaceView.ghosttyText(from: "\u{7F}") == "\u{7F}")
    }

    @Test func ghosttyTextPassesThroughSpace() {
        // Ctrl+Space lands here as " " (after ghosttyCharacters strips control).
        // 0x20 is the threshold, so space passes through.
        #expect(SurfaceView.ghosttyText(from: " ") == " ")
    }

    @Test func ghosttyTextPassesThroughPrintable() {
        #expect(SurfaceView.ghosttyText(from: "f") == "f")
    }

    @Test func ghosttyTextPassesThroughMultiByteUnicode() {
        #expect(SurfaceView.ghosttyText(from: "é") == "é")
    }

    @Test func ghosttyTextPassesThroughEmojiAndZWJ() {
        // Astral / surrogate-pair / ZWJ sequences start with high UTF-8
        // bytes (0xF0+ for astral, 0xE2 for ZWJ U+200D). The filter checks
        // first UTF-8 byte (not first scalar), so they pass through.
        #expect(SurfaceView.ghosttyText(from: "🎉") == "🎉")
        #expect(SurfaceView.ghosttyText(from: "👨‍👩‍👧") == "👨‍👩‍👧")
    }

    @Test func ghosttyTextReturnsNilForNilInput() {
        #expect(SurfaceView.ghosttyText(from: nil) == nil)
    }

    @Test func ghosttyTextReturnsNilForEmptyInput() {
        #expect(SurfaceView.ghosttyText(from: "") == nil)
    }

    @Test func shiftTabRoundTripFiltersToNil() {
        // End-to-end regression check for issue #134: Shift+Tab through both
        // helpers should yield nil so the keymap encodes CSI Z.
        let event = keyEvent(
            keyCode: 48,
            modifierFlags: .shift,
            characters: "\u{19}",
            charactersIgnoringModifiers: "\t"
        )

        let text = SurfaceView.ghosttyText(from: SurfaceView.ghosttyCharacters(from: event))
        #expect(text == nil)
    }
}
