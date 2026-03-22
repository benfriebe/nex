import SwiftUI

enum WorkspaceColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, gray

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
        }
    }

    var displayName: String { rawValue.capitalized }
}
