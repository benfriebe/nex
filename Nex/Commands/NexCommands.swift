import ComposableArchitecture
import SwiftUI

/// Menu bar keyboard shortcuts for workspace management.
struct NexCommands: Commands {
    let store: StoreOf<AppReducer>

    var body: some Commands {
        // Replace the default "New Window" (⌘N) with "New Workspace"
        CommandGroup(replacing: .newItem) {
            menuButton("New Workspace", action: .newWorkspace) {
                store.send(.showNewWorkspaceSheet())
            }

            menuButton("New Group", action: .newGroup) {
                // Immediate creation with a placeholder name; the user
                // drops straight into inline rename.
                let placeholder = defaultGroupName(existing: store.groups)
                store.send(.createGroup(name: placeholder, autoRename: true))
            }

            menuButton("Preview Markdown...", action: .openFile) {
                store.send(.openFile)
            }

            menuButton("New Web Pane", action: .openWebPane) {
                // Fresh web pane on a blank URL with the URL bar
                // focused — same reducer path as the ⌘⇧O keybinding.
                store.send(.openWebPanePath(url: "", fromPaneID: nil))
            }

            menuButton("Command Palette", action: .commandPalette) {
                store.send(.toggleCommandPalette)
            }

            Divider()

            // Switch by number: ⌘1–⌘9
            ForEach(0 ..< 9, id: \.self) { index in
                menuButton(
                    "Switch to Workspace \(index + 1)",
                    action: NexCommands.workspaceAction(for: index)
                ) {
                    store.send(.switchToWorkspaceByIndex(index))
                }
            }

            Divider()

            Button("Select All Workspaces") {
                store.send(.selectAllWorkspaces)
            }

            Button("Deselect All Workspaces") {
                store.send(.clearWorkspaceSelection)
            }
            .disabled(store.selectedWorkspaceIDs.isEmpty)
        }

        // View
        CommandGroup(after: .sidebar) {
            menuButton("Toggle Sidebar", action: .toggleSidebar) {
                store.send(.toggleSidebar)
            }

            menuButton("Toggle Inspector", action: .toggleInspector) {
                store.send(.toggleInspector)
            }
        }

        #if DEBUG
            CommandMenu("Debug") {
                Button("Seed Test Group") {
                    store.send(.seedTestGroup)
                }
            }
        #endif
    }

    /// Build a menu Button with the keyboard shortcut derived from the binding map.
    @ViewBuilder
    private func menuButton(
        _ title: String,
        action: NexAction,
        handler: @escaping () -> Void
    ) -> some View {
        if let shortcut = store.configHotkey.keybindings.triggers(for: action).first?.keyboardShortcut {
            Button(title, action: handler)
                .keyboardShortcut(shortcut)
        } else {
            Button(title, action: handler)
        }
    }

    private static func workspaceAction(for index: Int) -> NexAction {
        switch index {
        case 0: .switchToWorkspace1
        case 1: .switchToWorkspace2
        case 2: .switchToWorkspace3
        case 3: .switchToWorkspace4
        case 4: .switchToWorkspace5
        case 5: .switchToWorkspace6
        case 6: .switchToWorkspace7
        case 7: .switchToWorkspace8
        case 8: .switchToWorkspace9
        default: .switchToWorkspace1
        }
    }
}

/// Produce a unique default name for a newly-created group, used when no name
/// has been supplied yet (e.g., the ⌘⇧G menu shortcut).
func defaultGroupName(existing: IdentifiedArrayOf<WorkspaceGroup>) -> String {
    let base = "New Group"
    let names = Set(existing.map(\.name))
    if !names.contains(base) { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") {
        suffix += 1
    }
    return "\(base) \(suffix)"
}

/// Help menu command that opens the Help window.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Nex Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}

/// NSEvent monitor for shortcuts that need focused-pane context.
/// These can't go through SwiftUI Commands because they need to know
/// which pane is focused.
@MainActor
final class PaneShortcutMonitor {
    private var monitor: Any?
    private let store: StoreOf<AppReducer>

    init(store: StoreOf<AppReducer>) {
        self.store = store
    }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handleKeyEvent(event) ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Don't consume shortcuts when a secondary window (Help, Settings) is key.
        if let keyWindow = NSApp.keyWindow,
           keyWindow != NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            return false
        }

        // While command palette is visible, suppress pane shortcuts so typing works.
        if store.isCommandPaletteVisible {
            return false
        }

        // Escape clears an active workspace multi-selection.
        if event.keyCode == 53, !store.selectedWorkspaceIDs.isEmpty {
            store.send(.clearWorkspaceSelection)
            return true
        }

        guard let activeID = store.activeWorkspaceID else { return false }

        let trigger = KeyTrigger(event: event)

        // Belt-and-braces: if the user configured a global hotkey that also
        // matches an in-app binding, skip the in-app dispatch. Carbon
        // normally consumes matching events at the WindowServer level before
        // Cocoa sees them, but this guard keeps behavior consistent even if
        // the dispatcher order ever changes.
        if store.configHotkey.globalHotkey == trigger { return false }

        // Web pane priority layer: when the focused pane is a `.web`
        // pane, consult a hard-coded ⌘L / ⌘R / ⌘[ / ⌘] map *before*
        // falling through to the normal keybinding lookup. This way
        // the global defaults (close pane / focus prev / focus next /
        // markdown font) keep working for every other pane type while
        // web panes get browser-style shortcuts.
        if let consumed = handleWebPanePriorityShortcut(
            event: event,
            trigger: trigger,
            activeWorkspaceID: activeID
        ) {
            return consumed
        }

        guard let action = store.configHotkey.keybindings.action(for: trigger) else { return false }

        // Menu bar actions are handled by SwiftUI Commands — don't consume here.
        if action.isMenuBarAction { return false }

        return dispatchAction(action, activeWorkspaceID: activeID)
    }

    /// Web pane priority layer. Returns:
    /// - `true`  - event consumed by a web action
    /// - `false` - event consumed by an intentional fall-through
    ///   (e.g. URL bar editing + ⌘[ shouldn't trip back)
    /// - `nil`   - not applicable, the main layer should run
    private func handleWebPanePriorityShortcut(
        event _: NSEvent,
        trigger: KeyTrigger,
        activeWorkspaceID id: UUID
    ) -> Bool? {
        guard let workspace = store.workspaces[id: id],
              let focusedID = workspace.focusedPaneID,
              let pane = workspace.panes[id: focusedID],
              pane.type == .web else { return nil }

        // ⌘ alone, no shift / ctrl / option.
        let isPlainCommand = trigger.modifiers == .command
        let isCmdShift = trigger.modifiers == [.command, .shift]
        // ⌘[ / ⌘] — only intercept when the URL bar isn't editing.
        // The bar is an NSTextField, which becomes the window's
        // firstResponder via its NSText editor when typing.
        let urlBarIsEditing: Bool = {
            guard let keyWindow = NSApp.keyWindow,
                  let responder = keyWindow.firstResponder else { return false }
            return responder is NSText
        }()

        switch (trigger.keyCode, isPlainCommand, isCmdShift) {
        case (37, true, _): // ⌘L
            store.send(.webPaneFocusURLBar(paneID: focusedID))
            return true
        case (15, true, _): // ⌘R
            store.send(.workspaces(.element(
                id: id,
                action: .webPaneReload(paneID: focusedID, hard: false)
            )))
            return true
        case (33, true, _): // ⌘[
            if urlBarIsEditing { return nil } // fall through to focusPreviousPane
            store.send(.workspaces(.element(
                id: id,
                action: .webPaneBack(paneID: focusedID)
            )))
            return true
        case (30, true, _): // ⌘]
            if urlBarIsEditing { return nil }
            store.send(.workspaces(.element(
                id: id,
                action: .webPaneForward(paneID: focusedID)
            )))
            return true
        case (17, true, _): // ⌘T → new tab
            store.send(.webPaneOpenNewTab(paneID: focusedID, url: nil))
            return true
        case (13, true, _): // ⌘W → close tab (falls through to closePane on the last tab)
            guard let webState = workspace.webPanes[focusedID],
                  webState.tabs.count > 1,
                  let activeTabID = webState.activeTab?.id else { return nil }
            store.send(.workspaces(.element(
                id: id,
                action: .webPaneTabClose(paneID: focusedID, tabID: activeTabID)
            )))
            return true
        case (33, false, true): // ⌘⇧[ → previous tab
            if urlBarIsEditing { return nil }
            store.send(.webPaneTabCycleFocused(offset: -1))
            return true
        case (30, false, true): // ⌘⇧] → next tab
            if urlBarIsEditing { return nil }
            store.send(.webPaneTabCycleFocused(offset: 1))
            return true
        default:
            return nil
        }
    }

    // MARK: - Action Dispatch

    private func dispatchAction(_ action: NexAction, activeWorkspaceID id: UUID) -> Bool {
        switch action {
        case .splitRight:
            store.send(.workspaces(.element(
                id: id,
                action: .splitPane(direction: .horizontal, sourcePaneID: nil)
            )))
            return true

        case .splitDown:
            store.send(.workspaces(.element(
                id: id,
                action: .splitPane(direction: .vertical, sourcePaneID: nil)
            )))
            return true

        case .closePane:
            return handleClosePane(activeWorkspaceID: id)

        case .focusNextPane:
            store.send(.workspaces(.element(id: id, action: .focusNextPane)))
            return true

        case .focusPreviousPane:
            store.send(.workspaces(.element(id: id, action: .focusPreviousPane)))
            return true

        case .nextWorkspace:
            store.send(.switchToNextWorkspace)
            return true

        case .previousWorkspace:
            store.send(.switchToPreviousWorkspace)
            return true

        case .toggleMarkdownEdit:
            return handleToggleMarkdownEdit(activeWorkspaceID: id)

        case .increaseMarkdownFontSize:
            return handleMarkdownFontSize(activeWorkspaceID: id) { .increaseMarkdownFontSize($0) }

        case .decreaseMarkdownFontSize:
            return handleMarkdownFontSize(activeWorkspaceID: id) { .decreaseMarkdownFontSize($0) }

        case .resetMarkdownFontSize:
            return handleMarkdownFontSize(activeWorkspaceID: id) { .resetMarkdownFontSize($0) }

        case .toggleZoom:
            store.send(.workspaces(.element(id: id, action: .toggleZoomPane)))
            return true

        case .reopenClosedPane:
            store.send(.workspaces(.element(id: id, action: .reopenClosedPane)))
            return true

        case .toggleSearch:
            store.send(.workspaces(.element(id: id, action: .toggleSearch)))
            return true

        case .closeSearch:
            return handleCloseSearch(activeWorkspaceID: id)

        case .cycleLayout:
            store.send(.workspaces(.element(id: id, action: .cycleLayout)))
            return true

        case .movePaneLeft:
            store.send(.workspaces(.element(id: id, action: .movePaneInDirection(.left))))
            return true

        case .movePaneRight:
            store.send(.workspaces(.element(id: id, action: .movePaneInDirection(.right))))
            return true

        case .movePaneUp:
            store.send(.workspaces(.element(id: id, action: .movePaneInDirection(.up))))
            return true

        case .movePaneDown:
            store.send(.workspaces(.element(id: id, action: .movePaneInDirection(.down))))
            return true

        case .createScratchpad:
            store.send(.workspaces(.element(id: id, action: .createScratchpad)))
            return true

        case .renameWorkspace:
            store.send(.beginRenameActiveWorkspace)
            return true

        case .openDiff:
            return handleOpenDiff(activeWorkspaceID: id)

        case .toggleSyncInput:
            store.send(.workspaces(.element(id: id, action: .toggleSyncInput)))
            return true

        case .openWebPane:
            // Open a fresh web pane on a blank URL — user can type
            // one in the URL bar. Matches what ⌘L does for a brand-new
            // pane. No `--here` semantics here; that's reserved for
            // the explicit CLI flow.
            store.send(.openWebPanePath(url: "", fromPaneID: nil))
            return true

        case .webFocusURLBar:
            return handleWebAction(activeWorkspaceID: id) { paneID in
                .webPaneFocusURLBar(paneID: paneID)
            }

        case .webBack:
            return handleWebAction(activeWorkspaceID: id) { paneID in
                .workspaces(.element(id: id, action: .webPaneBack(paneID: paneID)))
            }

        case .webForward:
            return handleWebAction(activeWorkspaceID: id) { paneID in
                .workspaces(.element(id: id, action: .webPaneForward(paneID: paneID)))
            }

        case .webReload:
            return handleWebAction(activeWorkspaceID: id) { paneID in
                .workspaces(.element(id: id, action: .webPaneReload(paneID: paneID, hard: false)))
            }

        case .webTabNew:
            return handleWebAction(activeWorkspaceID: id) { paneID in
                .webPaneOpenNewTab(paneID: paneID, url: nil)
            }

        case .webTabClose:
            // Single-tab panes fall through (returns false) so the
            // binding doesn't no-op — the user's keymap can route ⌘W
            // to the workspace-level close-pane action instead.
            guard let workspace = store.workspaces[id: id],
                  let focusedID = workspace.focusedPaneID,
                  workspace.panes[id: focusedID]?.type == .web,
                  let webState = workspace.webPanes[focusedID],
                  webState.tabs.count > 1,
                  let activeTabID = webState.activeTab?.id else { return false }
            store.send(.workspaces(.element(
                id: id,
                action: .webPaneTabClose(paneID: focusedID, tabID: activeTabID)
            )))
            return true

        case .webTabPrev:
            return handleWebAction(activeWorkspaceID: id) { _ in
                .webPaneTabCycleFocused(offset: -1)
            }

        case .webTabNext:
            return handleWebAction(activeWorkspaceID: id) { _ in
                .webPaneTabCycleFocused(offset: 1)
            }

        default:
            return false
        }
    }

    /// Run a web-pane action only when the focused pane is `.web`,
    /// returning false (so the keybinding can fall through to a
    /// non-web default) otherwise. Mirrors `handleMarkdownFontSize`.
    private func handleWebAction(
        activeWorkspaceID id: UUID,
        _ build: (UUID) -> AppReducer.Action
    ) -> Bool {
        guard let workspace = store.workspaces[id: id],
              let focusedID = workspace.focusedPaneID,
              workspace.panes[id: focusedID]?.type == .web
        else { return false }
        store.send(build(focusedID))
        return true
    }

    // MARK: - Conditional Handlers

    private func handleClosePane(activeWorkspaceID id: UUID) -> Bool {
        guard let workspace = store.workspaces[id: id],
              let focusedID = workspace.focusedPaneID
        else { return false }

        // Last pane — close the workspace instead
        if workspace.panes.count <= 1 {
            store.send(.deleteWorkspace(id))
            return true
        }

        store.send(.workspaces(.element(id: id, action: .closePane(focusedID))))
        return true
    }

    private func handleToggleMarkdownEdit(activeWorkspaceID id: UUID) -> Bool {
        guard let workspace = store.workspaces[id: id],
              let focusedID = workspace.focusedPaneID,
              workspace.panes[id: focusedID]?.type == .markdown
        else { return false }

        store.send(.workspaces(.element(id: id, action: .toggleMarkdownEdit(focusedID))))
        return true
    }

    private func handleMarkdownFontSize(
        activeWorkspaceID id: UUID,
        action: (UUID) -> WorkspaceFeature.Action
    ) -> Bool {
        guard let workspace = store.workspaces[id: id],
              let focusedID = workspace.focusedPaneID,
              let pane = workspace.panes[id: focusedID],
              pane.type == .markdown,
              !pane.isEditing
        else { return false }

        store.send(.workspaces(.element(id: id, action: action(focusedID))))
        return true
    }

    private func handleOpenDiff(activeWorkspaceID id: UUID) -> Bool {
        guard let workspace = store.workspaces[id: id],
              let focusedID = workspace.focusedPaneID,
              let pane = workspace.panes[id: focusedID]
        else { return false }
        store.send(.openDiffPath(
            repoPath: pane.workingDirectory,
            targetPath: nil,
            fromPaneID: focusedID
        ))
        return true
    }

    private func handleCloseSearch(activeWorkspaceID id: UUID) -> Bool {
        guard let workspace = store.workspaces[id: id],
              workspace.searchingPaneID != nil
        else { return false }

        store.send(.workspaces(.element(id: id, action: .searchClose)))
        return true
    }
}
