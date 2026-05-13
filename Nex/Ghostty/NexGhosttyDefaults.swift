import Foundation

/// Nex-managed ghostty config defaults applied between the compiled-in
/// zig defaults and the user's `~/.config/ghostty/config`. Anything set
/// here can still be overridden by the user's own config — this is just
/// Nex's preferred starting point.
///
/// Currently used to give the in-pane scrollback search higher-contrast
/// match colors that align with the markdown find overlay (see
/// `MarkdownFindScript.matchBackgroundCSS`).
enum NexGhosttyDefaults {
    /// Hex string suitable for ghostty's `key = #RRGGBB` syntax.
    static let matchBackgroundHex = "#F2D027"
    static let matchForegroundHex = "#000000"
    static let currentMatchBackgroundHex = "#FF7A00"
    static let currentMatchForegroundHex = "#000000"

    static let source: String = """
    # Nex-managed defaults. Applied after ghostty's compiled-in defaults
    # but before the user's own config, so any of these stay overridable
    # by ~/.config/ghostty/config.
    search-background = \(matchBackgroundHex)
    search-foreground = \(matchForegroundHex)
    search-selected-background = \(currentMatchBackgroundHex)
    search-selected-foreground = \(currentMatchForegroundHex)
    """
}
