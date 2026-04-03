import Foundation
import os.log

/// Loads keybindings from ~/.config/nex/config at startup.
enum KeybindingService {
    static let configPath = ("~/.config/nex/config" as NSString).expandingTildeInPath

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.benfriebe.nex",
        category: "KeybindingService"
    )

    /// Read the config file and return a merged binding map.
    /// Returns defaults if the config file doesn't exist or has no keybind entries.
    static func loadFromDisk() -> KeyBindingMap {
        let configPath = Self.configPath

        guard FileManager.default.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8)
        else {
            return .defaults
        }

        let overrides = ConfigParser.parseKeybindings(from: contents)
        if overrides.isEmpty {
            return .defaults
        }

        logger.info("Loaded \(overrides.count) keybinding override(s) from config")
        return KeyBindingMap.defaults.applying(overrides: overrides)
    }
}
