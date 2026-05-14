import ComposableArchitecture
import Sparkle
import SwiftUI

@main
struct NexApp: App {
    @NSApplicationDelegateAdaptor(NexAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var store = Store(initialState: AppReducer.State()) {
        AppReducer()
    }

    @State private var shortcutMonitor: PaneShortcutMonitor?
    @State private var didLaunch = false
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
        // Single-instance Window (not WindowGroup) so closing it via ⌘W or
        // the red traffic light leaves a recoverable scene: openWindow(id:
        // "main") brings it back. A `Window` matched against an
        // `applicationShouldHandleReopen` adaptor is the standard macOS
        // pattern for "let the user close everything and still find their
        // way back to the app".
        Window("Nex", id: "main") {
            ContentView(store: store)
                .environment(\.surfaceManager, SurfaceManager.liveValue)
                .environment(\.socketServer, SocketServer.liveValue)
                .environment(\.ghosttyConfig, .liveValue)
                .background(SpacesBindingAttacher())
                .frame(minWidth: 600, minHeight: 400)
                .onAppear {
                    guard !Self.isTestMode else { return }

                    // Re-capture each mount so the closure tracks the
                    // current scene's openWindow action. Cheap and
                    // protects against any future scene-restart edge cases.
                    appDelegate.reopenHandler = { openWindow(id: "main") }

                    // Init below runs once per app launch. If the user
                    // closes the only window and reopens it via dock
                    // click or Window > Show Window, this body re-mounts
                    // and onAppear fires again — but StatusBarController
                    // and PaneShortcutMonitor would double-up without a
                    // guard.
                    guard !didLaunch else { return }
                    didLaunch = true

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
            ShowWindowCommands()
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

/// Attaches the user's macOS Dock Spaces binding to the main window
/// (issue #102). SwiftUI creates the window early, before WindowServer
/// applies the per-bundle binding after a system restart; reading it
/// from `com.apple.spaces` and applying it ourselves makes "Assign To:
/// All Desktops" survive reboots.
///
/// The hosting view's `viewDidMoveToWindow` is the only deterministic
/// hook for "this view is now parented in a real NSWindow". `.onAppear`
/// fires later and `makeNSView` fires earlier (when `view.window` is
/// still nil).
private struct SpacesBindingAttacher: NSViewRepresentable {
    func makeNSView(context _: Context) -> SpacesBindingView {
        SpacesBindingView()
    }

    func updateNSView(_: SpacesBindingView, context _: Context) {
        // No-op: SpacesBindingView applies the binding once in
        // viewDidMoveToWindow. Re-renders are intentionally ignored.
    }
}

private final class SpacesBindingView: NSView {
    private var didApply = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didApply, let window else { return }
        didApply = true
        WindowSpacesBinding.applyIfNeeded(to: window)
    }
}

/// Reopens the main window when the user reactivates the app (dock click,
/// Spotlight launch, etc.) with no visible window. Without this, ⌘W or
/// the red traffic light leaves the app running with no obvious way back —
/// we replace `File > New Window` with our own commands, so the system's
/// default "click dock to open a new window" path doesn't apply.
@MainActor
final class NexAppDelegate: NSObject, @preconcurrency NSApplicationDelegate {
    /// Installed by `NexApp` once the scene mounts. Captures the
    /// SwiftUI `openWindow` environment action targeting the "main"
    /// scene id.
    var reopenHandler: (() -> Void)?

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            reopenHandler?()
        }
        return true
    }
}
