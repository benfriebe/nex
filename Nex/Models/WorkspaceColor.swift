import AppKit
import SwiftUI

enum WorkspaceColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, gray, black, white

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        // Black/white are adaptive monochromes so they stay visible (and
        // distinct from each other) against both the light and dark chrome:
        // black is always the dark end, white the light end.
        case .black: Self.adaptiveMono(light: 0.11, dark: 0.45)
        case .white: Self.adaptiveMono(light: 0.68, dark: 0.96)
        }
    }

    /// A neutral grey whose brightness flips with the active appearance so a
    /// monochrome workspace colour never disappears into the chrome.
    private static func adaptiveMono(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }

    var displayName: String { rawValue.capitalized }

    static func random() -> WorkspaceColor {
        allCases.randomElement() ?? .blue
    }
}
