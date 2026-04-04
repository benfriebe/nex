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
            guard let userdata, let request else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.ghosttySurface?.surface else { return }

            // 1. Try string first (existing behavior — covers text copies and file URLs)
            if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, request, true)
                }
                return
            }

            // 2. Try image data — save to temp PNG and paste the shell-escaped path
            if let path = ClipboardImageHelper.saveClipboardImageToTempFile() {
                let escaped = SurfaceView.shellEscape(path)
                escaped.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, request, true)
                }
                return
            }

            // 3. Nothing usable — complete with empty string (ghostty requires a response)
            "".withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, request, true)
            }
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

    /// Called from `DispatchQueue.main.async` in the wakeup callback.
    /// Marked `nonisolated` to avoid `@MainActor` runtime assertions
    /// (`_dispatch_assert_queue_fail`) when the Swift 6 runtime on
    /// macOS Tahoe checks actor isolation for GCD-dispatched blocks.
    nonisolated func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
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
            var urlString = String(cString: urlPtr)
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

        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            return false

        case GHOSTTY_ACTION_RENDER:
            return false

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
