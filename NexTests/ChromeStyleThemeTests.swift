import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct ChromeStyleThemeTests {
    private func sample(name: String? = "Sunset") -> ChromeStyleTheme {
        ChromeStyleTheme(
            version: ChromeStyleTheme.currentVersion,
            name: name,
            colorOverrides: ["light:accent": "FF8800", "dark:accent": "FFAA33", "dark:sidebarBackground": "101014"],
            sidebarColorIntensity: 1.4,
            sidebarAvatarFillOpacity: 0.33,
            sidebarAvatarStrokeOpacity: 0.5,
            sidebarGroupFillOpacity: 0.25,
            sidebarGroupStrokeOpacity: 0.1,
            sparklineColorHex: "00FF99",
            sparklineWidth: 40,
            sparklineStyle: "dots"
        )
    }

    // MARK: - File (JSON) round-trip

    @Test func jsonRoundTrips() throws {
        let theme = sample()
        let restored = try ChromeStyleTheme(jsonData: theme.jsonData())
        #expect(restored == theme)
    }

    @Test func jsonDataIsHumanReadable() throws {
        let json = try String(data: sample().jsonData(), encoding: .utf8) ?? ""
        // Pretty-printed + sorted, so a shared file diffs cleanly.
        #expect(json.contains("\n"))
        #expect(json.contains("\"sparklineStyle\" : \"dots\""))
    }

    // MARK: - Share code round-trip

    @Test func shareCodeRoundTrips() throws {
        let theme = sample()
        let code = try theme.shareCode()
        #expect(code.hasPrefix(ChromeStyleTheme.codePrefix))
        let restored = try ChromeStyleTheme(shareCode: code)
        #expect(restored == theme)
    }

    @Test func shareCodeAcceptsBareBase64WithoutPrefix() throws {
        let theme = sample()
        let code = try theme.shareCode()
        let bare = String(code.dropFirst(ChromeStyleTheme.codePrefix.count))
        let restored = try ChromeStyleTheme(shareCode: bare)
        #expect(restored == theme)
    }

    @Test func shareCodeAcceptsRawJSONPastedDirectly() throws {
        let theme = sample()
        let json = try String(data: theme.jsonData(), encoding: .utf8) ?? ""
        let restored = try ChromeStyleTheme(shareCode: json)
        #expect(restored == theme)
    }

    @Test func shareCodeToleratesSurroundingWhitespace() throws {
        let theme = sample()
        let code = try "  \n" + (theme.shareCode()) + "\n  "
        let restored = try ChromeStyleTheme(shareCode: code)
        #expect(restored == theme)
    }

    @Test func invalidShareCodeThrows() {
        #expect(throws: ChromeStyleThemeError.invalidCode) {
            _ = try ChromeStyleTheme(shareCode: "not a theme at all")
        }
    }

    // MARK: - Version guard

    @Test func newerVersionIsRejected() throws {
        var future = sample()
        future.version = ChromeStyleTheme.currentVersion + 1
        let data = try future.jsonData()
        #expect(throws: ChromeStyleThemeError.unsupportedVersion(future.version)) {
            _ = try ChromeStyleTheme(jsonData: data)
        }
    }

    // MARK: - Capture from settings state

    @Test func capturesStylingFromSettingsState() {
        var state = SettingsFeature.State()
        state.chromeColorOverrides = ["light:accent": "112233"]
        state.sidebarColorIntensity = 1.7
        state.sidebarAvatarFillOpacity = 0.31
        state.sidebarGroupStrokeOpacity = 0.12
        state.sparklineColorHex = "ABCDEF"
        state.sparklineWidth = 36
        state.sparklineStyle = "dots"
        // Fields the theme must NOT carry (recipient keeps their own).
        state.chromeAppearance = .dark
        state.backgroundOpacity = 0.5

        let theme = ChromeStyleTheme(capturing: state, name: "Mine")
        #expect(theme.name == "Mine")
        #expect(theme.version == ChromeStyleTheme.currentVersion)
        #expect(theme.colorOverrides == ["light:accent": "112233"])
        #expect(theme.sidebarColorIntensity == 1.7)
        #expect(theme.sidebarAvatarFillOpacity == 0.31)
        #expect(theme.sidebarGroupStrokeOpacity == 0.12)
        #expect(theme.sparklineColorHex == "ABCDEF")
        #expect(theme.sparklineWidth == 36)
        #expect(theme.sparklineStyle == "dots")
    }

    @Test func captureThenApplyIsIdentity() async {
        // A theme captured from a styled state, applied onto a fresh state,
        // reproduces the same styling fields.
        var styled = SettingsFeature.State()
        styled.chromeColorOverrides = ["dark:divider": "222228"]
        styled.sidebarColorIntensity = 0.6
        styled.sparklineStyle = "dots"
        let theme = ChromeStyleTheme(capturing: styled)

        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.applyStyleTheme(theme)) { state in
            #expect(state.chromeColorOverrides == ["dark:divider": "222228"])
            #expect(state.sidebarColorIntensity == 0.6)
            #expect(state.sparklineStyle == "dots")
        }
    }

    // MARK: - Apply action

    @Test func applyStyleThemeOverwritesStylingFields() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.applyStyleTheme(sample())) { state in
            #expect(state.chromeColorOverrides["light:accent"] == "FF8800")
            #expect(state.chromeColorOverrides["dark:sidebarBackground"] == "101014")
            #expect(state.sidebarColorIntensity == 1.4)
            #expect(state.sidebarAvatarFillOpacity == 0.33)
            #expect(state.sidebarAvatarStrokeOpacity == 0.5)
            #expect(state.sidebarGroupFillOpacity == 0.25)
            #expect(state.sidebarGroupStrokeOpacity == 0.1)
            #expect(state.sparklineColorHex == "00FF99")
            #expect(state.sparklineWidth == 40)
            #expect(state.sparklineStyle == "dots")
        }
    }

    @Test func applyStyleThemeLeavesAppearanceAndTerminalUntouched() async {
        var initial = SettingsFeature.State()
        initial.chromeAppearance = .dark
        initial.backgroundOpacity = 0.4
        let store = TestStore(initialState: initial) {
            SettingsFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.applyStyleTheme(sample())) { state in
            // The recipient's mode + terminal background are not overridden.
            #expect(state.chromeAppearance == .dark)
            #expect(state.backgroundOpacity == 0.4)
        }
    }
}
