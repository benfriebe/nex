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

    /// Send a Return key press+release to the terminal. Used by
    /// `SurfaceManager.sendCommand` (the `pane send` path); kept
    /// byte-identical to its pre-#98 form so `pane send`'s behaviour
    /// does not change. The new `pane send-key` path uses
    /// `sendNamedKey("enter")`, which delivers raw bytes via
    /// `ghostty_surface_text` — see that method's docs for why the
    /// two paths differ.
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

    /// Send a single named key press+release. Returns true if the
    /// name resolves to a known key. Used by `nex pane send-key` to
    /// deliver an explicit keystroke (Enter, Tab, Escape, ...) outside
    /// any bracketed-paste envelope — see issue #98.
    ///
    /// All deliveries use the libghostty key-event path with
    /// `mods=NONE`. The `text` field carries the byte the PTY should
    /// see for byte-mapped keys (Enter `\r`, Tab `\t`, Escape `\x1B`,
    /// Space ` `, Backspace `\x7F`, Ctrl-C `\x03`); arrow keys leave
    /// `text=nil` so libghostty emits the terminal-mode-correct escape
    /// sequence (DECCKM `\eOA` vs `\e[A` etc).
    ///
    /// Why mods=NONE for Ctrl-C: setting `mods=CTRL` triggers
    /// libghostty's CSI u / Kitty keyboard encoding (`\x1b[3;5u`),
    /// which doesn't deliver SIGINT to the foreground process. We
    /// want the raw `\x03` byte to reach the PTY's line discipline.
    /// Why not `ghostty_surface_text` directly: that path runs through
    /// `completeClipboardPaste` in libghostty, which applies unsafe-
    /// paste detection (control bytes are rejected by default) and
    /// bracketed-paste wrapping when enabled.
    @discardableResult
    func sendNamedKey(_ name: String) -> Bool {
        guard let spec = Self.namedKey(for: name) else { return false }
        sendKeyEvent(keycode: spec.keycode, codepoint: spec.codepoint, text: spec.text)
        return true
    }

    /// Synthesize and dispatch a press+release pair via the key-event
    /// protocol with `mods=NONE`. `text` is the byte sequence the PTY
    /// should see for the key, or nil to let libghostty translate based
    /// on terminal mode.
    private func sendKeyEvent(keycode: UInt32, codepoint: UInt32, text: String?) {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = keycode
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.unshifted_codepoint = codepoint

        if let text {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }

        var release = key
        release.action = GHOSTTY_ACTION_RELEASE
        release.text = nil
        _ = ghostty_surface_key(surface, release)
    }

    /// Description of a named keystroke. `text` is the byte sequence
    /// the PTY should see, or nil for keys whose escape sequence
    /// libghostty must translate from `keycode` (arrow keys etc).
    private struct NamedKeySpec {
        let keycode: UInt32
        let codepoint: UInt32
        let text: String?
    }

    /// Names accepted by `sendNamedKey`. Lowercased on lookup so the
    /// CLI can pass `Enter` / `ENTER` / `enter` interchangeably. The
    /// list is intentionally narrow — it's the set of keys an
    /// orchestrator pane realistically needs to drive a TUI.
    static let namedKeyAliases: [String] = [
        "enter", "return",
        "tab",
        "escape", "esc",
        "space",
        "backspace",
        "up", "down", "left", "right",
        "ctrl-c"
    ]

    private static func namedKey(for rawName: String) -> NamedKeySpec? {
        switch rawName.lowercased() {
        case "enter", "return":
            NamedKeySpec(keycode: 0x24, codepoint: 0x0D, text: "\r")
        case "tab":
            NamedKeySpec(keycode: 0x30, codepoint: 0x09, text: "\t")
        case "escape", "esc":
            NamedKeySpec(keycode: 0x35, codepoint: 0x1B, text: "\u{1B}")
        case "space":
            NamedKeySpec(keycode: 0x31, codepoint: 0x20, text: " ")
        case "backspace":
            // PTY byte for the macOS Delete (backspace) key is DEL (0x7F).
            NamedKeySpec(keycode: 0x33, codepoint: 0x7F, text: "\u{7F}")
        case "ctrl-c":
            // C keycode 0x08 with mods=NONE and text="\x03" lands the
            // raw ETX byte at the PTY, so the kernel's line discipline
            // delivers SIGINT to the foreground process. mods=CTRL
            // would re-route through CSI u encoding (see sendNamedKey).
            NamedKeySpec(keycode: 0x08, codepoint: 0x03, text: "\u{03}")
        case "up":
            NamedKeySpec(keycode: 0x7E, codepoint: 0xF700, text: nil)
        case "down":
            NamedKeySpec(keycode: 0x7D, codepoint: 0xF701, text: nil)
        case "left":
            NamedKeySpec(keycode: 0x7B, codepoint: 0xF702, text: nil)
        case "right":
            NamedKeySpec(keycode: 0x7C, codepoint: 0xF703, text: nil)
        default:
            nil
        }
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

    /// Execute a ghostty binding action by name (e.g. "search:foo", "end_search").
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func destroy() {
        ghostty_surface_free(surface)
    }

    /// Read the terminal contents as plain text. When `includeScrollback` is false,
    /// returns just the visible viewport; when true, returns the full screen including scrollback.
    /// Returns nil if libghostty cannot read the region (e.g. surface torn down mid-read).
    func readText(includeScrollback: Bool) -> String? {
        let tag: ghostty_point_tag_e = includeScrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(cString: ptr)
    }

    /// Read a single visual row from the viewport as plain text, with trailing
    /// blanks omitted (matching how libghostty's read returns selections).
    /// Reading one row at a time avoids the soft-wrap unwrapping a multi-row
    /// read would apply, so each returned string is exactly one visual row.
    /// Used by the wrapped-path Cmd+click reconstruction (issue #107).
    /// Returns nil if the read fails, "" for a blank row.
    func readViewportRow(_ row: Int, columns: Int) -> String? {
        guard row >= 0, columns > 0 else { return nil }
        let y = UInt32(row)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: y),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(columns - 1),
                y: y
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(cString: ptr)
    }

    /// The on-screen origin (top-left, in points) of viewport cell (0,0).
    /// libghostty returns this as `cell_coord * cell_size + padding`, unscaled,
    /// so for cell (0,0) it is exactly the surface's left/top padding at the
    /// current size and padding config. Used to map a click to a cell without
    /// assuming how libghostty distributes leftover space (issue #107: a
    /// centered estimate is correct only at the initial size and drifts on
    /// resize). Returns nil if libghostty can't report it.
    func cellOrigin() -> (x: Double, y: Double)? {
        let zero = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: zero, bottom_right: zero, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return (text.tl_px_x, text.tl_px_y)
    }
}
