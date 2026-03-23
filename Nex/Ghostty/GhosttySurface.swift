import Foundation

/// Lightweight handle around a ghostty_surface_t pointer.
/// The actual surface lifecycle is managed by SurfaceView.
final class GhosttySurface {
    let surface: ghostty_surface_t

    init(surface: ghostty_surface_t) {
        self.surface = surface
    }

    func setSize(width: UInt32, height: UInt32) {
        ghostty_surface_set_size(surface, width, height)
    }

    func setContentScale(x: Double, y: Double) {
        ghostty_surface_set_content_scale(surface, x, y)
    }

    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        ghostty_surface_key(surface, event)
    }

    func sendText(_ text: String) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Send a Return key press+release to the terminal.
    func sendEnterKey() {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 0x24 // macOS Return keycode
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.unshifted_codepoint = 0x0D
        "\r".withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }

        var release = key
        release.action = GHOSTTY_ACTION_RELEASE
        release.text = nil
        _ = ghostty_surface_key(surface, release)
    }

    func sendPreedit(_ text: String) {
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
    }

    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        ghostty_surface_mouse_button(surface, state, button, mods)
    }

    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    func sendScroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    func setOcclusion(_ occluded: Bool) {
        ghostty_surface_set_occlusion(surface, occluded)
    }

    func requestClose() {
        ghostty_surface_request_close(surface)
    }

    func refresh() {
        ghostty_surface_refresh(surface)
    }

    func draw() {
        ghostty_surface_draw(surface)
    }

    var size: ghostty_surface_size_s {
        ghostty_surface_size(surface)
    }

    var processExited: Bool {
        ghostty_surface_process_exited(surface)
    }

    var needsConfirmQuit: Bool {
        ghostty_surface_needs_confirm_quit(surface)
    }

    var mouseCaptured: Bool {
        ghostty_surface_mouse_captured(surface)
    }

    func imePoint() -> (x: Double, y: Double, w: Double, h: Double) {
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        return (x, y, w, h)
    }

    func destroy() {
        ghostty_surface_free(surface)
    }
}
