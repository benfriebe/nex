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
    @State private var titlebarZoomMonitor: TitlebarDoubleClickMonitor?
    /// One-shot guard so the heavy `.onAppear` bootstrap (store launch,
    /// socket server, ghostty start, monitors) runs exactly once for the
    /// app, not per WindowGroup window. Without this, any second window
    /// re-runs `.appLaunched`, reloading persistence and clobbering live
    /// state — e.g. wiping a just-opened markdown pane (#197).
    @State private var didBootstrap = false
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
                .background(DuplicateMainWindowCloser())
                .background(WindowFrameRestorer())
                .frame(minWidth: 600, minHeight: 400)
                // An appearance change updates `liveValue` and posts this; mirror
                // it into @State so the env re-injects and the non-terminal panes
                // pick up the new terminal background live.
                .onReceive(NotificationCenter.default.publisher(for: GhosttyConfigClient.changedNotification)) { _ in
                    ghosttyConfig = .liveValue
                }
                .onAppear {
                    guard !Self.isTestMode else { return }
                    // Bootstrap once per app, never per window (see didBootstrap).
                    guard !didBootstrap else { return }
                    didBootstrap = true

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
                        // `.hiddenTitleBar` the custom title bar's
                        // `WindowDragRegion` drives both window dragging and
                        // double-click zoom/minimise explicitly (see
                        // `WindowTitleBar.swift`), scoped to the bar so the
                        // sidebar drags stay intact.
                    }

                    // Global hotkey callback — registration happens from the
                    // `.configLoaded` effect so it runs once the user's trigger
                    // has actually been parsed off disk.
                    GlobalHotkeyService.shared.onPressed = {
                        store.send(.configHotkey(.globalHotkeyPressed))
                    }

                    store.send(.appLaunched)

                    // Wire the Finder "Open With" bridge: NexAppDelegate
                    // hands opened markdown files to FileOpenGate, which we
                    // forward into the same reducer path as drag-and-drop.
                    // Any file that arrived during cold launch (before this
                    // ran) is replayed now; the reducer queues it further if
                    // the async state load hasn't set a workspace yet (#197).
                    FileOpenGate.shared.connect { path in
                        store.send(.openFileAtPath(path, fromPaneID: nil))
                    }

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
                        // Stop every session the SERVICE holds (not the
                        // store's mirror — the mirror can lose track of
                        // live sessions, issue #231). Block (with a
                        // 2-second cap) so the breadcrumb files are
                        // gone before the process exits. Sessions that
                        // can't stop in time fall back to the orphan
                        // recovery path on next launch.
                        let service = GraftService.liveValue
                        let semaphore = DispatchSemaphore(value: 0)
                        Task.detached {
                            for session in await service.activeSessions() {
                                try? await service.stop(session.id)
                            }
                            semaphore.signal()
                        }
                        _ = semaphore.wait(timeout: .now() + 2)
                    }

                    let monitor = PaneShortcutMonitor(store: store)
                    monitor.start()
                    shortcutMonitor = monitor

                    // Restore double-click-to-zoom on the hidden titlebar (#199).
                    let zoomMonitor = TitlebarDoubleClickMonitor()
                    zoomMonitor.start()
                    titlebarZoomMonitor = zoomMonitor
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

/// Nex is a single-window app, but SwiftUI's `WindowGroup` spawns an
/// extra window when the already-running app is handed a document to open
/// (Finder "Open With" → the `openDocuments` Apple event). Our
/// `NexAppDelegate.application(_:open:)` already routes the opened file
/// into the existing window's active workspace, so that spawned window is
/// a redundant duplicate of the current session. This attacher records
/// the first main window and closes any later one, keeping the app
/// single-window (#197). Only the main `WindowGroup` content embeds it —
/// Settings and the Help window are separate scenes and never get it.
private struct DuplicateMainWindowCloser: NSViewRepresentable {
    func makeNSView(context _: Context) -> DuplicateMainWindowCloserView {
        DuplicateMainWindowCloserView()
    }

    func updateNSView(_: DuplicateMainWindowCloserView, context _: Context) {}
}

@MainActor
enum MainWindowRegistry {
    weak static var primary: NSWindow?

    /// Claims `window` as the primary main window if none is registered yet
    /// (or it's the same window), returning whether `window` is the primary.
    /// `false` means it's a duplicate — a second main WindowGroup window
    /// SwiftUI spawned for a file-open on the already-running app. Both
    /// `DuplicateMainWindowCloser` and `WindowFrameRestorer` route through
    /// this so the answer is stable regardless of which `.background`
    /// attachment's `viewDidMoveToWindow` fires first.
    static func isPrimary(_ window: NSWindow) -> Bool {
        if primary == nil || primary === window {
            primary = window
            return true
        }
        return false
    }

    /// Clears the primary registration when the primary window closes, so a
    /// window reopened from the Dock (app still running after its last window
    /// closed) can claim primary again instead of being treated as a
    /// duplicate. The `weak` ref only zeroes on dealloc, whose timing isn't
    /// guaranteed to precede the reopen.
    static func relinquishIfPrimary(_ window: NSWindow) {
        if primary === window {
            primary = nil
        }
    }
}

private final class DuplicateMainWindowCloserView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The first main window (cold launch / normal) becomes the primary.
        if MainWindowRegistry.isPrimary(window) { return }
        // A second main window — SwiftUI spawned it for a file-open on the
        // already-running app. Close it; the file was already routed into
        // the primary window's workspace by NexAppDelegate.
        DispatchQueue.main.async { [weak window] in
            window?.close()
        }
    }
}
