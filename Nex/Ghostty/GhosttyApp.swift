import AppKit
import Foundation

/// Singleton wrapper around ghostty_app_t.
/// Manages the libghostty event loop and dispatches callbacks.
@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    // nonisolated(unsafe) so deinit and config client can access without actor hop
    private(set) nonisolated(unsafe) var app: ghostty_app_t?
    nonisolated(unsafe) var config: GhosttyConfig?

    /// Notification posted when a surface title changes.
    /// userInfo: ["surface": ghostty_surface_t, "title": String]
    static let surfaceTitleNotification = Notification.Name("GhosttyApp.surfaceTitle")
    /// Notification posted when a surface's pwd changes.
    /// userInfo: ["surface": ghostty_surface_t, "pwd": String]
    static let surfacePwdNotification = Notification.Name("GhosttyApp.surfacePwd")
    /// Notification posted when a surface should close.
    /// userInfo: ["surface": ghostty_surface_t]
    static let surfaceCloseNotification = Notification.Name("GhosttyApp.surfaceClose")
    /// Notification posted when a surface sends an OSC desktop notification.
    /// userInfo: ["surface": ghostty_surface_t, "title": String, "body": String]
    static let desktopNotification = Notification.Name("GhosttyApp.desktopNotification")
    /// Notification posted when the user CMD-clicks a .md file path in the terminal.
    /// userInfo: ["path": String, "surface": ghostty_surface_t?]
    static let openFileNotification = Notification.Name("GhosttyApp.openFile")
    /// Notification posted when ghostty requests opening the search overlay.
    /// userInfo: ["surface": ghostty_surface_t, "needle": String]
    static let searchStartNotification = Notification.Name("GhosttyApp.searchStart")
    /// Notification posted when ghostty requests closing the search overlay.
    /// userInfo: ["surface": ghostty_surface_t]
    static let searchEndNotification = Notification.Name("GhosttyApp.searchEnd")
    /// Notification posted when ghostty reports the total number of search matches.
    /// userInfo: ["surface": ghostty_surface_t, "total": Int]
    static let searchTotalNotification = Notification.Name("GhosttyApp.searchTotal")
    /// Notification posted when ghostty reports the currently selected search match.
    /// userInfo: ["surface": ghostty_surface_t, "selected": Int]
    static let searchSelectedNotification = Notification.Name("GhosttyApp.searchSelected")

    private init() {}

    func start() {
        // ghostty_init() MUST be called before any other libghostty function.
        // It initializes the global allocator, shader compiler, and regex engine.
        let initResult = ghostty_init(
            UInt(CommandLine.argc),
            CommandLine.unsafeArgv
        )
        guard initResult == 0 else {
            fatalError("ghostty_init failed with code \(initResult)")
        }

        let config = GhosttyConfig()
        config.finalize()
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false

        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
                app.tick()
            }
        }

        runtime.action_cb = { ghosttyApp, target, action in
            guard let ghosttyApp else { return false }
            let userdata = ghostty_app_userdata(ghosttyApp)
            guard let userdata else { return false }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            return app.handleAction(target: target, action: action)
        }

        runtime.read_clipboard_cb = { userdata, _, request in
            guard let userdata, let request else { return false }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.ghosttySurface?.surface else { return false }

            // 1. Try string first (existing behavior — covers text copies and file URLs)
            if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, request, true)
                }
                return true
            }

            // 2. Try image data — save to temp PNG and paste the shell-escaped path
            if let path = ClipboardImageHelper.saveClipboardImageToTempFile() {
                let escaped = SurfaceView.shellEscape(path)
                escaped.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, request, true)
                }
                return true
            }

            // 3. Nothing usable — return false so performable paste bindings can
            // pass through to the terminal instead of being consumed.
            return false
        }

        runtime.confirm_read_clipboard_cb = { userdata, data, request, _ in
            guard let userdata, let request else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.ghosttySurface?.surface else { return }
            // Auto-confirm — data pointer is only valid for this callback's duration
            ghostty_surface_complete_clipboard_request(surface, data, request, true)
        }

        runtime.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0 else { return }
            // content pointer is only valid for this callback's duration — read synchronously
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let text = content.pointee.data {
                let str = String(cString: text)
                pasteboard.setString(str, forType: .string)
            }
        }

        runtime.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            let paneID = surfaceView.paneID
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: GhosttyApp.surfaceCloseNotification,
                    object: nil,
                    userInfo: ["paneID": paneID]
                )
            }
        }

        app = ghostty_app_new(&runtime, config.rawConfig)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Serial queue for off-main surface teardown (issue #136).
    ///
    /// `ghostty_surface_free` calls `Surface.deinit`, which joins the
    /// surface's IO thread (`ghostty/src/Surface.zig` `io_thr.join()`).
    /// When the child process traps or ignores SIGHUP, libghostty's
    /// `killPid` spins forever on `killpg(SIGHUP)` + `waitpid(WNOHANG)`
    /// (`ghostty/src/termio/Exec.zig`) with no SIGKILL escalation, so the
    /// join — and the main thread that called free synchronously — hangs
    /// for tens of seconds. Running free here keeps the UI responsive;
    /// worst case the surface struct lingers until the child finally dies.
    ///
    /// Only the *free* is offloaded. Surface creation (`ghostty_surface_new`)
    /// makes the SurfaceView's NSView layer-hosting by assigning libghostty's
    /// Metal layer to the view's `layer` property (`renderer/Metal.zig`
    /// `surfaceInit` → `setProperty("layer", …)`; the `addSublayer:` branch is
    /// iOS-only), a main-thread-only AppKit mutation, so creation cannot move
    /// off-main. `ghostty_app_tick` iterates `App.surfaces` (via `hasSurface`
    /// while draining the mailbox) and so must stay serialized with creation —
    /// keeping it on main lets the run loop do that for free. The teardown
    /// reads only cached surface state (`getContentScale`/`getSize`), and the
    /// post-join `layer.release()` only drops libghostty's own retain — on
    /// macOS the view *is* the layer host, so its `.layer` keeps the layer
    /// alive until the NSView deallocs on main. Off-main free is therefore
    /// safe as long as the view outlives the call (see `freeSurfaceAsync`).
    ///
    /// Residual race (accepted, not fully fixable in Swift): `ghostty_surface_free`
    /// is a single C call, so free's own `App.deleteSurface` (a `swapRemove`
    /// on the lock-free `App.surfaces` list) now runs on this queue and can
    /// interleave with *any* main-thread libghostty call that touches that
    /// list — not only `ghostty_surface_new` (append, may realloc) and `tick`'s
    /// `hasSurface`, but also app-scoped / all-surfaces binding actions and
    /// config reloads (`App.zig` `performAction` iterating `surfaces.items`).
    /// Ordinary per-key input does *not* iterate the list, so in practice the
    /// colliding window is small — `deleteSurface` runs at the very start of
    /// free, before the long `io_thr.join()` — but the access is genuinely
    /// unsynchronized, i.e. a rare latent crash. It is still vastly preferable
    /// to the deterministic multi-second freeze it replaces. Closing this
    /// fully needs a libghostty change (a split teardown API, an internal lock
    /// on `App.surfaces`, or PID-export + SIGKILL-before-free — issue #136 plan
    /// steps 3/4), none of which is possible against the prebuilt static lib.
    ///
    /// Head-of-line caveat: frees serialize on this queue, so a free whose
    /// child never dies (SIGHUP-trapped) blocks every later free behind it —
    /// those panes leave Nex's UI but their PTY children linger until the first
    /// child finally exits. Bounding this needs the same SIGKILL escalation. A
    /// concurrent queue would unblock them but let two `deleteSurface`s race
    /// each other, so serial is the safer of the two imperfect choices here.
    nonisolated let surfaceTeardownQueue = DispatchQueue(
        label: "com.nex.ghostty.surface-teardown",
        qos: .userInitiated
    )

    /// Free a libghostty surface off the main thread. `view` is retained
    /// for the duration of the (potentially multi-second) free so its
    /// NSView — whose CALayer libghostty renders into and releases during
    /// teardown — stays alive throughout; the view's deallocation is then
    /// forced back onto the main thread, where NSView dealloc belongs.
    nonisolated func freeSurfaceAsync(_ rawSurface: ghostty_surface_t, retaining view: SurfaceView) {
        let retainer = SurfaceViewRetainer(view)
        surfaceTeardownQueue.async {
            ghostty_surface_free(rawSurface)
            // Release the retained view (and trigger NSView dealloc) on main.
            DispatchQueue.main.async { _ = retainer }
        }
    }

    private nonisolated func handleAction(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title.flatMap { String(cString: $0) } ?? ""
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.surfaceTitleNotification,
                    object: nil,
                    userInfo: [
                        "surface": surface as Any,
                        "title": title
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.surfacePwdNotification,
                    object: nil,
                    userInfo: [
                        "surface": surface as Any,
                        "pwd": pwd
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let title = action.action.desktop_notification.title.flatMap { String(cString: $0) } ?? ""
            let body = action.action.desktop_notification.body.flatMap { String(cString: $0) } ?? ""
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.desktopNotification,
                    object: nil,
                    userInfo: [
                        "surface": surface as Any,
                        "title": title,
                        "body": body
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let openUrl = action.action.open_url
            guard let urlPtr = openUrl.url else { return false }
            // Ghostty's URL regex includes trailing spaces that run to end-of-line
            // (see ghostty/src/config/url.zig `trailing_spaces_at_eol`), so a path
            // matched at the end of a terminal line arrives padded with spaces.
            // Trim before the .md suffix check or we'd silently fall through to
            // ghostty's default opener and `open(1)` would fail.
            var urlString = String(cString: urlPtr).trimmingCharacters(in: .whitespacesAndNewlines)
            while urlString.hasSuffix(".") {
                urlString.removeLast()
            }
            let path = NSString(string: urlString).standardizingPath
            guard path.hasSuffix(".md") else { return false }
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.openFileNotification,
                    object: nil,
                    userInfo: [
                        "path": path,
                        "surface": surface as Any
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) } ?? ""
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            guard let surface else { return false }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.searchStartNotification,
                    object: nil,
                    userInfo: [
                        "surface": surface as Any,
                        "needle": needle
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            guard let surface else { return false }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.searchEndNotification,
                    object: nil,
                    userInfo: ["surface": surface as Any]
                )
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = Int(action.action.search_total.total)
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            guard let surface else { return false }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.searchTotalNotification,
                    object: nil,
                    userInfo: [
                        "surface": surface as Any,
                        "total": total
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = Int(action.action.search_selected.selected)
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            guard let surface else { return false }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.searchSelectedNotification,
                    object: nil,
                    userInfo: [
                        "surface": surface as Any,
                        "selected": selected
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Fires when a surface's child process exits. Returning `true`
            // tells ghostty we've handled the notification, which suppresses
            // its default "Process exited. Press any key to close the
            // terminal." message. We also need to initiate the close
            // ourselves because ghostty silently force-sets
            // `wait-after-command = true` whenever a surface is created with
            // a command set (see ghostty/src/apprt/embedded.zig:529-535), so
            // `close_surface_cb` will not otherwise fire for command-backed
            // surfaces like our external-editor panes.
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            guard let surface else { return false }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.surfaceCloseNotification,
                    object: nil,
                    userInfo: ["surface": surface as Any]
                )
            }
            return true

        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            return false

        case GHOSTTY_ACTION_RENDER:
            // libghostty processed new PTY output and wants the host to
            // present a frame. Nex's draw is host-pumped (updateLayer ->
            // ghostty_surface_draw), so we must re-arm needsDisplay or the
            // pane never repaints (issue #194): a surface created while its
            // window was zero-bounds / occluded gets its one and only draw
            // from AppKit layout callbacks, so without this incoming output
            // is silently dropped and the body stays blank until focus or
            // resize. Capture the raw surface pointer as an opaque token and
            // resolve it to a live SurfaceView on main by pointer identity
            // (like every other action handler, via SurfaceManager) — never
            // dereference the incoming pointer in this possibly-off-main
            // callback, so a RENDER draining for a surface being freed off
            // the main thread (issue #136 teardown) finds no match and is
            // safely dropped instead of touching freed memory. AppKit
            // coalesces repeated needsDisplay into one draw per display cycle.
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            guard let surface else { return false }
            DispatchQueue.main.async {
                SurfaceManager.liveValue.surfaceView(forRawSurface: surface)?.needsDisplay = true
            }
            return true

        default:
            return false
        }
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
    }
}

/// Holds a `SurfaceView` alive across the off-main teardown hop in
/// `GhosttyApp.freeSurfaceAsync` without tripping Swift 6 Sendable
/// checks. The view is only retained (never accessed) off the main
/// thread — ARC retain/release is atomic, and the final release is
/// forced back onto main — so `@unchecked Sendable` is sound here.
private final class SurfaceViewRetainer: @unchecked Sendable {
    let view: SurfaceView
    init(_ view: SurfaceView) {
        self.view = view
    }
}
