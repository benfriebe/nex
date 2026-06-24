import Foundation

/// A user-defined workspace label preset: a name paired with a color.
///
/// Presets are a global, app-level convenience — picking one in the
/// inspector adds its `name` to a workspace's free-form `labels` (the
/// existing string list is unchanged), and chips whose text matches a
/// preset name render in the preset's color. Identity is the name, which
/// is unique (case-sensitive) within the preset list. This mirrors how a
/// label string matches a preset: exact, case-sensitive (labels are only
/// trimmed/clamped by `WorkspaceFeature.normalizeLabel`, never lowercased).
struct LabelPreset: Equatable, Identifiable, Codable {
    var name: String
    var color: WorkspaceColor

    var id: String { name }
}

extension [LabelPreset] {
    /// Color for a label string via exact, case-sensitive name match, or
    /// nil when no preset matches (the chip renders neutral). This is the
    /// single source of the lookup semantics — `AppReducer.State` and the
    /// inspector both route through it.
    func color(for label: String) -> WorkspaceColor? {
        first { $0.name == label }?.color
    }
}

/// JSON-in-UserDefaults persistence for the label preset list, mirroring
/// `FavouritesStorage`. Presets are a flat, foreign-key-free global list,
/// so they live alongside favourites in UserDefaults rather than in the
/// GRDB entity graph.
enum LabelPresetsStorage {
    static let defaultsKey = "settings.labelPresets"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func decode(_ json: String?) -> [LabelPreset] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return (try? decoder.decode([LabelPreset].self, from: data)) ?? []
    }

    static func encode(_ presets: [LabelPreset]) -> String {
        guard let data = try? encoder.encode(presets),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
