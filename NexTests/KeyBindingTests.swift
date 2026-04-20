import AppKit
@testable import Nex
import Testing

@MainActor
struct KeyTriggerParsingTests {
    @Test func parseSingleModifierAndKey() {
        let trigger = KeyTrigger.parse("super+d")
        #expect(trigger != nil)
        #expect(trigger?.keyCode == 2)
        #expect(trigger?.modifiers == .command)
    }

    @Test func parseMultipleModifiers() {
        let trigger = KeyTrigger.parse("super+shift+d")
        #expect(trigger != nil)
        #expect(trigger?.keyCode == 2)
        #expect(trigger?.modifiers == [.command, .shift])
    }

    @Test func parseCtrlAlt() {
        let trigger = KeyTrigger.parse("ctrl+alt+a")
        #expect(trigger != nil)
        #expect(trigger?.keyCode == 0)
        #expect(trigger?.modifiers == [.control, .option])
    }

    @Test func parseArrowKey() {
        let trigger = KeyTrigger.parse("super+alt+right")
        #expect(trigger != nil)
        #expect(trigger?.keyCode == 124)
        #expect(trigger?.modifiers == [.command, .option])
    }

    @Test func parseReturnKey() {
        let trigger = KeyTrigger.parse("super+shift+return")
        #expect(trigger != nil)
        #expect(trigger?.keyCode == 36)
        #expect(trigger?.modifiers == [.command, .shift])
    }

    @Test func parseEscapeKey() {
        let trigger = KeyTrigger.parse("escape")
        #expect(trigger != nil)
        #expect(trigger?.keyCode == 53)
        #expect(trigger?.modifiers == [])
    }

    @Test func parseBrackets() {
        let open = KeyTrigger.parse("super+open_bracket")
        #expect(open?.keyCode == 33)
        #expect(open?.modifiers == .command)

        let close = KeyTrigger.parse("super+close_bracket")
        #expect(close?.keyCode == 30)
        #expect(close?.modifiers == .command)
    }

    @Test func parseNumericKeys() {
        let trigger = KeyTrigger.parse("super+1")
        #expect(trigger?.keyCode == 18)
        #expect(trigger?.modifiers == .command)
    }

    @Test func parseFunctionKey() {
        let trigger = KeyTrigger.parse("f1")
        #expect(trigger?.keyCode == 122)
        #expect(trigger?.modifiers == [])
    }

    @Test func parseModifierAliases() {
        let cmd = KeyTrigger.parse("cmd+a")
        let command = KeyTrigger.parse("command+a")
        let superKey = KeyTrigger.parse("super+a")
        #expect(cmd == command)
        #expect(cmd == superKey)

        let ctrl = KeyTrigger.parse("ctrl+a")
        let control = KeyTrigger.parse("control+a")
        #expect(ctrl == control)

        let alt = KeyTrigger.parse("alt+a")
        let opt = KeyTrigger.parse("opt+a")
        let option = KeyTrigger.parse("option+a")
        #expect(alt == opt)
        #expect(alt == option)
    }

    @Test func parseUnknownKeyReturnsNil() {
        #expect(KeyTrigger.parse("super+nonexistent") == nil)
    }

    @Test func parseUnknownModifierReturnsNil() {
        #expect(KeyTrigger.parse("hyper+a") == nil)
    }

    @Test func parseEmptyStringReturnsNil() {
        #expect(KeyTrigger.parse("") == nil)
    }

    @Test func caseInsensitive() {
        let upper = KeyTrigger.parse("SUPER+SHIFT+D")
        let lower = KeyTrigger.parse("super+shift+d")
        #expect(upper == lower)
    }
}

@MainActor
struct KeyTriggerMatchingTests {
    private func keyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test func matchesExactEvent() {
        let trigger = KeyTrigger(keyCode: 2, modifiers: .command)
        let event = keyEvent(keyCode: 2, modifierFlags: .command)
        #expect(trigger.matches(event))
    }

    @Test func doesNotMatchDifferentModifiers() {
        let trigger = KeyTrigger(keyCode: 2, modifiers: .command)
        let event = keyEvent(keyCode: 2, modifierFlags: [.command, .shift])
        #expect(!trigger.matches(event))
    }

    @Test func doesNotMatchDifferentKeyCode() {
        let trigger = KeyTrigger(keyCode: 2, modifiers: .command)
        let event = keyEvent(keyCode: 3, modifierFlags: .command)
        #expect(!trigger.matches(event))
    }

    @Test func stripsNumericPadAndFunctionForArrows() {
        let trigger = KeyTrigger(keyCode: 124, modifiers: [.command, .option])
        let event = keyEvent(keyCode: 124, modifierFlags: [.command, .option, .numericPad, .function])
        #expect(trigger.matches(event))
    }
}

@MainActor
struct NexActionTests {
    @Test func allRawValuesAreUnique() {
        let rawValues = NexAction.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test func menuBarActionsAreCorrect() {
        let menuActions: [NexAction] = [
            .newWorkspace, .openFile,
            .switchToWorkspace1, .switchToWorkspace2, .switchToWorkspace3,
            .switchToWorkspace4, .switchToWorkspace5, .switchToWorkspace6,
            .switchToWorkspace7, .switchToWorkspace8, .switchToWorkspace9,
            .toggleSidebar, .toggleInspector, .commandPalette
        ]
        for action in menuActions {
            #expect(action.isMenuBarAction, "Expected \(action.rawValue) to be a menu bar action")
        }
    }

    @Test func paneActionsAreNotMenuBar() {
        let paneActions: [NexAction] = [
            .splitRight, .splitDown, .closePane,
            .focusNextPane, .focusPreviousPane,
            .nextWorkspace, .previousWorkspace,
            .toggleMarkdownEdit, .toggleZoom, .reopenClosedPane,
            .toggleSearch, .closeSearch, .createScratchpad, .unbind
        ]
        for action in paneActions {
            #expect(!action.isMenuBarAction, "Expected \(action.rawValue) NOT to be a menu bar action")
        }
    }

    @Test func workspaceIndexMapping() {
        #expect(NexAction.switchToWorkspace1.workspaceIndex == 0)
        #expect(NexAction.switchToWorkspace9.workspaceIndex == 8)
        #expect(NexAction.splitRight.workspaceIndex == nil)
    }
}

@MainActor
struct KeyBindingMapTests {
    @Test func defaultsContainAllExpectedBindings() {
        let map = KeyBindingMap.defaults

        // Spot check some defaults
        let cmdD = KeyTrigger(keyCode: 2, modifiers: .command)
        #expect(map.action(for: cmdD) == .splitRight)

        let cmdShiftD = KeyTrigger(keyCode: 2, modifiers: [.command, .shift])
        #expect(map.action(for: cmdShiftD) == .splitDown)

        let cmdW = KeyTrigger(keyCode: 13, modifiers: .command)
        #expect(map.action(for: cmdW) == .closePane)

        let escape = KeyTrigger(keyCode: 53)
        #expect(map.action(for: escape) == .closeSearch)
    }

    @Test func defaultsHaveDualBindingsForFocusNext() {
        let map = KeyBindingMap.defaults
        let triggers = map.triggers(for: .focusNextPane)
        #expect(triggers.count == 2)

        let cmdBracket = KeyTrigger(keyCode: 30, modifiers: .command)
        let cmdOptRight = KeyTrigger(keyCode: 124, modifiers: [.command, .option])
        #expect(triggers.contains(cmdBracket))
        #expect(triggers.contains(cmdOptRight))
    }

    @Test func applyingOverrideReplacesBinding() {
        let original = KeyBindingMap.defaults
        let newTrigger = KeyTrigger(keyCode: 2, modifiers: [.control])
        let map = original.applying(overrides: [(newTrigger, .splitRight)])

        #expect(map.action(for: newTrigger) == .splitRight)
        // Original Cmd+D is still bound (we added, not replaced)
        let cmdD = KeyTrigger(keyCode: 2, modifiers: .command)
        #expect(map.action(for: cmdD) == .splitRight)
    }

    @Test func applyingUnbindRemovesBinding() {
        let cmdD = KeyTrigger(keyCode: 2, modifiers: .command)
        let map = KeyBindingMap.defaults.applying(overrides: [(cmdD, .unbind)])
        #expect(map.action(for: cmdD) == nil)
    }

    @Test func applyingOverrideToExistingTrigger() {
        // Rebind Cmd+D from split_right to split_down
        let cmdD = KeyTrigger(keyCode: 2, modifiers: .command)
        let map = KeyBindingMap.defaults.applying(overrides: [(cmdD, .splitDown)])
        #expect(map.action(for: cmdD) == .splitDown)
    }

    @Test func unboundTriggerReturnsNil() {
        let map = KeyBindingMap.defaults
        let random = KeyTrigger(keyCode: 0) // bare 'a', no modifiers
        #expect(map.action(for: random) == nil)
    }

    @Test func triggersForActionReturnsEmpty() {
        let map = KeyBindingMap(bindings: [:])
        #expect(map.triggers(for: .splitRight).isEmpty)
    }

    @Test func cycleLayoutCategory() {
        #expect(NexAction.cycleLayout.category == "Pane Management")
        #expect(NexAction.cycleLayout.isMenuBarAction == false)
        #expect(NexAction.cycleLayout.displayName == "Cycle Layout")
    }

    @Test func defaultsContainCycleLayout() {
        let map = KeyBindingMap.defaults
        let cmdShiftSpace = KeyTrigger(keyCode: 49, modifiers: [.command, .shift])
        #expect(map.action(for: cmdShiftSpace) == .cycleLayout)
    }

    @Test func renameWorkspaceMetadata() {
        #expect(NexAction(rawValue: "rename_workspace") == .renameWorkspace)
        #expect(NexAction.renameWorkspace.category == "Workspaces")
        #expect(NexAction.renameWorkspace.isMenuBarAction == false)
        #expect(NexAction.renameWorkspace.displayName == "Rename Workspace")
        #expect(NexAction.bindableActions.contains(.renameWorkspace))
    }

    @Test func defaultsContainRenameWorkspace() {
        let map = KeyBindingMap.defaults
        let cmdShiftR = KeyTrigger(keyCode: 15, modifiers: [.command, .shift])
        #expect(map.action(for: cmdShiftR) == .renameWorkspace)
    }

    @Test func createScratchpadMetadata() {
        #expect(NexAction(rawValue: "create_scratchpad") == .createScratchpad)
        #expect(NexAction.createScratchpad.category == "Pane Management")
        #expect(NexAction.createScratchpad.isMenuBarAction == false)
        #expect(NexAction.createScratchpad.displayName == "New Scratchpad")
        #expect(NexAction.bindableActions.contains(.createScratchpad))
    }

    @Test func defaultsContainCreateScratchpad() {
        let map = KeyBindingMap.defaults
        let cmdShiftN = KeyTrigger(keyCode: 45, modifiers: [.command, .shift])
        #expect(map.action(for: cmdShiftN) == .createScratchpad)
    }

    @Test func commandPaletteMetadata() {
        #expect(NexAction(rawValue: "command_palette") == .commandPalette)
        #expect(NexAction.commandPalette.category == "Navigation")
        #expect(NexAction.commandPalette.isMenuBarAction == true)
        #expect(NexAction.commandPalette.displayName == "Command Palette")
        #expect(NexAction.bindableActions.contains(.commandPalette))
    }

    @Test func defaultsContainCommandPalette() {
        let map = KeyBindingMap.defaults
        let cmdP = KeyTrigger(keyCode: 35, modifiers: .command)
        #expect(map.action(for: cmdP) == .commandPalette)
    }
}

@MainActor
struct KeybindingConflictTests {
    private let cmdShiftT = KeyTrigger(keyCode: 17, modifiers: [.command, .shift])
    private let cmdD = KeyTrigger(keyCode: 2, modifiers: .command)
    private let ctrlAltL = KeyTrigger(keyCode: 37, modifiers: [.control, .option])

    @Test func conflictWithExistingActionReturnsAction() {
        let conflict = KeybindingConflict.check(
            trigger: cmdD,
            in: .defaults,
            globalHotkey: nil
        )
        #expect(conflict == .action(.splitRight))
    }

    @Test func conflictWithGlobalHotkeyWins() {
        // cmdShiftT is bound to .reopenClosedPane by default; ensure the
        // global-hotkey check fires first when both would match.
        let conflict = KeybindingConflict.check(
            trigger: cmdShiftT,
            in: .defaults,
            globalHotkey: cmdShiftT
        )
        #expect(conflict == .globalHotkey)
    }

    @Test func conflictExcludingSameActionIsNil() {
        // Re-recording ⌘D for split_right (its current binding) should not
        // report a self-collision.
        let conflict = KeybindingConflict.check(
            trigger: cmdD,
            in: .defaults,
            globalHotkey: nil,
            excluding: .splitRight
        )
        #expect(conflict == nil)
    }

    @Test func conflictExcludingDifferentActionStillReports() {
        // Recording ⌘D for close_pane must still collide with split_right.
        let conflict = KeybindingConflict.check(
            trigger: cmdD,
            in: .defaults,
            globalHotkey: nil,
            excluding: .closePane
        )
        #expect(conflict == .action(.splitRight))
    }

    @Test func ignoreGlobalHotkeyFlagSkipsGlobalMatch() {
        // Editing the global hotkey itself: a match against the current
        // global trigger is not a conflict.
        let conflict = KeybindingConflict.check(
            trigger: cmdShiftT,
            in: KeyBindingMap(),
            globalHotkey: cmdShiftT,
            ignoreGlobalHotkey: true
        )
        #expect(conflict == nil)
    }

    @Test func nonCollidingTriggerReturnsNil() {
        let conflict = KeybindingConflict.check(
            trigger: ctrlAltL,
            in: .defaults,
            globalHotkey: nil
        )
        #expect(conflict == nil)
    }

    @Test func messageIncludesActionDisplayName() {
        #expect(KeybindingConflict.action(.splitRight).message.contains("Split Right"))
        #expect(KeybindingConflict.globalHotkey.message.contains("global hotkey"))
    }
}
