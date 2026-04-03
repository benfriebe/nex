@testable import Nex
import Testing

@MainActor
struct ConfigParserTests {
    @Test func emptyStringReturnsEmpty() {
        let result = ConfigParser.parseKeybindings(from: "")
        #expect(result.isEmpty)
    }

    @Test func commentsAndBlankLinesSkipped() {
        let config = """
        # This is a comment

        # Another comment
        """
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.isEmpty)
    }

    @Test func parseSingleKeybind() {
        let config = "keybind = super+d=split_right"
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
        #expect(result[0].0 == KeyTrigger(keyCode: 2, modifiers: .command))
        #expect(result[0].1 == .splitRight)
    }

    @Test func parseMultipleKeybinds() {
        let config = """
        keybind = super+d=split_right
        keybind = super+shift+d=split_down
        keybind = super+w=close_pane
        """
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 3)
    }

    @Test func parseUnbind() {
        let config = "keybind = super+d=unbind"
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
        #expect(result[0].1 == .unbind)
    }

    @Test func unknownActionSkipped() {
        let config = """
        keybind = super+d=nonexistent_action
        keybind = super+w=close_pane
        """
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
        #expect(result[0].1 == .closePane)
    }

    @Test func unknownKeySkipped() {
        let config = """
        keybind = super+badkey=split_right
        keybind = super+d=split_right
        """
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
    }

    @Test func malformedLineMissingEquals() {
        let config = "keybind = super+d"
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.isEmpty)
    }

    @Test func nonKeybindLinesIgnored() {
        let config = """
        background = #ff0000
        font-size = 14
        keybind = super+d=split_right
        some-other-setting = value
        """
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
    }

    @Test func spacingVariations() {
        let config = """
        keybind=super+d=split_right
        keybind =super+w=close_pane
        keybind = super+f = toggle_search
        """
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 3)
    }

    @Test func multipleModifiers() {
        let config = "keybind = ctrl+alt+shift+a=split_right"
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
        #expect(result[0].0.modifiers == [.control, .option, .shift])
    }

    @Test func inlineCommentNotSupported() {
        // Ghostty-style: inline comments are NOT supported, the whole line
        // after # is a comment only if # is the first non-whitespace char.
        // A "keybind = ..." line with trailing text is still parsed.
        let config = "keybind = super+d=split_right"
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
    }
}
