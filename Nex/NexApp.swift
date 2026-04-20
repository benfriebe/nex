import ComposableArchitecture
import Sparkle
import SwiftUI

@main
struct NexApp: App {
    @State private var store = Store(initialState: AppReducer.State()) {
        AppReducer()
    }

    @State private var shortcutMonitor: PaneShortcutMonitor?
    @StateObject private var updaterViewModel = UpdaterViewModel(
        startUpdater: !NexApp.isTestMode
    )

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    static var isTestMode: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environment(\.surfaceManager, SurfaceManager.liveValue)
                .environment(\.socketServer, SocketServer.liveValue)
                .environment(\.ghosttyConfig, .liveValue)
                .frame(minWidth: 600, minHeight: 400)
                .onAppear {
                    guard !Self.isTestMode else { return }

                    // Keep the global /usr/local/bin/nex symlink and installed
                    // nex-agentic skill in sync with the running bundle after
                    // Sparkle auto-updates (see issue #39).
                    Task.detached(priority: .utility) {
                        CLIInstallService.healIfNeeded()
                    }

                    // Warm the editor resolver cache on a background queue
                    // so the first ⌘E press on a markdown pane doesn't stall
                    // the reducer while we shell out to read $EDITOR.
                    EditorService.liveValue.warmUp()

                    GhosttyApp.shared.start()

                    // Notification service — permission + action callback
                    let notifService = NotificationService.liveValue
                    notifService.requestPermission()
                    notifService.onOpenPane = { paneID, workspaceID in
                        store.send(.setActiveWorkspace(workspaceID))
                        store.send(.workspaces(.element(id: workspaceID, action: .focusPane(paneID))))
                    }

                    // Status bar — menu bar icon + popover
                    let statusBar = StatusBarController.liveValue
                    statusBar.setup()
                    statusBar.onSelectPane = { paneID, workspaceID in
                        store.send(.setActiveWorkspace(workspaceID))
                        store.send(.workspaces(.element(id: workspaceID, action: .focusPane(paneID))))
                        NSApp.activate()
                        if let window = NSApp.windows.first {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }

                    // Populate config dependency from the live ghostty config
                    var config = GhosttyConfigClient.load()

                    // Apply saved appearance settings BEFORE creating surfaces so
                    // panes start with the correct background from the first frame.
                    let defaults = UserDefaults.standard
                    if defaults.object(forKey: SettingsFeature.defaultsKeyOpacity) != nil {
                        config.backgroundOpacity = defaults.double(forKey: SettingsFeature.defaultsKeyOpacity)
                    }
                    if defaults.bool(forKey: SettingsFeature.defaultsKeyHasCustomColor) {
                        let r = defaults.double(forKey: SettingsFeature.defaultsKeyColorR)
                        let g = defaults.double(forKey: SettingsFeature.defaultsKeyColorG)
                        let b = defaults.double(forKey: SettingsFeature.defaultsKeyColorB)
                        config.backgroundColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
                    }

                    GhosttyConfigClient.liveValue = config

                    if let window = NSApp.windows.first {
                        if config.backgroundOpacity < 1 {
                            window.isOpaque = false
                            window.backgroundColor = .white.withAlphaComponent(0.001)
                        }
                    }

                    // Global hotkey callback — registration happens from the
                    // `.configLoaded` effect so it runs once the user's trigger
                    // has actually been parsed off disk.
                    GlobalHotkeyService.shared.onPressed = {
                        store.send(.globalHotkeyPressed)
                    }

                    store.send(.appLaunched)

                    let monitor = PaneShortcutMonitor(store: store)
                    monitor.start()
                    shortcutMonitor = monitor
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
            NexCommands(store: store)
            HelpCommands()
        }

        Settings {
            SettingsView(store: store)
        }

        Window("Nex Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
