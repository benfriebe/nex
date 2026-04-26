import AppKit
import SwiftUI

// MARK: - KeyTrigger

/// A physical key combination (keyCode + modifier flags).
struct KeyTrigger: Hashable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    /// Build from an NSEvent, stripping numericPad/function flags so arrow keys
    /// match cleanly against user-specified triggers.
    init(event: NSEvent) {
        keyCode = event.keyCode
        modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.subtracting([.numericPad, .function])
    }

    func matches(_ event: NSEvent) -> Bool {
        let eventFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && eventFlags == modifiers
    }

    // MARK: Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    // MARK: Parsing

    /// Parse a trigger string like `"super+shift+d"` into a KeyTrigger.
    static func parse(_ string: String) -> KeyTrigger? {
        let parts = string.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }

        let keyName = parts.last!
        let modifierNames = parts.dropLast()

        guard let code = keyNameToCode[keyName] else { return nil }

        var flags: NSEvent.ModifierFlags = []
        for mod in modifierNames {
            guard let flag = modifierNameToFlag[mod] else { return nil }
            flags.insert(flag)
        }

        return KeyTrigger(keyCode: code, modifiers: flags)
    }

    /// Convert to SwiftUI KeyboardShortcut for menu items.
    /// Returns nil for keys that can't be represented as a KeyEquivalent.
    var keyboardShortcut: KeyboardShortcut? {
        guard let equiv = keyEquivalent else { return nil }
        return KeyboardShortcut(equiv, modifiers: swiftUIModifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        if let char = Self.keyCodeToCharacter[keyCode] {
            return KeyEquivalent(char)
        }
        // Named keys
        switch keyCode {
        case 36: return .return
        case 48: return .tab
        case 53: return .escape
        case 51: return .delete
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        case 49: return .space
        default: return nil
        }
    }

    private var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    // MARK: Display

    /// Human-readable display string using macOS modifier symbols (e.g. "⌘D", "⌘⇧Return").
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }

        let keyName: String = if let char = Self.keyCodeToCharacter[keyCode] {
            String(char).uppercased()
        } else if let name = Self.keyCodeToDisplayName[keyCode] {
            name
        } else {
            "?"
        }
        parts.append(keyName)
        return parts.joined()
    }

    /// Config-file format string (e.g. "super+shift+d").
    var configString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("super") }

        let keyName: String = if let char = Self.keyCodeToCharacter[keyCode] {
            String(char)
        } else if let name = Self.keyCodeToConfigName[keyCode] {
            name
        } else {
            "unknown"
        }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    private static let keyCodeToDisplayName: [UInt16: String] = [
        36: "Return", 48: "Tab", 53: "Esc", 51: "Delete", 49: "Space",
        117: "Fwd Del",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12"
    ]

    private static let keyCodeToConfigName: [UInt16: String] = [
        36: "return", 48: "tab", 53: "escape", 51: "delete", 49: "space",
        117: "forward_delete",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5",
        97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12"
    ]

    // MARK: Lookup Tables

    static let keyNameToCode: [String: UInt16] = [
        // Letters
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3,
        "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37,
        "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
        "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        // Numbers
        "one": 18, "two": 19, "three": 20, "four": 21, "five": 23,
        "six": 22, "seven": 26, "eight": 28, "nine": 25, "zero": 29,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        // Special keys
        "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "space": 49, "delete": 51, "backspace": 51,
        "forward_delete": 117,
        // Arrow keys
        "left": 123, "right": 124, "down": 125, "up": 126,
        // Brackets and punctuation
        "open_bracket": 33, "close_bracket": 30,
        "[": 33, "]": 30,
        "semicolon": 41, "quote": 39, "backquote": 50, "grave": 50,
        "comma": 43, "period": 47, "slash": 44, "backslash": 42,
        "minus": 27, "equal": 24, "equals": 24,
        "-": 27, "=": 24,
        // Function keys
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111
    ]

    static let modifierNameToFlag: [String: NSEvent.ModifierFlags] = [
        "super": .command, "cmd": .command, "command": .command,
        "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option,
        "shift": .shift
    ]

    /// Reverse mapping from keyCode to printable character for KeyEquivalent.
    private static let keyCodeToCharacter: [UInt16: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f",
        5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l",
        46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r",
        1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
        16: "y", 6: "z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        33: "[", 30: "]", 41: ";", 39: "'", 50: "`",
        43: ",", 47: ".", 44: "/", 42: "\\",
        27: "-", 24: "="
    ]
}

// MARK: - NexAction

/// Bindable action identifiers for keybinding configuration.
enum NexAction: String, CaseIterable {
    case newWorkspace = "new_workspace"
    case openFile = "open_file"
    case switchToWorkspace1 = "switch_to_workspace_1"
    case switchToWorkspace2 = "switch_to_workspace_2"
    case switchToWorkspace3 = "switch_to_workspace_3"
    case switchToWorkspace4 = "switch_to_workspace_4"
    case switchToWorkspace5 = "switch_to_workspace_5"
    case switchToWorkspace6 = "switch_to_workspace_6"
    case switchToWorkspace7 = "switch_to_workspace_7"
    case switchToWorkspace8 = "switch_to_workspace_8"
    case switchToWorkspace9 = "switch_to_workspace_9"
    case toggleSidebar = "toggle_sidebar"
    case toggleInspector = "toggle_inspector"
    case splitRight = "split_right"
    case splitDown = "split_down"
    case closePane = "close_pane"
    case focusNextPane = "focus_next_pane"
    case focusPreviousPane = "focus_previous_pane"
    case nextWorkspace = "next_workspace"
    case previousWorkspace = "previous_workspace"
    case renameWorkspace = "rename_workspace"
    case toggleMarkdownEdit = "toggle_markdown_edit"
    case increaseMarkdownFontSize = "increase_markdown_font_size"
    case decreaseMarkdownFontSize = "decrease_markdown_font_size"
    case toggleZoom = "toggle_zoom"
    case reopenClosedPane = "reopen_closed_pane"
    case toggleSearch = "toggle_search"
    case closeSearch = "close_search"
    case cycleLayout = "cycle_layout"
    case movePaneLeft = "move_pane_left"
    case movePaneRight = "move_pane_right"
    case movePaneUp = "move_pane_up"
    case movePaneDown = "move_pane_down"
    case createScratchpad = "create_scratchpad"
    case commandPalette = "command_palette"
    case newGroup = "new_group"
    case openDiff = "open_diff"
    case unbind

    /// Actions handled by SwiftUI Commands (menu bar items).
    /// The NSEvent monitor should not consume events for these.
    var isMenuBarAction: Bool {
        switch self {
        case .newWorkspace, .openFile, .newGroup,
             .switchToWorkspace1, .switchToWorkspace2, .switchToWorkspace3,
             .switchToWorkspace4, .switchToWorkspace5, .switchToWorkspace6,
             .switchToWorkspace7, .switchToWorkspace8, .switchToWorkspace9,
             .toggleSidebar, .toggleInspector, .commandPalette:
            true
        default:
            false
        }
    }

    /// Human-readable display name for the Settings UI.
    var displayName: String {
        switch self {
        case .newWorkspace: "New Workspace"
        case .openFile: "Preview Markdown"
        case .switchToWorkspace1: "Switch to Workspace 1"
        case .switchToWorkspace2: "Switch to Workspace 2"
        case .switchToWorkspace3: "Switch to Workspace 3"
        case .switchToWorkspace4: "Switch to Workspace 4"
        case .switchToWorkspace5: "Switch to Workspace 5"
        case .switchToWorkspace6: "Switch to Workspace 6"
        case .switchToWorkspace7: "Switch to Workspace 7"
        case .switchToWorkspace8: "Switch to Workspace 8"
        case .switchToWorkspace9: "Switch to Workspace 9"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleInspector: "Toggle Inspector"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .closePane: "Close Pane"
        case .focusNextPane: "Focus Next Pane"
        case .focusPreviousPane: "Focus Previous Pane"
        case .nextWorkspace: "Next Workspace"
        case .previousWorkspace: "Previous Workspace"
        case .renameWorkspace: "Rename Workspace"
        case .toggleMarkdownEdit: "Toggle Markdown Edit"
        case .increaseMarkdownFontSize: "Increase Markdown Font Size"
        case .decreaseMarkdownFontSize: "Decrease Markdown Font Size"
        case .toggleZoom: "Toggle Zoom"
        case .reopenClosedPane: "Reopen Closed Pane"
        case .toggleSearch: "Toggle Search"
        case .closeSearch: "Close Search"
        case .cycleLayout: "Cycle Layout"
        case .movePaneLeft: "Move Pane Left"
        case .movePaneRight: "Move Pane Right"
        case .movePaneUp: "Move Pane Up"
        case .movePaneDown: "Move Pane Down"
        case .createScratchpad: "New Scratchpad"
        case .commandPalette: "Command Palette"
        case .newGroup: "New Group"
        case .openDiff: "Open Diff"
        case .unbind: "Unbind"
        }
    }

    /// Category for grouping in Settings UI.
    var category: String {
        switch self {
        case .splitRight, .splitDown, .closePane, .reopenClosedPane, .toggleZoom, .cycleLayout,
             .movePaneLeft, .movePaneRight, .movePaneUp, .movePaneDown, .createScratchpad:
            "Pane Management"
        case .focusNextPane, .focusPreviousPane, .commandPalette:
            "Navigation"
        case .newWorkspace, .nextWorkspace, .previousWorkspace, .renameWorkspace, .newGroup,
             .switchToWorkspace1, .switchToWorkspace2, .switchToWorkspace3,
             .switchToWorkspace4, .switchToWorkspace5, .switchToWorkspace6,
             .switchToWorkspace7, .switchToWorkspace8, .switchToWorkspace9:
            "Workspaces"
        case .toggleSidebar, .toggleInspector:
            "View"
        case .openFile, .toggleMarkdownEdit, .increaseMarkdownFontSize, .decreaseMarkdownFontSize, .openDiff:
            "Files"
        case .toggleSearch, .closeSearch:
            "Search"
        case .unbind:
            "Other"
        }
    }

    /// Actions that should appear in the Settings keybinding table.
    static var bindableActions: [NexAction] {
        allCases.filter { $0 != .unbind }
    }

    /// The workspace index for switchToWorkspace actions, or nil.
    var workspaceIndex: Int? {
        switch self {
        case .switchToWorkspace1: 0
        case .switchToWorkspace2: 1
        case .switchToWorkspace3: 2
        case .switchToWorkspace4: 3
        case .switchToWorkspace5: 4
        case .switchToWorkspace6: 5
        case .switchToWorkspace7: 6
        case .switchToWorkspace8: 7
        case .switchToWorkspace9: 8
        default: nil
        }
    }
}

// MARK: - KeybindingConflict

/// The outcome of checking whether a proposed trigger is already claimed.
enum KeybindingConflict: Equatable {
    case action(NexAction)
    case globalHotkey

    /// Human-readable reason for surfacing in the recorder sheet.
    var message: String {
        switch self {
        case .action(let action):
            "Already bound to \"\(action.displayName)\""
        case .globalHotkey:
            "Already bound to the global hotkey"
        }
    }

    /// Look up whether `trigger` collides with any existing binding.
    ///
    /// - Parameters:
    ///   - excluding: When recording a new combo for an action that already owns a
    ///     binding, skip the match on its own current binding so re-recording the
    ///     same combo is a no-op rather than a self-collision.
    ///   - ignoreGlobalHotkey: Set when recording the global hotkey itself, so the
    ///     check only considers in-app bindings.
    static func check(
        trigger: KeyTrigger,
        in map: KeyBindingMap,
        globalHotkey: KeyTrigger?,
        excluding: NexAction? = nil,
        ignoreGlobalHotkey: Bool = false
    ) -> KeybindingConflict? {
        if !ignoreGlobalHotkey, globalHotkey == trigger {
            return .globalHotkey
        }
        if let existing = map.action(for: trigger), existing != excluding {
            return .action(existing)
        }
        return nil
    }
}

// MARK: - KeyBindingMap

/// Maps key triggers to actions. Supports multiple triggers per action.
struct KeyBindingMap: Equatable {
    private var triggerToAction: [KeyTrigger: NexAction]

    init(bindings: [KeyTrigger: NexAction] = [:]) {
        triggerToAction = bindings
    }

    /// Look up the action for a key trigger.
    func action(for trigger: KeyTrigger) -> NexAction? {
        triggerToAction[trigger]
    }

    /// All triggers currently bound to the given action, sorted by configString
    /// for deterministic ordering across launches.
    func triggers(for action: NexAction) -> [KeyTrigger] {
        triggerToAction.compactMap { $0.value == action ? $0.key : nil }
            .sorted { $0.configString < $1.configString }
    }

    /// Set a trigger → action binding. Removes any previous binding for this trigger.
    mutating func setBinding(trigger: KeyTrigger, action: NexAction) {
        triggerToAction[trigger] = action
    }

    /// Remove a specific trigger binding.
    mutating func removeBinding(trigger: KeyTrigger) {
        triggerToAction.removeValue(forKey: trigger)
    }

    /// Remove all triggers bound to a specific action.
    mutating func removeAllBindings(for action: NexAction) {
        triggerToAction = triggerToAction.filter { $0.value != action }
    }

    /// Apply user overrides on top of this map.
    /// - `unbind` actions remove the trigger.
    /// - Other actions replace or add the trigger → action mapping.
    func applying(overrides: [(KeyTrigger, NexAction)]) -> KeyBindingMap {
        var result = triggerToAction
        for (trigger, action) in overrides {
            if action == .unbind {
                result.removeValue(forKey: trigger)
            } else {
                result[trigger] = action
            }
        }
        return KeyBindingMap(bindings: result)
    }

    // MARK: Defaults

    /// All hardcoded default bindings matching current NexCommands + PaneShortcutMonitor.
    static let defaults: KeyBindingMap = {
        var bindings: [KeyTrigger: NexAction] = [:]

        // Menu bar actions (Layer 1)
        bindings[KeyTrigger(keyCode: 45, modifiers: .command)] = .newWorkspace // ⌘N
        bindings[KeyTrigger(keyCode: 31, modifiers: .command)] = .openFile // ⌘O
        bindings[KeyTrigger(keyCode: 18, modifiers: .command)] = .switchToWorkspace1 // ⌘1
        bindings[KeyTrigger(keyCode: 19, modifiers: .command)] = .switchToWorkspace2 // ⌘2
        bindings[KeyTrigger(keyCode: 20, modifiers: .command)] = .switchToWorkspace3 // ⌘3
        bindings[KeyTrigger(keyCode: 21, modifiers: .command)] = .switchToWorkspace4 // ⌘4
        bindings[KeyTrigger(keyCode: 23, modifiers: .command)] = .switchToWorkspace5 // ⌘5
        bindings[KeyTrigger(keyCode: 22, modifiers: .command)] = .switchToWorkspace6 // ⌘6
        bindings[KeyTrigger(keyCode: 26, modifiers: .command)] = .switchToWorkspace7 // ⌘7
        bindings[KeyTrigger(keyCode: 28, modifiers: .command)] = .switchToWorkspace8 // ⌘8
        bindings[KeyTrigger(keyCode: 25, modifiers: .command)] = .switchToWorkspace9 // ⌘9
        bindings[KeyTrigger(keyCode: 1, modifiers: [.command, .shift])] = .toggleSidebar // ⌘⇧S
        bindings[KeyTrigger(keyCode: 34, modifiers: .command)] = .toggleInspector // ⌘I

        // Pane shortcuts (Layer 2)
        bindings[KeyTrigger(keyCode: 2, modifiers: .command)] = .splitRight // ⌘D
        bindings[KeyTrigger(keyCode: 2, modifiers: [.command, .shift])] = .splitDown // ⌘⇧D
        bindings[KeyTrigger(keyCode: 13, modifiers: .command)] = .closePane // ⌘W
        bindings[KeyTrigger(keyCode: 30, modifiers: .command)] = .focusNextPane // ⌘]
        bindings[KeyTrigger(keyCode: 124, modifiers: [.command, .option])] = .focusNextPane // ⌘⌥→
        bindings[KeyTrigger(keyCode: 33, modifiers: .command)] = .focusPreviousPane // ⌘[
        bindings[KeyTrigger(keyCode: 123, modifiers: [.command, .option])] = .focusPreviousPane // ⌘⌥←
        bindings[KeyTrigger(keyCode: 125, modifiers: [.command, .option])] = .nextWorkspace // ⌘⌥↓
        bindings[KeyTrigger(keyCode: 126, modifiers: [.command, .option])] = .previousWorkspace // ⌘⌥↑
        bindings[KeyTrigger(keyCode: 15, modifiers: [.command, .shift])] = .renameWorkspace // ⌘⇧R
        bindings[KeyTrigger(keyCode: 14, modifiers: .command)] = .toggleMarkdownEdit // ⌘E
        bindings[KeyTrigger(keyCode: 24, modifiers: .command)] = .increaseMarkdownFontSize // ⌘=
        bindings[KeyTrigger(keyCode: 27, modifiers: .command)] = .decreaseMarkdownFontSize // ⌘-
        bindings[KeyTrigger(keyCode: 36, modifiers: [.command, .shift])] = .toggleZoom // ⌘⇧Return
        bindings[KeyTrigger(keyCode: 17, modifiers: [.command, .shift])] = .reopenClosedPane // ⌘⇧T
        bindings[KeyTrigger(keyCode: 3, modifiers: .command)] = .toggleSearch // ⌘F
        bindings[KeyTrigger(keyCode: 53)] = .closeSearch // Escape
        bindings[KeyTrigger(keyCode: 49, modifiers: [.command, .shift])] = .cycleLayout // ⌘⇧Space

        // Command Palette
        bindings[KeyTrigger(keyCode: 35, modifiers: .command)] = .commandPalette // ⌘P

        // Scratchpad
        bindings[KeyTrigger(keyCode: 45, modifiers: [.command, .shift])] = .createScratchpad // ⌘⇧N

        // Group management
        bindings[KeyTrigger(keyCode: 5, modifiers: [.command, .shift])] = .newGroup // ⌘⇧G

        // Move pane in direction
        bindings[KeyTrigger(keyCode: 123, modifiers: [.control, .shift])] = .movePaneLeft // ⌃⇧←
        bindings[KeyTrigger(keyCode: 124, modifiers: [.control, .shift])] = .movePaneRight // ⌃⇧→
        bindings[KeyTrigger(keyCode: 125, modifiers: [.control, .shift])] = .movePaneDown // ⌃⇧↓
        bindings[KeyTrigger(keyCode: 126, modifiers: [.control, .shift])] = .movePaneUp // ⌃⇧↑

        return KeyBindingMap(bindings: bindings)
    }()
}
