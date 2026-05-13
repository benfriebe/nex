import AppKit
import Foundation

/// Type-safe wrapper around ghostty_config_t.
final class GhosttyConfig {
    let rawConfig: ghostty_config_t

    init() {
        rawConfig = ghostty_config_new()
        Self.loadNexDefaults(rawConfig)
        ghostty_config_load_default_files(rawConfig)
        ghostty_config_load_recursive_files(rawConfig)
    }

    /// Create a config that loads default + recursive files, then applies
    /// an override file on top. The override file is loaded last so its
    /// values take precedence.
    init(overrideFile path: String) {
        rawConfig = ghostty_config_new()
        Self.loadNexDefaults(rawConfig)
        ghostty_config_load_default_files(rawConfig)
        ghostty_config_load_recursive_files(rawConfig)
        path.withCString { ghostty_config_load_file(rawConfig, $0) }
    }

    /// Apply Nex's opinionated tweaks on top of ghostty's compiled-in
    /// defaults but BEFORE the user's `~/.config/ghostty/config` so any
    /// of these can still be overridden by the user. Order matters:
    /// `loadDefaultFiles` reads the user's XDG / app-support config, so
    /// our defaults must run first to keep user overrides winning.
    private static func loadNexDefaults(_ raw: ghostty_config_t) {
        let path = NSTemporaryDirectory() + "nex-ghostty-defaults"
        try? NexGhosttyDefaults.source.write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
        path.withCString { ghostty_config_load_file(raw, $0) }
    }

    func finalize() {
        ghostty_config_finalize(rawConfig)
    }

    // MARK: - Config Getters

    var backgroundOpacity: Double {
        var v = 1.0
        let key = "background-opacity"
        _ = ghostty_config_get(rawConfig, &v, key, UInt(key.count))
        return v
    }

    var backgroundColor: NSColor {
        var color = ghostty_config_color_s(r: 0, g: 0, b: 0)
        let key = "background"
        if ghostty_config_get(rawConfig, &color, key, UInt(key.count)) {
            return NSColor(
                red: CGFloat(color.r) / 255.0,
                green: CGFloat(color.g) / 255.0,
                blue: CGFloat(color.b) / 255.0,
                alpha: 1.0
            )
        }
        return .windowBackgroundColor
    }

    deinit {
        ghostty_config_free(rawConfig)
    }
}
