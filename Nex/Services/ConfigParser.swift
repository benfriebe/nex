import Foundation
import os.log

/// Parses Ghostty-style config files for keybinding entries.
enum ConfigParser {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.benfriebe.nex",
        category: "ConfigParser"
    )

    struct GeneralSettings {
        var focusFollowsMouse: Bool = false
        var focusFollowsMouseDelay: Int = 100
        var theme: String?
        var tcpPort: Int = 0
        var globalHotkey: KeyTrigger?
        var globalHotkeyHideOnRepress: Bool = true
    }

    /// Parse general (non-keybind) settings from a config file.
    static func parseGeneralSettings(fromFile path: String) -> GeneralSettings {
        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return GeneralSettings()
        }
        return parseGeneralSettings(from: contents)
    }

    static func parseGeneralSettings(from contents: String) -> GeneralSettings {
        var settings = GeneralSettings()
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)
            let value = rawValue.lowercased()

            switch key {
            case "focus-follows-mouse":
                settings.focusFollowsMouse = value == "true"
            case "focus-follows-mouse-delay":
                if let ms = Int(value) {
                    settings.focusFollowsMouseDelay = max(0, ms)
                }
            case "theme":
                // Preserve original case — ghostty theme filenames are case-sensitive.
                settings.theme = rawValue
            case "tcp-port":
                if let port = Int(value), (1 ... 65535).contains(port) {
                    settings.tcpPort = port
                }
            case "global-hotkey":
                if value == "none" || value == "unbind" || value.isEmpty {
                    settings.globalHotkey = nil
                } else if let trigger = KeyTrigger.parse(rawValue) {
                    settings.globalHotkey = trigger
                }
            case "global-hotkey-hide-on-repress":
                settings.globalHotkeyHideOnRepress = value != "false"
            default:
                break
            }
        }
        return settings
    }

    /// Set a general setting in the config file, preserving other lines.
    static func setGeneralSetting(_ key: String, value: String, inFile path: String) {
        var lines: [String] = []
        var found = false

        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let eqIndex = trimmed.firstIndex(of: "=") {
                    let lineKey = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
                    if lineKey == key {
                        lines.append("\(key) = \(value)")
                        found = true
                        continue
                    }
                }
                lines.append(line)
            }
        }

        if !found {
            // Remove trailing empty lines before appending
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            lines.append("\(key) = \(value)")
        }

        // Ensure trailing newline
        if lines.last?.isEmpty != true {
            lines.append("")
        }

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Parse keybind entries from a config file's contents.
    ///
    /// Expected format (one per line):
    /// ```
    /// keybind = super+d=split_right
    /// keybind = super+shift+d=split_down
    /// keybind = super+e=unbind
    /// ```
    static func parseKeybindings(from contents: String) -> [(KeyTrigger, NexAction)] {
        var results: [(KeyTrigger, NexAction)] = []

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Only process keybind lines
            guard trimmed.hasPrefix("keybind") else { continue }

            // Split on first "=" to get "keybind" and the value
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
            guard key == "keybind" else { continue }

            let value = trimmed[trimmed.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)

            // The value is "trigger=action" — split on the last "=" since
            // modifier+key part uses "+" not "="
            guard let actionSep = value.lastIndex(of: "=") else {
                logger.warning("Malformed keybind value (missing '='): \(value)")
                continue
            }

            let triggerStr = value[..<actionSep].trimmingCharacters(in: .whitespaces)
            let actionStr = value[value.index(after: actionSep)...]
                .trimmingCharacters(in: .whitespaces)

            guard let trigger = KeyTrigger.parse(triggerStr) else {
                logger.warning("Unknown key in keybind trigger: \(triggerStr)")
                continue
            }

            guard let action = NexAction(rawValue: actionStr) else {
                logger.warning("Unknown action in keybind: \(actionStr)")
                continue
            }

            results.append((trigger, action))
        }

        return results
    }

    /// Write keybinding overrides to the config file, preserving non-keybind lines.
    /// Only writes entries that differ from defaults.
    static func writeKeybindings(_ map: KeyBindingMap, toFile path: String) {
        let defaults = KeyBindingMap.defaults

        // Read existing file to preserve non-keybind lines
        var nonKeybindLines: [String] = []
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in existing.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("keybind"), trimmed.contains("=") {
                    continue // Skip old keybind lines
                }
                nonKeybindLines.append(line)
            }
            // Remove trailing empty lines
            while nonKeybindLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                nonKeybindLines.removeLast()
            }
        }

        // Compute overrides vs defaults
        var keybindLines: [String] = []

        // Find triggers that are new or changed from defaults
        for action in NexAction.bindableActions {
            let currentTriggers = map.triggers(for: action)
            let defaultTriggers = defaults.triggers(for: action)

            // New triggers not in defaults
            for trigger in currentTriggers {
                if defaults.action(for: trigger) != action {
                    keybindLines.append("keybind = \(trigger.configString)=\(action.rawValue)")
                }
            }

            // Default triggers that have been removed (unbound)
            for trigger in defaultTriggers where map.action(for: trigger) != action {
                if map.action(for: trigger) == nil {
                    keybindLines.append("keybind = \(trigger.configString)=unbind")
                }
            }
        }

        // Default triggers rebound to a different action
        var writtenTriggers: Set<String> = []
        for line in keybindLines {
            // Extract the trigger portion: "keybind = <trigger>=<action>"
            if let eqIdx = line.firstIndex(of: "=") {
                let afterKeybind = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                if let triggerEnd = afterKeybind.lastIndex(of: "=") {
                    writtenTriggers.insert(
                        afterKeybind[..<triggerEnd].trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }
        for action in NexAction.bindableActions {
            let defaultTriggers = defaults.triggers(for: action)
            for trigger in defaultTriggers {
                if let newAction = map.action(for: trigger), newAction != action {
                    if !writtenTriggers.contains(trigger.configString) {
                        keybindLines.append("keybind = \(trigger.configString)=\(newAction.rawValue)")
                    }
                }
            }
        }

        // If no overrides, delete the file (or write empty)
        if keybindLines.isEmpty, nonKeybindLines.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }

        var output = nonKeybindLines
        if !keybindLines.isEmpty {
            if !output.isEmpty { output.append("") }
            output.append(contentsOf: keybindLines)
        }
        output.append("") // trailing newline

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? output.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
