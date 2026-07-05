import AppKit
import SwiftUI

/// Persists and restores the main window's size, position, and native
/// fullscreen state across launches (issue #179). Without this the
/// `WindowGroup` has no `.defaultSize` and no frame autosave, so macOS
/// falls back to a default cascaded size on every restart -- the app
/// "forgets" a resized or fullscreen window.
///
/// Two halves, both backed by `UserDefaults` (domain `com.benfriebe.nex`):
///
///  - **Windowed frame** (size + position, including a green-button
///    "zoomed" frame, which is just a large ordinary frame): handled by
///    AppKit's `setFrameAutosaveName(_:)`. Setting the name restores the
///    saved frame immediately and auto-persists it on every move/resize.
///    AppKit does not autosave the frame while in native fullscreen, so
///    the stored frame stays the *windowed* one.
///
///  - **Fullscreen flag**: AppKit's frame autosave can't express "was
///    fullscreen", so we persist a bool ourselves from the enter/exit
///    fullscreen notifications and re-enter fullscreen on launch.
///
/// Mirrors `SpacesBindingAttacher` in `NexApp.swift`: `viewDidMoveToWindow`
/// is the only deterministic hook for "this view is now parented in a real
/// NSWindow" (`.onAppear` fires later; `makeNSView` fires before
/// `view.window` is set).
struct WindowFrameRestorer: NSViewRepresentable {
    func makeNSView(context _: Context) -> WindowFrameRestorerView {
        WindowFrameRestorerView()
    }

    func updateNSView(_: WindowFrameRestorerView, context _: Context) {
        // No-op: the view configures the window once in viewDidMoveToWindow.
    }
}

final class WindowFrameRestorerView: NSView {
    /// UserDefaults key holding whether the window was in native fullscreen.
    nonisolated static let fullscreenDefaultsKey = "nex.mainWindow.isFullScreen"
    /// Frame autosave name -> AppKit stores under "NSWindow Frame <name>".
    nonisolated static let frameAutosaveName = "NexMainWindow"

    private var didConfigure = false
    // Read from the nonisolated `deinit`; only mutated on the main actor in
    // `configure`, and `deinit` runs after the last reference is gone, so the
    // access is race-free.
    private nonisolated(unsafe) var enterObserver: NSObjectProtocol?
    private nonisolated(unsafe) var exitObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didConfigure, let window else { return }
        // Only the primary main window owns the saved frame. A duplicate main
        // window (SwiftUI spawns one for a Finder file-open on the running
        // app, which DuplicateMainWindowCloser then closes) must not share the
        // autosave name, register fullscreen observers, or toggle fullscreen
        // on a window that's about to close -- its exit-fullscreen would flip
        // the persisted flag and silently regress the restore.
        guard MainWindowRegistry.isPrimary(window) else { return }
        didConfigure = true
        configure(window)
    }

    private func configure(_ window: NSWindow) {
        // Restore (and from now on auto-persist) the windowed size + position.
        // Setting the autosave name applies the saved frame synchronously, so
        // there's no visible resize flash from the SwiftUI default size.
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // Guard against restoring onto a now-disconnected display: with
        // `.hiddenTitleBar` AppKit's own constrain is weak, so a frame saved on
        // an external monitor can come back effectively off-screen. Recenter it
        // if it no longer overlaps any screen enough to be reachable.
        let screens = NSScreen.screens.map(\.frame)
        if let fallback = (window.screen ?? NSScreen.main)?.visibleFrame {
            let safe = WindowFrameClamp.constrained(window.frame, toVisible: screens, fallback: fallback)
            if safe != window.frame {
                window.setFrame(safe, display: true)
            }
        }

        // Keep the persisted fullscreen flag in sync with the live window.
        let center = NotificationCenter.default
        enterObserver = center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { _ in
            UserDefaults.standard.set(true, forKey: Self.fullscreenDefaultsKey)
        }
        exitObserver = center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { _ in
            UserDefaults.standard.set(false, forKey: Self.fullscreenDefaultsKey)
        }

        // Re-enter fullscreen if that's how we were left. Defer one runloop
        // tick so the window is live and its windowed frame (just restored
        // above) is the frame it will return to on exit.
        guard UserDefaults.standard.bool(forKey: Self.fullscreenDefaultsKey) else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    deinit {
        if let enterObserver {
            NotificationCenter.default.removeObserver(enterObserver)
        }
        if let exitObserver {
            NotificationCenter.default.removeObserver(exitObserver)
        }
    }
}

/// Pure geometry helper for keeping a restored window frame on-screen.
/// Split out from `WindowFrameRestorerView` so it can be unit-tested without
/// a real `NSWindow` / display.
enum WindowFrameClamp {
    /// Minimum overlap (points) required on each axis for a saved frame to
    /// count as "still reachable" on a screen.
    static let minVisible: CGFloat = 80

    /// If `frame` overlaps at least one of `screens` by `minVisible` on both
    /// axes it's returned unchanged; otherwise it's recentered on `fallback`
    /// (keeping its size, shrunk to fit if larger than `fallback`).
    static func constrained(_ frame: NSRect, toVisible screens: [NSRect], fallback: NSRect) -> NSRect {
        let visibleEnough = screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width >= minVisible && overlap.height >= minVisible
        }
        if visibleEnough { return frame }

        let width = min(frame.width, fallback.width)
        let height = min(frame.height, fallback.height)
        return NSRect(
            x: fallback.midX - width / 2,
            y: fallback.midY - height / 2,
            width: width,
            height: height
        )
    }
}
