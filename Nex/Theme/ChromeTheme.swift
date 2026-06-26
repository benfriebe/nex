import SwiftUI

/// Dedicated warm app-chrome palette, intentionally independent of the
/// Ghostty terminal theme. Drives the sidebar, window title bar, pane
/// headers, and the bottom status bar so the chrome reads as a single
/// designed surface regardless of which terminal theme the user runs.
///
/// Resolved (never stored in TCA state) from `ChromeAppearance` + the
/// system colour scheme and injected via `EnvironmentValues.chromeTheme`.
struct ChromeTheme: Equatable {
    // Surfaces
    let windowBackground: Color
    let sidebarBackground: Color
    let surfaceBackground: Color
    let headerBackground: Color
    let footerBackground: Color
    // Text
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    // Structure
    let divider: Color
    let selectionFill: Color
    let selectionStroke: Color
    let accent: Color
    // Semantic status (chrome-specific; not the system .green/.blue used before)
    let statusRunning: Color
    let statusWaiting: Color
    let statusDone: Color
    let activeAgent: Color
    /// Opacity applied to a group's colour for its full-width header band.
    /// Light needs more to read as a pastel; dark needs less over near-black.
    let groupBandOpacity: Double

    /// Surfaces sampled from the "Refined" mockups: neutral light (not a warm
    /// cream) and a near-black, cool dark (not warm brown).
    static let light = ChromeTheme(
        windowBackground: .hex(0xEAE8E2),
        sidebarBackground: .hex(0xEFEEE9),
        surfaceBackground: .hex(0xFFFFFF),
        // Pane headers are intentionally a touch lighter than the
        // sidebar/footer/title-bar tone, sitting between it and the pane body.
        headerBackground: .hex(0xF7F6F2),
        footerBackground: .hex(0xEFEEE9),
        textPrimary: .hex(0x2B2B2E),
        textSecondary: .hex(0x6B6C70),
        textTertiary: .hex(0x9A9A96),
        divider: .hex(0xDEDCD5),
        selectionFill: Color.hex(0x5E8AC4).opacity(0.16),
        selectionStroke: .hex(0x5E8AC4),
        accent: .hex(0x5E8AC4),
        statusRunning: .hex(0x4FA46B),
        statusWaiting: .hex(0x5E8AC4),
        statusDone: .hex(0x9A9A96),
        activeAgent: .hex(0xA97C17),
        groupBandOpacity: 0.30
    )

    static let dark = ChromeTheme(
        windowBackground: .hex(0x0A0A0C),
        sidebarBackground: .hex(0x0C0C10),
        surfaceBackground: .hex(0x101013),
        headerBackground: .hex(0x13131A),
        footerBackground: .hex(0x0C0C10),
        textPrimary: .hex(0xE6E6EA),
        textSecondary: .hex(0x9A9AA0),
        textTertiary: .hex(0x6A6A72),
        divider: .hex(0x24242B),
        selectionFill: Color.hex(0x5276B8).opacity(0.24),
        selectionStroke: .hex(0x5276B8),
        accent: .hex(0x6F9BD8),
        statusRunning: .hex(0x5FBE89),
        statusWaiting: .hex(0x6F9BD8),
        statusDone: .hex(0x8A8A92),
        activeAgent: .hex(0xD3A329),
        groupBandOpacity: 0.22
    )
}

/// User preference for the chrome palette. `.system` follows the macOS
/// appearance; `.light`/`.dark` force the chrome (and the whole window,
/// via `.preferredColorScheme`) regardless of the system setting.
enum ChromeAppearance: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` for `.system` so we don't override the window's colour scheme.
    var explicitScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func theme(system: ColorScheme) -> ChromeTheme {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: system == .dark ? .dark : .light
        }
    }
}

/// Abbreviate the user's home directory to `~` in a path. Shared by the
/// status bar and pane header so they agree on display form.
func chromeHomeAbbreviated(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// "4m 9s"-style elapsed label shared by the status bar and pane-header
/// agent badges. Clamps negatives to zero.
func chromeElapsedLabel(from start: Date, to now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(seconds)s" }
    return "\(seconds)s"
}

extension Color {
    /// Build an opaque sRGB colour from a packed 0xRRGGBB literal.
    static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

extension EnvironmentValues {
    /// Active chrome palette. Defaults to `.light` so previews and any view
    /// rendered before `RootChromeView` injects a value still read a concrete
    /// theme.
    @Entry var chromeTheme: ChromeTheme = .light
}
