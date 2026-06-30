import ComposableArchitecture
import Sparkle
import SwiftUI

@main
struct NexApp: App {
    @NSApplicationDelegateAdaptor(NexAppDelegate.self) private var appDelegate

    @State private var store = Store(initialState: AppReducer.State()) {
        AppReducer()
    }

    @State private var shortcutMonitor: PaneShortcutMonitor?
    // Holds the loaded ghostty config so the `\.ghosttyConfig` environment
    // reflects the real terminal background once it's read in `.onAppear`.
    // Injecting `.liveValue` directly captured the pre-load default
    // (windowBackgroundColor), so markdown / scratchpad / diff panes rendered a
    // different background from the terminal surfaces.
    @State private var ghosttyConfig = GhosttyConfigClient()
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
            RootChromeView(store: store)
                .environment(\.surfaceManager, SurfaceManager.liveValue)
                .environment(\.socketServer, SocketServer.liveValue)
                .environment(\.ghosttyConfig, ghosttyConfig)
                .environment(\.webPaneStore, WebPaneStore.liveValue)
                .background(SpacesBindingAttacher())
                .frame(minWidth: 600, minHeight: 400)
                // An appearance change updates `liveValue` and posts this; mirror
                // it into @State so the env re-injects and the non-terminal panes
                // pick up the new terminal background live.
                .onReceive(NotificationCenter.default.publisher(for: GhosttyConfigClient.changedNotification)) { _ in
                    ghosttyConfig = .liveValue
                }
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
                        // Raise the window FIRST. Making it key restores its
                        // previous first responder (the previously-focused
                        // surface), whose `becomeFirstResponder` re-emits
                        // `paneFocusedNotification` and syncs focus back to the
                        // OLD pane. Setting the new focus before that lets the
                        // restoration revert it — which is why selecting a pane
                        // in the already-active workspace snapped back to the
                        // old pane (cross-workspace the old surface isn't in
                        // view, so nothing reverts).
                        NSApp.activate()
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                        store.send(.setActiveWorkspace(workspaceID))
                        // Apply focus after the window has restored its old
                        // first responder, so our selection is the last word.
                        DispatchQueue.main.async {
                            store.send(.workspaces(.element(id: workspaceID, action: .focusPane(paneID))))
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
                    // Drive the environment so the pane views (markdown /
                    // scratchpad / diff) pick up the real terminal background.
                    ghosttyConfig = config

                    if let window = NSApp.windows.first {
                        if config.backgroundOpacity < 1 {
                            window.isOpaque = false
                            window.backgroundColor = .white.withAlphaComponent(0.001)
                        }
                        // NB: do NOT set `isMovableByWindowBackground` — it turns
                        // the whole window (incl. the sidebar) into a drag handle,
                        // which hijacks sidebar row/group reordering. With
                        // `.hiddenTitleBar` the titlebar region the custom title
                        // bar overlaps is already window-draggable (its
                        // non-interactive SwiftUI content reports
                        // mouseDownCanMoveWindow), so the bar still moves the
                        // window without breaking sidebar drags.
                    }

                    // Global hotkey callback — registration happens from the
                    // `.configLoaded` effect so it runs once the user's trigger
                    // has actually been parsed off disk.
                    GlobalHotkeyService.shared.onPressed = {
                        store.send(.configHotkey(.globalHotkeyPressed))
                    }

                    store.send(.appLaunched)

                    // Wire the quit-confirmation summary + the markdown save
                    // flush. NexAppDelegate's applicationShouldTerminate calls
                    // both synchronously to (a) decide whether to show the
                    // dialog and (b) drain any in-flight debounced markdown
                    // writes so the 500ms autosave window can't drop edits
                    // when the user hits Cmd+Q (issue #129).
                    QuitGate.shared.summarize = {
                        store.withState { $0.activeAgentSummary }
                    }
                    QuitGate.shared.flushPendingSaves = {
                        MarkdownEditorRegistry.shared.flushAll()
                    }

                    QuitGate.shared.flushGraftSessions = {
                        // Snapshot active session IDs from the store and
                        // call graftService.stop on each. Block (with a
                        // 2-second cap) so the breadcrumb files are
                        // gone before the process exits. Sessions that
                        // can't stop in time fall back to the orphan
                        // recovery path on next launch.
                        let sessionIDs = store.withState { $0.graft.sessions.ids }
                        guard !sessionIDs.isEmpty else { return }
                        let service = GraftService.liveValue
                        let semaphore = DispatchSemaphore(value: 0)
                        Task.detached {
                            for id in sessionIDs {
                                try? await service.stop(id)
                            }
                            semaphore.signal()
                        }
                        _ = semaphore.wait(timeout: .now() + 2)
                    }

                    let monitor = PaneShortcutMonitor(store: store)
                    monitor.start()
                    shortcutMonitor = monitor
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
            NexCommands(store: store)
            HelpCommands()
        }

        Settings {
            ChromeThemed(store: store) {
                SettingsView(store: store)
            }
        }

        Window("Nex Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Attaches the user's macOS Dock Spaces binding to the main window
/// (issue #102). SwiftUI's WindowGroup creates the window early, before
/// WindowServer applies the per-bundle binding after a system restart;
/// reading it from `com.apple.spaces` and applying it ourselves makes
/// "Assign To: All Desktops" survive reboots.
///
/// The hosting view's `viewDidMoveToWindow` is the only deterministic
/// hook for "this view is now parented in a real NSWindow". `.onAppear`
/// fires later and `makeNSView` fires earlier (when `view.window` is
/// still nil). Each WindowGroup instance gets its own attacher, which
/// is the right behaviour if SwiftUI ever opens multiple main windows.
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
