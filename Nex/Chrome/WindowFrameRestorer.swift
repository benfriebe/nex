import AppKit
import SwiftUI

/// Persists and restores the main window's size, position, and native
/// fullscreen state across launches (issue #179). Without this the
/// `WindowGroup` has no `.defaultSize` and no frame persistence, so macOS
/// falls back to a default cascaded size on every restart -- the app
/// "forgets" a resized, moved, or fullscreen window.
///
/// Both halves are persisted explicitly via `NotificationCenter` observers
/// into `UserDefaults` (domain `com.benfriebe.nex`):
///
///  - **Windowed frame** (size + position, including a green-button
///    "zoomed" frame, which is just a large ordinary frame): saved on every
///    `didResize` / `didMove`, restored via `setFrame` on launch. We do NOT
///    use `setFrameAutosaveName` -- inside a SwiftUI `WindowGroup` it does
///    not reliably capture user resizes, so the window always came back at
///    the default size (issue #179). Saving is skipped while in native
///    fullscreen so the stored frame stays the *windowed* one.
///
///  - **Fullscreen flag**: persisted from the enter/exit fullscreen
///    notifications; on launch we re-enter fullscreen after the windowed
///    frame is restored.
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
    /// UserDefaults key holding the windowed frame as an `NSStringFromRect`.
    nonisolated static let frameDefaultsKey = "nex.mainWindow.frame"
    /// UserDefaults key holding whether the window was in native fullscreen.
    nonisolated static let fullscreenDefaultsKey = "nex.mainWindow.isFullScreen"

    private var didConfigure = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didConfigure, let window else { return }
        // Only the primary main window owns the saved frame. A duplicate main
        // window (SwiftUI spawns one for a Finder file-open on the running
        // app, which DuplicateMainWindowCloser then closes) must not persist a
        // frame, register fullscreen observers, or toggle fullscreen on a
        // window that's about to close -- its exit-fullscreen would flip the
        // persisted flag and silently regress the restore.
        guard MainWindowRegistry.isPrimary(window) else { return }
        didConfigure = true
        configure(window)
    }

    private func configure(_ window: NSWindow) {
        // Selector-based observers (target = self) rather than block-based:
        // AppKit posts these notifications on the main thread, so the @objc
        // handlers run on the main actor, and there's no @Sendable closure
        // capturing the non-Sendable NSWindow to fight Swift 6 over.
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didResizeNotification, object: window
        )
        center.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didMoveNotification, object: window
        )
        center.addObserver(
            self, selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification, object: window
        )
        center.addObserver(
            self, selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification, object: window
        )

        // Restore the saved windowed frame (size + position). Recenter it if
        // it no longer overlaps any screen -- e.g. saved on a since-
        // disconnected external display; with `.hiddenTitleBar` AppKit's own
        // constrain is weak. Applying the frame fires didResize/didMove above,
        // which re-persists the (possibly clamped) frame -- intended.
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let rect = NSRectFromString(saved)
            if rect.width > 0, rect.height > 0 {
                let screens = NSScreen.screens.map(\.frame)
                let fallback = (window.screen ?? NSScreen.main)?.visibleFrame ?? rect
                let safe = WindowFrameClamp.constrained(rect, toVisible: screens, fallback: fallback)
                window.setFrame(safe, display: true)
            }
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

    /// Persist the windowed frame on every move/resize. Skipped while in
    /// native fullscreen so we keep remembering the *windowed* frame, not the
    /// full-screen one AppKit reports during fullscreen.
    @objc private func windowFrameChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
    }

    @objc private func windowDidEnterFullScreen(_: Notification) {
        UserDefaults.standard.set(true, forKey: Self.fullscreenDefaultsKey)
    }

    @objc private func windowDidExitFullScreen(_: Notification) {
        UserDefaults.standard.set(false, forKey: Self.fullscreenDefaultsKey)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
