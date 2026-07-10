import Foundation
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

    @Test func parseThemeSetting() {
        let result = ConfigParser.parseGeneralSettings(from: "theme = Dracula")
        #expect(result.theme == "Dracula")
    }

    @Test func parseThemePreservesCase() {
        let result = ConfigParser.parseGeneralSettings(from: "theme = Catppuccin Mocha")
        #expect(result.theme == "Catppuccin Mocha")
    }

    @Test func parseRenameWorkspace() {
        let config = "keybind = super+shift+r=rename_workspace"
        let result = ConfigParser.parseKeybindings(from: config)
        #expect(result.count == 1)
        #expect(result[0].0 == KeyTrigger(keyCode: 15, modifiers: [.command, .shift]))
        #expect(result[0].1 == .renameWorkspace)
    }

    // MARK: - TCP Port

    @Test func parseTCPPort() {
        let result = ConfigParser.parseGeneralSettings(from: "tcp-port = 19400")
        #expect(result.tcpPort == 19400)
    }

    @Test func parseTCPPortZeroMeansDisabled() {
        let result = ConfigParser.parseGeneralSettings(from: "tcp-port = 0")
        #expect(result.tcpPort == 0)
    }

    @Test func parseTCPPortAbsentDefaultsToZero() {
        let result = ConfigParser.parseGeneralSettings(from: "focus-follows-mouse = true")
        #expect(result.tcpPort == 0)
    }

    @Test func parseTCPPortInvalidIgnored() {
        let result = ConfigParser.parseGeneralSettings(from: "tcp-port = banana")
        #expect(result.tcpPort == 0)
    }

    @Test func parseTCPPortOutOfRangeIgnored() {
        let result = ConfigParser.parseGeneralSettings(from: "tcp-port = 99999")
        #expect(result.tcpPort == 0)
    }

    // MARK: - Global Hotkey

    @Test func parseGlobalHotkeyAbsentIsNil() {
        let result = ConfigParser.parseGeneralSettings(from: "focus-follows-mouse = true")
        #expect(result.globalHotkey == nil)
    }

    @Test func parseGlobalHotkeyWithModifiers() {
        let result = ConfigParser.parseGeneralSettings(from: "global-hotkey = super+shift+t")
        #expect(result.globalHotkey == KeyTrigger(keyCode: 17, modifiers: [.command, .shift]))
    }

    @Test func parseGlobalHotkeyNoneClears() {
        let result = ConfigParser.parseGeneralSettings(from: "global-hotkey = none")
        #expect(result.globalHotkey == nil)
    }

    @Test func parseGlobalHotkeyInvalidIgnored() {
        let result = ConfigParser.parseGeneralSettings(from: "global-hotkey = super+badkey")
        #expect(result.globalHotkey == nil)
    }

    @Test func parseGlobalHotkeyHideOnRepressDefaultsTrue() {
        let result = ConfigParser.parseGeneralSettings(from: "")
        #expect(result.globalHotkeyHideOnRepress == true)
    }

    @Test func parseGlobalHotkeyHideOnRepressFalse() {
        let result = ConfigParser.parseGeneralSettings(from: "global-hotkey-hide-on-repress = false")
        #expect(result.globalHotkeyHideOnRepress == false)
    }

    @Test func parseGlobalHotkeyHideOnRepressTrue() {
        let result = ConfigParser.parseGeneralSettings(from: "global-hotkey-hide-on-repress = true")
        #expect(result.globalHotkeyHideOnRepress == true)
    }

    @Test func globalHotkeyRoundTripThroughSetGeneralSetting() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nex-test-\(UUID().uuidString).config")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed file with an unrelated setting to verify preservation.
        try "focus-follows-mouse = true\n".write(to: tmp, atomically: true, encoding: .utf8)

        ConfigParser.setGeneralSetting("global-hotkey", value: "super+shift+t", inFile: tmp.path)
        ConfigParser.setGeneralSetting(
            "global-hotkey-hide-on-repress", value: "false", inFile: tmp.path
        )

        let parsed = ConfigParser.parseGeneralSettings(fromFile: tmp.path)
        #expect(parsed.globalHotkey == KeyTrigger(keyCode: 17, modifiers: [.command, .shift]))
        #expect(parsed.globalHotkeyHideOnRepress == false)
        #expect(parsed.focusFollowsMouse == true)

        // Clear the hotkey.
        ConfigParser.setGeneralSetting("global-hotkey", value: "none", inFile: tmp.path)
        let cleared = ConfigParser.parseGeneralSettings(fromFile: tmp.path)
        #expect(cleared.globalHotkey == nil)
        #expect(cleared.focusFollowsMouse == true)
    }

    // MARK: - Workspace profiles

    @Test func parseProfilesSingleLine() {
        let config = "profile = work:CLAUDE_CONFIG_DIR=/accounts/work"
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result.count == 1)
        #expect(result[0].name == "work")
        #expect(result[0].env == ["CLAUDE_CONFIG_DIR": "/accounts/work"])
    }

    @Test func parseProfilesMergesRepeatedLinesLaterWins() {
        let config = """
        profile = work:FOO=first
        profile = work:BAR=kept
        profile = work:FOO=second
        """
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result.count == 1)
        #expect(result[0].env == ["FOO": "second", "BAR": "kept"])
    }

    @Test func parseProfilesPreservesFirstAppearanceOrder() {
        let config = """
        profile = work:A=1
        profile = personal:B=2
        profile = work:C=3
        """
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result.map(\.name) == ["work", "personal"])
        #expect(result[0].env == ["A": "1", "C": "3"])
    }

    @Test func parseProfilesExpandsLeadingTilde() {
        let config = "profile = work:CLAUDE_CONFIG_DIR=~/.claude-accounts/work"
        let result = ConfigParser.parseProfiles(from: config)
        let expected = ("~/.claude-accounts/work" as NSString).expandingTildeInPath
        #expect(result[0].env["CLAUDE_CONFIG_DIR"] == expected)
        #expect(result[0].env["CLAUDE_CONFIG_DIR"]?.hasPrefix("~") == false)
    }

    @Test func parseProfilesLeavesMidStringTildeAlone() {
        let config = "profile = work:MARKER=a~b"
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result[0].env["MARKER"] == "a~b")
    }

    @Test func parseProfilesKeepsQuotesLiteral() {
        // Quotes are not stripped (matches the rest of the config syntax),
        // and a leading quote suppresses tilde expansion.
        let config = "profile = work:DIR=\"~/path with spaces\""
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result[0].env["DIR"] == "\"~/path with spaces\"")
    }

    @Test func parseProfilesValueMayContainColonsAndEquals() {
        let config = "profile = work:URL=https://example.com:8080/a=b"
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result[0].env["URL"] == "https://example.com:8080/a=b")
    }

    @Test func parseProfilesSkipsMalformedLines() {
        let config = """
        profile = missing-colon-entirely
        profile = work:JUSTAKEY
        profile = :K=V
        profile = work:=value
        profile = work:GOOD=yes
        """
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result.count == 1)
        #expect(result[0].name == "work")
        #expect(result[0].env == ["GOOD": "yes"])
    }

    @Test func parseProfilesIgnoresCommentsAndOtherKeys() {
        let config = """
        # profile = commented:A=1
        focus-follows-mouse = true
        profiles = notme:A=1
        profile-x = notme:A=1
        keybind = super+d=split_right
        profile = work:A=1
        """
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result.count == 1)
        #expect(result[0].name == "work")
    }

    @Test func parseProfilesPreservesCase() {
        let config = "profile = Work:MixedCase=VaLuE"
        let result = ConfigParser.parseProfiles(from: config)
        #expect(result[0].name == "Work")
        #expect(result[0].env == ["MixedCase": "VaLuE"])
    }

    @Test func parseProfilesMissingFileReturnsEmpty() {
        let result = ConfigParser.parseProfiles(
            fromFile: "/nonexistent/path/to/nex/config"
        )
        #expect(result.isEmpty)
    }
}
