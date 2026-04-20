import ComposableArchitecture
import SwiftUI

/// Menu bar keyboard shortcuts for workspace management.
struct NexCommands: Commands {
    let store: StoreOf<AppReducer>

    var body: some Commands {
        // Replace the default "New Window" (⌘N) with "New Workspace"
        CommandGroup(replacing: .newItem) {
            menuButton("New Workspace", action: .newWorkspace) {
                store.send(.showNewWorkspaceSheet)
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
        if let shortcut = store.keybindings.triggers(for: action).first?.keyboardShortcut {
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
        if store.globalHotkey == trigger { return false }

        guard let action = store.keybindings.action(for: trigger) else { return false }

        // Menu bar actions are handled by SwiftUI Commands — don't consume here.
        if action.isMenuBarAction { return false }

        return dispatchAction(action, activeWorkspaceID: activeID)
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

        default:
            return false
        }
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

    private func handleCloseSearch(activeWorkspaceID id: UUID) -> Bool {
        guard let workspace = store.workspaces[id: id],
              workspace.searchingPaneID != nil
        else { return false }

        store.send(.workspaces(.element(id: id, action: .searchClose)))
        return true
    }
}
