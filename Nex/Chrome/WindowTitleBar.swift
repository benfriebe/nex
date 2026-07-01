import AppKit
import ComposableArchitecture
import SwiftUI

/// Custom in-content window title bar shown under the hidden native
/// titlebar (`.windowStyle(.hiddenTitleBar)`). Centres the active
/// workspace identity (status dot · name · pane count). Traffic
/// lights float over its leading edge; window dragging is handled by the
/// `WindowDragRegion`.
///
/// This bar is drawn as *content* under the transparent native titlebar
/// (via `ignoresSafeArea`), so the macOS titlebar owns mouse events in the
/// top strip and any interactive control placed here would be unclickable.
/// The identity + background are non-interactive, so that's fine; the
/// right-hand chrome controls (••• menu, sidebar toggle) instead live in a
/// native trailing titlebar accessory (`TitlebarTrailingControls`, installed
/// in `NexApp`) which the titlebar *does* route clicks to.
///
/// A distinct child view with its own `WithPerceptionTracking` so it
/// re-renders in Release builds when the active workspace / pane state
/// changes (the outer `WithPerceptionTracking` is a no-op there).
struct WindowTitleBar: View {
    let store: StoreOf<AppReducer>
    @Environment(\.chromeTheme) private var theme
    /// Owned here (an in-scene view) so the titlebar-accessory ••• menu — which
    /// is outside the SwiftUI scene and can't reach `openSettings` itself — can
    /// relay through `nexOpenSettings`.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        WithPerceptionTracking {
            let workspace = store.activeWorkspace
            ZStack {
                // Match the bottom status bar's background (sidebar/footer
                // tone). `WindowDragRegion` lets empty parts of the bar drag
                // the window (single click) and zoom/minimise it (double
                // click) — scoped to the bar so it doesn't make the sidebar a
                // drag handle the way `isMovableByWindowBackground` did. The
                // interactive controls are a native titlebar accessory (see the
                // type doc), not content here, so the drag region can span the
                // full width.
                theme.footerBackground
                WindowDragRegion()
                identityCluster(workspace)
            }
            .frame(maxWidth: .infinity)
            // 32pt centres the title bar on the macOS traffic lights' fixed
            // vertical position (~16pt from the window top), so they sit
            // vertically centred in the bar.
            .frame(height: 32)
            .overlay(alignment: .bottom) {
                theme.divider.frame(height: 1)
            }
            // Installs the trailing controls as a native titlebar accessory on
            // the *actual* hosting window (resolved via the view's `.window`),
            // which `NSApp.windows.first` at app-setup time can't reliably do.
            .background(TitlebarControlsInstaller(store: store))
            // The accessory's ••• menu posts this; relay it to the scene's
            // Settings action (which the accessory itself can't reach).
            .onReceive(NotificationCenter.default.publisher(for: .nexOpenSettings)) { _ in
                openSettings()
            }
        }
    }

    private func identityCluster(_ workspace: WorkspaceFeature.State?) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor(workspace))
                .frame(width: 7, height: 7)

            Text(workspace?.name ?? "Nex")
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)

            if let workspace {
                separator
                Text("\(workspace.panes.count) pane\(workspace.panes.count == 1 ? "" : "s")")
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
        // Asymmetric insets: clear the traffic lights on the left (80) and
        // reserve room for the trailing controls on the right (86) so a long
        // name truncates instead of overlapping the menu / sidebar buttons on a
        // narrow window.
        .padding(.leading, 80)
        .padding(.trailing, 86)
        // The identity is purely decorative; let clicks fall through to the
        // `WindowDragRegion` behind it so dragging and double-click zoom work
        // when the pointer is over the workspace name, matching native title
        // bars (issue #199).
        .allowsHitTesting(false)
    }

    private var separator: some View {
        Text("·").foregroundStyle(theme.textTertiary)
    }

    private func dotColor(_ workspace: WorkspaceFeature.State?) -> Color {
        guard let workspace else { return theme.textTertiary }
        if workspace.panes.contains(where: { $0.status == .waitingForInput }) {
            return theme.statusWaiting
        }
        if workspace.panes.contains(where: { $0.status == .running }) {
            return theme.statusRunning
        }
        return workspace.color.color
    }
}

/// The window action bound to a title-bar double-click, mirroring the macOS
/// "Double-click a window's title bar to" setting (System Settings → Desktop &
/// Dock). A pure value type so the preference→action mapping is unit-testable
/// without a live window.
enum TitlebarDoubleClickAction {
    case zoom
    case minimize
    case doNothing

    /// Resolve from the `AppleActionOnDoubleClick` value in `NSGlobalDomain`.
    /// Unset or unrecognised falls back to `.zoom` (the macOS factory default).
    static func resolve(from raw: String?) -> TitlebarDoubleClickAction {
        switch raw {
        case "Minimize": .minimize
        case "None": .doNothing
        default: .zoom // "Maximize" or unset/unknown
        }
    }
}

/// A transparent, hit-testable backing view that lets the window be dragged
/// from the non-interactive parts of the custom title bar. Scoped to the
/// title bar (not the whole window) so it doesn't hijack sidebar drag-to-
/// reorder the way `NSWindow.isMovableByWindowBackground` did. Interactive
/// SwiftUI controls layered in front (the buttons) keep their own handling.
private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        DragView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class DragView: NSView {
        /// Drag the window from empty title-bar regions. `performDrag` is only
        /// initiated on a single click; a double-click is left untouched so the
        /// `TitlebarDoubleClickMonitor` (and macOS) can act on it. Note that
        /// under `.hiddenTitleBar` the native transparent titlebar usually wins
        /// the top strip's events and moves the window itself, so this is a
        /// belt-and-braces drag path rather than the sole one.
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 1 {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Restores macOS double-click-to-zoom on the hidden titlebar (issue #199).
///
/// Under `.windowStyle(.hiddenTitleBar)` the window is draggable from the
/// title-bar strip (the transparent native titlebar / movable-background owns
/// those events), but the *double-click* titlebar convention is lost: a
/// content view placed there never receives the click, and a
/// movable-background region drags without zooming. Rather than fight the
/// event routing, a local `NSEvent` monitor observes `leftMouseDown` before
/// the window dispatches it, and on a double-click in the empty title-bar
/// region performs the action from the user's `AppleActionOnDoubleClick`
/// preference (Zoom / Minimise / Do Nothing), matching a native title bar.
@MainActor
final class TitlebarDoubleClickMonitor {
    private var monitor: Any?

    /// Height of the custom title bar (`WindowTitleBar`), in points.
    private static let titleBarHeight: CGFloat = 32
    /// Leading inset that clears the traffic lights.
    private static let leadingInset: CGFloat = 80
    /// Trailing inset that clears the ••• menu / sidebar-toggle accessory.
    private static let trailingInset: CGFloat = 86

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            Self.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func handle(_ event: NSEvent) {
        guard event.clickCount == 2, let window = event.window else { return }
        // Only the main window uses `.hiddenTitleBar` (transparent titlebar +
        // full-size content view); Settings / Help keep a native titlebar that
        // already zooms, so leave those alone.
        guard window.titlebarAppearsTransparent,
              window.styleMask.contains(.fullSizeContentView)
        else { return }

        let loc = event.locationInWindow
        let height = window.contentView?.bounds.height ?? window.frame.height
        let width = window.frame.width
        // Top `titleBarHeight` strip, excluding the traffic-light and trailing
        // control gutters so double-clicking a control never zooms.
        guard loc.y >= height - titleBarHeight,
              loc.x >= leadingInset,
              loc.x <= width - trailingInset
        else { return }

        let raw = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch TitlebarDoubleClickAction.resolve(from: raw) {
        case .zoom: window.performZoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .doNothing: break
        }
    }
}

/// The right-hand chrome controls (••• menu + sidebar toggle). Installed as a
/// native *trailing titlebar accessory* (see `installTitlebarTrailingControls`)
/// rather than drawn inside `WindowTitleBar`: content drawn under the
/// transparent native titlebar is click-shadowed (the titlebar owns mouse
/// events in the top strip), so these would be dead. A titlebar accessory is
/// the supported way to put clickable controls up there. Resolves the chrome
/// theme inline because the accessory lives outside the window's SwiftUI
/// environment.
struct TitlebarTrailingControls: View {
    let store: StoreOf<AppReducer>
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        WithPerceptionTracking {
            let theme = ChromeTheme.resolve(
                appearance: store.settings.chromeAppearance,
                system: systemScheme,
                overrides: store.settings.chromeColorOverrides
            )
            HStack(spacing: 14) {
                Menu {
                    Button("Settings…") { openSettings() }
                    Button(store.isInspectorVisible ? "Hide Inspector" : "Show Inspector") {
                        store.send(.toggleInspector)
                    }
                    Divider()
                    Button("Restart Socket Server") { store.send(.restartSocketServer) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                // borderlessButton tints its label with the accent; force it to
                // the neutral text colour so ••• matches the sidebar toggle.
                .tint(theme.textSecondary)
                .foregroundStyle(theme.textSecondary)

                Button { store.send(.toggleSidebar) } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
                .help("Toggle sidebar")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
        }
    }

    /// Settings is its own SwiftUI scene; the accessory is outside that scene's
    /// environment, so `@Environment(\.openSettings)` is unavailable and the
    /// `showSettingsWindow:` responder action doesn't reach it from here. Relay
    /// to an in-scene listener (`WindowTitleBar`) that owns `openSettings`.
    private func openSettings() {
        NotificationCenter.default.post(name: .nexOpenSettings, object: nil)
    }
}

extension Notification.Name {
    /// Posted by the titlebar-accessory ••• menu (outside the SwiftUI scene) to
    /// ask an in-scene view to invoke the scene's `openSettings` action.
    static let nexOpenSettings = Notification.Name("nex.openSettings")
}

/// Resolves the real hosting `NSWindow` (via `view.window`, which
/// `NSApp.windows.first` at app-setup time can't be trusted to return) and
/// installs the trailing titlebar accessory once it's available. Lives as a
/// zero-size background in `WindowTitleBar`.
private struct TitlebarControlsInstaller: NSViewRepresentable {
    let store: StoreOf<AppReducer>

    func makeNSView(context _: Context) -> NSView {
        let probe = NSView(frame: .zero)
        install(from: probe)
        return probe
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        install(from: nsView)
    }

    private func install(from probe: NSView) {
        // The window isn't attached during make/update; defer to the next
        // runloop tick when `probe.window` is set.
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            installTitlebarTrailingControls(in: window, store: store)
        }
    }
}

/// Install `TitlebarTrailingControls` as a trailing titlebar accessory on the
/// window. Idempotent: the installer's make/update both call in, so we must not
/// stack duplicate accessories.
@MainActor
func installTitlebarTrailingControls(in window: NSWindow, store: StoreOf<AppReducer>) {
    let id = NSUserInterfaceItemIdentifier("nex.titlebar.trailing")
    if window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == id }) {
        return
    }
    let hosting = NSHostingView(rootView: TitlebarTrailingControls(store: store))
    hosting.identifier = id
    // Give the accessory an explicit size so it isn't laid out at zero width.
    hosting.frame = NSRect(x: 0, y: 0, width: hosting.fittingSize.width, height: 28)
    let controller = NSTitlebarAccessoryViewController()
    controller.layoutAttribute = .trailing
    controller.view = hosting
    window.addTitlebarAccessoryViewController(controller)
}
