import Foundation

/// Icon displayed on a `WorkspaceGroup`'s header. `nil` on the group
/// renders today's colour-tinted folder fallback.
///
/// `systemName` carries an SF Symbol identifier (e.g., `star.fill`);
/// it inherits the group's colour tint in the header view. `emoji`
/// carries a 1-grapheme user string (e.g., `📁`); it renders as plain
/// text and ignores the group colour — emoji glyphs carry their own
/// palette and SwiftUI can't recolour them cleanly.
enum GroupIcon: Codable, Equatable, Hashable {
    case systemName(String)
    case emoji(String)

    // MARK: - Storage

    /// Serialise for the `workspace_group.icon` TEXT column as a
    /// prefix-qualified string (`"system:<name>"` or `"emoji:<grapheme>"`).
    /// The JSON representation that Swift's Codable generates for
    /// associated-value enums is verbose; a flat prefix keeps the
    /// stored row compact and trivial to read by hand.
    var storageString: String {
        switch self {
        case .systemName(let name): "system:\(name)"
        case .emoji(let e): "emoji:\(e)"
        }
    }

    /// Parse a value previously produced by `storageString`. Returns
    /// `nil` for unknown prefixes or empty payloads so a malformed
    /// row degrades gracefully to the folder fallback.
    init?(storageString: String) {
        if let rest = storageString.stripPrefix("system:") {
            guard !rest.isEmpty else { return nil }
            self = .systemName(rest)
        } else if let rest = storageString.stripPrefix("emoji:") {
            guard !rest.isEmpty else { return nil }
            self = .emoji(rest)
        } else {
            return nil
        }
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

extension Character {
    /// Heuristic emoji check used by the Custom Emoji input so a
    /// stray letter or digit can't be persisted as `.emoji`. Returns
    /// `true` when any scalar of the grapheme defaults to emoji
    /// presentation (single-codepoint pictographs, skin-toned,
    /// flags, ZWJ sequences) or carries the explicit emoji-
    /// presentation selector (`U+FE0F`). That covers common cases —
    /// `"a"` / `"1"` / keyboard punctuation are rejected, while
    /// `"❤️"`, `"👨‍👩‍👧‍👦"`, and `"1️⃣"` pass.
    var isGraphemeEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar == "\u{FE0F}"
        }
    }
}
