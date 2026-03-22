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
            // read_clipboard_cb is designed for async — ghostty keeps the request alive
            let str = NSPasteboard.general.string(forType: .string) ?? ""
            str.withCString { ptr in
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

        runtime.close_surface_cb = { _, _ in
            // The close_surface callback fires when a surface's process terminates
            // We handle this via the action callback instead
        }

        app = ghostty_app_new(&runtime, config.rawConfig)
    }

    func tick() {
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
