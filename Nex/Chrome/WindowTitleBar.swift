import AppKit
import ComposableArchitecture
import SwiftUI

/// Custom in-content window title bar shown under the hidden native
/// titlebar (`.windowStyle(.hiddenTitleBar)`). Centres the active
/// workspace identity (status dot · name · pane count · branch). Traffic
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
    // Owned here (an in-scene view) so the titlebar-accessory ••• menu — which
    // is outside the SwiftUI scene and can't reach `openSettings` itself — can
    // relay through `nexOpenSettings`.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        WithPerceptionTracking {
            let workspace = store.activeWorkspace
            ZStack {
                // Match the bottom status bar's background (sidebar/footer
                // tone). `WindowDragRegion` lets empty parts of the bar drag
                // the window (via `performDrag`) — scoped to the bar so it
                // doesn't make the sidebar a drag handle the way
                // `isMovableByWindowBackground` did. The interactive controls
                // are a native titlebar accessory (see the type doc), not
                // content here, so the drag region can span the full width.
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

            if let branch = activeBranch(workspace) {
                separator
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                }
                .foregroundStyle(theme.textTertiary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
        // Asymmetric insets: clear the traffic lights on the left (80) and
        // reserve room for the trailing controls on the right (86) so a long
        // name + branch truncates instead of overlapping the menu / sidebar
        // buttons on a narrow window.
        .padding(.leading, 80)
        .padding(.trailing, 86)
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

    /// Branch of the focused pane, falling back to the first pane that has
    /// one (so the title bar still shows a branch when focus is on a
    /// non-shell pane).
    private func activeBranch(_ workspace: WorkspaceFeature.State?) -> String? {
        guard let workspace else { return nil }
        if let focusedID = workspace.focusedPaneID,
           let branch = workspace.panes[id: focusedID]?.gitBranch {
            return branch
        }
        return workspace.panes.compactMap(\.gitBranch).first
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
        /// `mouseDownCanMoveWindow` is unreliable for a SwiftUI-embedded view,
        /// so initiate the drag explicitly. `performDrag` also handles the
        /// double-click-to-zoom/minimise titlebar conventions.
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
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
