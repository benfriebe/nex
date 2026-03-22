import AppKit
import QuartzCore

/// NSView subclass that hosts a ghostty terminal surface.
/// Manages Metal rendering via CALayer, routes keyboard/mouse events
/// to the ghostty C API.
final class SurfaceView: NSView, @preconcurrency NSTextInputClient {
    nonisolated(unsafe) var ghosttySurface: GhosttySurface?
    private var markedText: NSMutableAttributedString = .init()
    let paneID: UUID

    // Keyboard interpretation state — populated by NSTextInputClient during interpretKeyEvents
    private var interpretedText: String?
    private var isComposing: Bool = false
    private var isInKeyDown: Bool = false

    /// Resize debounce — coalesces rapid setFrameSize calls (from splits, maximize,
    /// drag resize) into a single set_size so the shell only gets one SIGWINCH.
    private var resizeWorkItem: DispatchWorkItem?

    init(paneID: UUID, workingDirectory: String, backgroundOpacity: Double = 1.0) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = backgroundOpacity >= 1.0
        layerContentsRedrawPolicy = .duringViewResize

        guard let app = GhosttyApp.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0 // 0 = use config default
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        // Inject NEXUS_PANE_ID so hook scripts know which pane fired
        let paneIDString = paneID.uuidString
        paneIDString.withCString { paneIDCStr in
            var envVar = ghostty_env_var_s()
            let keyStr = strdup("NEXUS_PANE_ID")!
            let valStr = strdup(paneIDCStr)!
            envVar.key = UnsafePointer(keyStr)
            envVar.value = UnsafePointer(valStr)

            withUnsafeMutablePointer(to: &envVar) { envPtr in
                config.env_vars = envPtr
                config.env_var_count = 1

                workingDirectory.withCString { cwd in
                    config.working_directory = cwd
                    let rawSurface = ghostty_surface_new(app, &config)
                    if let rawSurface {
                        ghosttySurface = GhosttySurface(surface: rawSurface)
                        // Start unfocused — focus is granted explicitly via makeFirstResponder
                        ghosttySurface?.setFocus(false)
                    }
                }
            }

            free(keyStr)
            free(valStr)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        ghosttySurface?.destroy()
    }

    // MARK: - Layer

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        ghosttySurface?.draw()
    }

    override func layout() {
        super.layout()
        syncSublayerFrames()
    }

    /// Resize ghostty's Metal sublayer to match the view bounds.
    /// Disables Core Animation implicit animations so the frame snaps
    /// immediately — without this, maximize/minimize animations cause
    /// the Metal drawable to read interpolated (wrong) bounds.
    private func syncSublayerFrames() {
        guard let sublayers = layer?.sublayers else { return }
        // Skip when bounds is zero — setting the Metal layer to zero size
        // corrupts ghostty's rendering state (happens during view re-parenting)
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers {
            sublayer.frame = bounds
        }
        CATransaction.commit()
    }

    // MARK: - NSView overrides

    static let paneFocusedNotification = Notification.Name("SurfaceView.paneFocused")

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        ghosttySurface?.setFocus(true)
        NotificationCenter.default.post(
            name: Self.paneFocusedNotification,
            object: nil,
            userInfo: ["paneID": paneID]
        )
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        ghosttySurface?.setFocus(false)
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateContentScale()
            // When re-attached to a window (e.g., after pane close collapses
            // a split or workspace switch), defer refresh until after layout
            // so the view has its correct bounds.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window else { return }
                ghosttySurface?.refresh()
                needsDisplay = true
                let scale = window.backingScaleFactor
                let w = UInt32(bounds.width * scale)
                let h = UInt32(bounds.height * scale)
                if w > 0, h > 0 {
                    ghosttySurface?.setSize(width: w, height: h)
                }
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
    }

    private func updateContentScale() {
        guard let scale = window?.backingScaleFactor else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        if let sublayers = layer?.sublayers {
            for sublayer in sublayers {
                sublayer.contentsScale = scale
            }
        }
        CATransaction.commit()
        ghosttySurface?.setContentScale(x: scale, y: scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSublayerFrames()

        // Debounce set_size: during splits, maximize, or drag resize, setFrameSize
        // fires multiple times as the layout settles. Each call would trigger a
        // SIGWINCH causing the shell to redraw its prompt. By debouncing, we coalesce
        // all intermediate sizes and only send the final one.
        resizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window else { return }
            let scale = window.backingScaleFactor
            let w = UInt32(frame.width * scale)
            let h = UInt32(frame.height * scale)
            if w > 0, h > 0 {
                ghosttySurface?.setSize(width: w, height: h)
            }
        }
        resizeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Keyboard input

    override func doCommand(by _: Selector) {
        // Ghostty handles all key bindings internally. Without this override,
        // NSView's default calls NSBeep() for unhandled selectors (Enter,
        // Backspace, arrows, etc.).
    }

    override func keyDown(with event: NSEvent) {
        // Step 1: Interpret the key event to get the text it produces.
        // This calls our NSTextInputClient methods (insertText/setMarkedText)
        // which store the result in interpretedText/isComposing.
        interpretedText = nil
        isComposing = false
        isInKeyDown = true
        interpretKeyEvents([event])
        isInKeyDown = false

        // Step 2: Build a key event with the interpreted text attached.
        var key = Self.keyEvent(from: event, action: GHOSTTY_ACTION_PRESS)
        key.composing = isComposing

        // Step 3: Send the key event to ghostty with the text.
        if let text = interpretedText {
            text.withCString { ptr in
                key.text = ptr
                _ = ghosttySurface?.sendKey(key)
            }
        } else {
            _ = ghosttySurface?.sendKey(key)
        }
    }

    override func keyUp(with event: NSEvent) {
        let key = Self.keyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        _ = ghosttySurface?.sendKey(key)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = Self.mods(from: event)
        let action = (mods.rawValue & mod != 0) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mods
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.text = nil
        key.composing = false
        key.unshifted_codepoint = 0
        _ = ghosttySurface?.sendKey(key)
    }

    // MARK: - Mouse input

    /// Convert NSView coordinates (bottom-left origin) to ghostty coordinates (top-left origin).
    private func mousePoint(from event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: point.x, y: frame.height - point.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = mousePoint(from: event)
        ghosttySurface?.sendMousePos(x: point.x, y: point.y, mods: Self.mods(from: event))
        _ = ghosttySurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: Self.mods(from: event)
        )
    }

    override func mouseUp(with event: NSEvent) {
        let point = mousePoint(from: event)
        ghosttySurface?.sendMousePos(x: point.x, y: point.y, mods: Self.mods(from: event))
        _ = ghosttySurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            mods: Self.mods(from: event)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        let point = mousePoint(from: event)
        ghosttySurface?.sendMousePos(
            x: point.x, y: point.y,
            mods: Self.mods(from: event)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let point = mousePoint(from: event)
        ghosttySurface?.sendMousePos(
            x: point.x, y: point.y,
            mods: Self.mods(from: event)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = mousePoint(from: event)
        ghosttySurface?.sendMousePos(x: point.x, y: point.y, mods: Self.mods(from: event))
        _ = ghosttySurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT,
            mods: Self.mods(from: event)
        )
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = mousePoint(from: event)
        ghosttySurface?.sendMousePos(x: point.x, y: point.y, mods: Self.mods(from: event))
        _ = ghosttySurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_RIGHT,
            mods: Self.mods(from: event)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        var scrollMods: ghostty_input_scroll_mods_t = 0
        // scroll_mods is a bitfield — bit 0 = precise (trackpad) scrolling
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 1
        }
        ghosttySurface?.sendScroll(
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            mods: scrollMods
        )
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange _: NSRange) {
        guard let str = string as? String else { return }
        if isInKeyDown {
            // During keyDown: store text for the key event, don't send separately
            interpretedText = str
            isComposing = false
            // Clear any marked text since input was committed
            markedText = NSMutableAttributedString()
        } else {
            // Outside keyDown (e.g., paste via services menu): send directly
            ghosttySurface?.sendText(str)
        }
    }

    func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        let str: String
        if let attrStr = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attrStr)
            str = attrStr.string
        } else if let s = string as? String {
            markedText = NSMutableAttributedString(string: s)
            str = s
        } else {
            return
        }

        if isInKeyDown {
            interpretedText = str
            isComposing = true
        } else {
            ghosttySurface?.sendPreedit(str)
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        isComposing = false
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let surface = ghosttySurface else {
            return window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        }
        let (x, y, w, h) = surface.imePoint()
        let viewPoint = NSPoint(x: x, y: frame.height - y)
        let screenPoint = window?.convertPoint(toScreen: convert(viewPoint, to: nil)) ?? viewPoint
        return NSRect(x: screenPoint.x, y: screenPoint.y - h, width: w, height: h)
    }

    func characterIndex(for _: NSPoint) -> Int {
        0
    }

    // MARK: - Helpers

    static func mods(from event: NSEvent) -> ghostty_input_mods_e {
        mods(fromFlags: event.modifierFlags)
    }

    static func mods(fromFlags flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    static func keyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = mods(from: event)
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false

        // consumed_mods tells ghostty which modifiers were already applied by the
        // platform's text input system. Control and command never contribute to text
        // translation, so exclude them — everything else (shift, option, caps) is consumed.
        let consumedFlags = event.modifierFlags.subtracting([.control, .command])
        key.consumed_mods = mods(fromFlags: consumedFlags)

        // Unshifted codepoint: the character with no modifiers applied.
        // Use characters(byApplyingModifiers:) with empty set instead of
        // charactersIgnoringModifiers, which changes behavior with ctrl pressed.
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let scalar = chars.unicodeScalars.first {
                key.unshifted_codepoint = scalar.value
            }
        }

        return key
    }
}
