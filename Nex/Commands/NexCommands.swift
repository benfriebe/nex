import ComposableArchitecture
import SwiftUI

/// Menu bar keyboard shortcuts for workspace management.
struct NexCommands: Commands {
    let store: StoreOf<AppReducer>

    var body: some Commands {
        // Replace the default "New Window" (⌘N) with "New Workspace"
        CommandGroup(replacing: .newItem) {
            Button("New Workspace") {
                store.send(.showNewWorkspaceSheet)
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open File...") {
                store.send(.openFile)
            }
            .keyboardShortcut("o", modifiers: [.command])

            Divider()

            // Switch by number: ⌘1–⌘9
            ForEach(0 ..< 9, id: \.self) { index in
                Button("Switch to Workspace \(index + 1)") {
                    store.send(.switchToWorkspaceByIndex(index))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
            }
        }

        // View
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                store.send(.toggleSidebar)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Toggle Inspector") {
                store.send(.toggleInspector)
            }
            .keyboardShortcut("i", modifiers: [.command])
        }
    }
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

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard let activeID = store.activeWorkspaceID else { return false }

        // ⌘D — split right
        if event.keyCode == 2 /* d */, flags == .command {
            store.send(.workspaces(.element(
                id: activeID,
                action: .splitPane(direction: .horizontal, sourcePaneID: nil)
            )))
            return true
        }

        // ⌘⇧D — split down
        if event.keyCode == 2 /* d */, flags == [.command, .shift] {
            store.send(.workspaces(.element(
                id: activeID,
                action: .splitPane(direction: .vertical, sourcePaneID: nil)
            )))
            return true
        }

        // ⌘W — close pane
        if event.keyCode == 13 /* w */, flags == .command {
            if let workspace = store.workspaces[id: activeID],
               let focusedID = workspace.focusedPaneID {
                // Last pane — close the workspace instead
                if workspace.panes.count <= 1 {
                    store.send(.deleteWorkspace(activeID))
                    return true
                }
                store.send(.workspaces(.element(
                    id: activeID,
                    action: .closePane(focusedID)
                )))
                return true
            }
            return false
        }

        // Arrow keys include .numericPad and .function in their modifier flags
        let arrowFlags = flags.subtracting([.numericPad, .function])

        // ⌘⌥→ or ⌘] — focus next pane
        let isNextPane = (event.keyCode == 124 && arrowFlags == [.command, .option])
            || (event.keyCode == 30 && flags == .command)
        if isNextPane {
            store.send(.workspaces(.element(
                id: activeID,
                action: .focusNextPane
            )))
            return true
        }

        // ⌘⌥← or ⌘[ — focus previous pane
        let isPreviousPane = (event.keyCode == 123 && arrowFlags == [.command, .option])
            || (event.keyCode == 33 && flags == .command)
        if isPreviousPane {
            store.send(.workspaces(.element(
                id: activeID,
                action: .focusPreviousPane
            )))
            return true
        }

        // ⌘⌥↓ — next workspace
        if event.keyCode == 125 /* ↓ */, arrowFlags == [.command, .option] {
            store.send(.switchToNextWorkspace)
            return true
        }

        // ⌘⌥↑ — previous workspace
        if event.keyCode == 126 /* ↑ */, arrowFlags == [.command, .option] {
            store.send(.switchToPreviousWorkspace)
            return true
        }

        // ⌘E — toggle markdown edit/preview
        if event.keyCode == 14 /* e */, flags == .command {
            if let workspace = store.workspaces[id: activeID],
               let focusedID = workspace.focusedPaneID,
               workspace.panes[id: focusedID]?.type == .markdown {
                store.send(.workspaces(.element(
                    id: activeID,
                    action: .toggleMarkdownEdit(focusedID)
                )))
                return true
            }
        }

        // ⌘⇧↩ — toggle zoom pane
        if event.keyCode == 36 /* Return */, flags == [.command, .shift] {
            store.send(.workspaces(.element(
                id: activeID,
                action: .toggleZoomPane
            )))
            return true
        }

        // ⌘⇧T — reopen closed pane
        if event.keyCode == 17 /* t */, flags == [.command, .shift] {
            store.send(.workspaces(.element(
                id: activeID,
                action: .reopenClosedPane
            )))
            return true
        }

        // ⌘F — toggle search
        if event.keyCode == 3 /* f */, flags == .command {
            store.send(.workspaces(.element(
                id: activeID,
                action: .toggleSearch
            )))
            return true
        }

        // Escape — close search (only when search is active)
        if event.keyCode == 53 /* Escape */, flags.isEmpty {
            if let workspace = store.workspaces[id: activeID],
               workspace.searchingPaneID != nil {
                store.send(.workspaces(.element(
                    id: activeID,
                    action: .searchClose
                )))
                return true
            }
        }

        return false
    }
}
