import Foundation

/// The eleven chrome colours a preset theme specifies, as `"RRGGBB"` strings.
/// Mapped onto `ChromeColorKey`s for a single light/dark bucket.
struct ChromePalette: Equatable {
    let windowBackground: String
    let sidebarBackground: String
    let headerBackground: String
    let footerBackground: String
    let surfaceBackground: String
    let accent: String
    let paneFocus: String
    let divider: String
    let statusRunning: String
    let statusWaiting: String
    let statusInactive: String

    /// `"<bucket>:<ChromeColorKey>"` → `"RRGGBB"` overrides for one appearance
    /// bucket (`"light"` or `"dark"`).
    func overrides(bucket: String) -> [String: String] {
        [
            "\(bucket):windowBackground": windowBackground,
            "\(bucket):sidebarBackground": sidebarBackground,
            "\(bucket):headerBackground": headerBackground,
            "\(bucket):footerBackground": footerBackground,
            "\(bucket):surfaceBackground": surfaceBackground,
            "\(bucket):accent": accent,
            "\(bucket):paneFocus": paneFocus,
            "\(bucket):divider": divider,
            "\(bucket):statusRunning": statusRunning,
            "\(bucket):statusWaiting": statusWaiting,
            "\(bucket):statusInactive": statusInactive
        ]
    }
}

/// A built-in chrome palette the user can apply in one click, modelled on a
/// popular editor/terminal theme. Selecting one writes its palette into the
/// matching appearance bucket and switches Light/Dark to suit — the terminal
/// theme is left alone.
struct BuiltInChromeTheme: Identifiable, Equatable {
    let name: String
    /// The mode this palette is designed for; selecting the theme switches to it.
    let appearance: ChromeAppearance
    let palette: ChromePalette

    var id: String { name }

    /// The shareable styling payload for this preset: the palette in its native
    /// bucket, the sparkline tinted to the accent, everything else at defaults.
    var styleTheme: ChromeStyleTheme {
        ChromeStyleTheme(
            version: ChromeStyleTheme.currentVersion,
            name: name,
            colorOverrides: palette.overrides(bucket: appearance == .light ? "light" : "dark"),
            sidebarColorIntensity: 1.0,
            sidebarAvatarFillOpacity: 0.20,
            sidebarAvatarStrokeOpacity: 0.45,
            sidebarGroupFillOpacity: -1,
            sidebarGroupStrokeOpacity: 0.0,
            sparklineColorHex: palette.accent,
            sparklineWidth: 28,
            sparklineStyle: "line"
        )
    }
}

extension BuiltInChromeTheme {
    /// The preset gallery, ordered dark-first then light. Colours sampled from
    /// each theme's published palette.
    static let all: [BuiltInChromeTheme] = [
        // Dracula — https://draculatheme.com
        BuiltInChromeTheme(name: "Dracula", appearance: .dark, palette: ChromePalette(
            windowBackground: "21222C",
            sidebarBackground: "282A36",
            headerBackground: "343746",
            footerBackground: "282A36",
            surfaceBackground: "2B2D3A",
            accent: "BD93F9",
            paneFocus: "BD93F9",
            divider: "44475A",
            statusRunning: "50FA7B",
            statusWaiting: "8BE9FD",
            statusInactive: "6272A4"
        )),
        // Nord — https://www.nordtheme.com
        BuiltInChromeTheme(name: "Nord", appearance: .dark, palette: ChromePalette(
            windowBackground: "2E3440",
            sidebarBackground: "2E3440",
            headerBackground: "3B4252",
            footerBackground: "2E3440",
            surfaceBackground: "353C4A",
            accent: "88C0D0",
            paneFocus: "88C0D0",
            divider: "3B4252",
            statusRunning: "A3BE8C",
            statusWaiting: "81A1C1",
            statusInactive: "4C566A"
        )),
        // Gruvbox Dark — https://github.com/morhetz/gruvbox
        BuiltInChromeTheme(name: "Gruvbox Dark", appearance: .dark, palette: ChromePalette(
            windowBackground: "1D2021",
            sidebarBackground: "282828",
            headerBackground: "3C3836",
            footerBackground: "282828",
            surfaceBackground: "32302F",
            accent: "FE8019",
            paneFocus: "FE8019",
            divider: "3C3836",
            statusRunning: "B8BB26",
            statusWaiting: "83A598",
            statusInactive: "7C6F64"
        )),
        // Tokyo Night — https://github.com/folke/tokyonight.nvim
        BuiltInChromeTheme(name: "Tokyo Night", appearance: .dark, palette: ChromePalette(
            windowBackground: "16161E",
            sidebarBackground: "1A1B26",
            headerBackground: "1F2335",
            footerBackground: "1A1B26",
            surfaceBackground: "1F2335",
            accent: "7AA2F7",
            paneFocus: "7AA2F7",
            divider: "292E42",
            statusRunning: "9ECE6A",
            statusWaiting: "7DCFFF",
            statusInactive: "565F89"
        )),
        // Catppuccin Mocha — https://catppuccin.com
        BuiltInChromeTheme(name: "Catppuccin Mocha", appearance: .dark, palette: ChromePalette(
            windowBackground: "181825",
            sidebarBackground: "1E1E2E",
            headerBackground: "313244",
            footerBackground: "1E1E2E",
            surfaceBackground: "313244",
            accent: "CBA6F7",
            paneFocus: "CBA6F7",
            divider: "45475A",
            statusRunning: "A6E3A1",
            statusWaiting: "89B4FA",
            statusInactive: "6C7086"
        )),
        // Solarized Light — https://ethanschoonover.com/solarized
        BuiltInChromeTheme(name: "Solarized Light", appearance: .light, palette: ChromePalette(
            windowBackground: "EEE8D5",
            sidebarBackground: "EEE8D5",
            headerBackground: "FDF6E3",
            footerBackground: "EEE8D5",
            surfaceBackground: "FDF6E3",
            accent: "268BD2",
            paneFocus: "268BD2",
            divider: "D9D2BE",
            statusRunning: "859900",
            statusWaiting: "2AA198",
            statusInactive: "93A1A1"
        )),
        // Gruvbox Light — https://github.com/morhetz/gruvbox
        BuiltInChromeTheme(name: "Gruvbox Light", appearance: .light, palette: ChromePalette(
            windowBackground: "EBDBB2",
            sidebarBackground: "FBF1C7",
            headerBackground: "F2E5BC",
            footerBackground: "FBF1C7",
            surfaceBackground: "FBF1C7",
            accent: "AF3A03",
            paneFocus: "AF3A03",
            divider: "D5C4A1",
            statusRunning: "79740E",
            statusWaiting: "076678",
            statusInactive: "7C6F64"
        ))
    ]
}
