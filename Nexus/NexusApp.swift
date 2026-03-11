import ComposableArchitecture
import SwiftUI

@main
struct NexusApp: App {
    @State private var store = Store(initialState: AppReducer.State()) {
        AppReducer()
    }

    @State private var shortcutMonitor: PaneShortcutMonitor?

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
            NexusCommands(store: store)
        }

        Settings {
            SettingsView(store: store)
        }
    }
}
