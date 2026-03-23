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
                    let config = GhosttyConfigClient.load()
                    GhosttyConfigClient.liveValue = config

                    if let window = NSApp.windows.first {
                        if config.backgroundOpacity < 1 {
                            window.isOpaque = false
                            window.backgroundColor = .white.withAlphaComponent(0.001)
                        }
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
        }

        Settings {
            SettingsView(store: store)
        }
    }
}
