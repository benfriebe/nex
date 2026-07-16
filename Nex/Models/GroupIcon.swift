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
    /// stray letter or digit can't be persisted as `.emoji`. The
    /// macOS character palette (the sheet's "Browse All Emoji…"
    /// button) offers glyphs well beyond RGI emoji — e.g. ⛙ U+26D9
    /// carries no Unicode emoji properties at all (issue #254) — so
    /// the check accepts, in order:
    ///
    /// 1. An emoji-presentation *base* scalar (`"🔥"`, skin tones,
    ///    flags, ZWJ sequences), or an explicit `U+FE0F` selector on
    ///    an emoji-capable base (`"❤️"`, `"1️⃣"` — digits carry
    ///    `Emoji=Yes`, so keycaps pass). Anchoring on the first
    ///    scalar rejects degenerate clusters — a lone invisible
    ///    `U+FE0F`, a selector on a non-emoji base (`"a\u{FE0F}"`),
    ///    or a letter with a skin-tone modifier glued on.
    /// 2. Text-presentation emoji pasted bare, i.e. without the
    ///    `U+FE0F` the palette usually appends (`"✂"`, `"ℹ"`, `"©"`):
    ///    `Emoji=Yes` on a non-ASCII first scalar. The ASCII guard
    ///    keeps `"1"` / `"#"` / `"*"` (also `Emoji=Yes`) rejected.
    /// 3. Non-emoji pictographs and symbols (`"⛙"`, `"♞"`, `"→"`,
    ///    `"⌘"`): non-ASCII first scalar in the So/Sm/Sc symbol
    ///    categories. Sk (spacing accents like `"´"`) is deliberately
    ///    excluded — it is a dead-key mistype away and never
    ///    icon-worthy.
    ///
    /// Letters, digits, punctuation, whitespace, and lone combining
    /// marks — ASCII or not (`"a"`, `"Ω"`, `"あ"`, `"！"`) — stay
    /// rejected.
    var isGraphemeEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        if unicodeScalars.count > 1, unicodeScalars.contains("\u{FE0F}"),
           first.properties.isEmoji {
            return true
        }
        guard !first.isASCII else { return false }
        if first.properties.isEmoji { return true }
        switch first.properties.generalCategory {
        case .otherSymbol, .mathSymbol, .currencySymbol:
            return true
        default:
            return false
        }
    }
}
