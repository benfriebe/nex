import AppKit
import QuartzCore

/// NSView subclass that hosts a ghostty terminal surface.
/// Manages Metal rendering via CALayer, routes keyboard/mouse events
/// to the ghostty C API.
final class SurfaceView: NSView, @preconcurrency NSTextInputClient {
    nonisolated(unsafe) var ghosttySurface: GhosttySurface?
    private var markedText: NSMutableAttributedString = .init()
    let paneID: UUID

    /// Keyboard interpretation state, populated by NSTextInputClient during interpretKeyEvents.
    /// A non-nil accumulator means we're inside a keyDown. `insertText` may be called more than
    /// once per keyDown (e.g. US International dead-key failure: `'` + `s` fires twice), so we
    /// accumulate and emit one key event per string. Mirrors Ghostty upstream's approach.
    private var keyTextAccumulator: [String]?

    /// Resize debounce — coalesces rapid setFrameSize calls (from splits, maximize,
    /// drag resize) into a single set_size so the shell only gets one SIGWINCH.
    private var resizeWorkItem: DispatchWorkItem?

    private static let dropTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string
    ]

    init(paneID: UUID, workingDirectory: String, backgroundOpacity: Double = 1.0, command: String? = nil) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = backgroundOpacity >= 1.0
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes(Self.dropTypes)

        guard let app = GhosttyApp.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0 // 0 = use config default
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        config.wait_after_command = false

        // Inject NEX_PANE_ID so hook scripts know which pane fired.
        // Also prepend Contents/Helpers to PATH so `nex` (CLI) is found before
        // `Nex` (app binary) in Contents/MacOS on case-insensitive filesystems.
        let paneIDString = paneID.uuidString
        let helpersDir = Bundle.main.bundlePath + "/Contents/Helpers"
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let modifiedPath = helpersDir + ":" + currentPath

        paneIDString.withCString { paneIDCStr in
            modifiedPath.withCString { pathCStr in
                var envVars: [ghostty_env_var_s] = []

                let paneKey = strdup("NEX_PANE_ID")!
                let paneVal = strdup(paneIDCStr)!
                var paneEnv = ghostty_env_var_s()
                paneEnv.key = UnsafePointer(paneKey)
                paneEnv.value = UnsafePointer(paneVal)
                envVars.append(paneEnv)

                let pathKey = strdup("PATH")!
                let pathVal = strdup(pathCStr)!
                var pathEnv = ghostty_env_var_s()
                pathEnv.key = UnsafePointer(pathKey)
                pathEnv.value = UnsafePointer(pathVal)
                envVars.append(pathEnv)

                envVars.withUnsafeMutableBufferPointer { buffer in
                    config.env_vars = buffer.baseAddress
                    config.env_var_count = buffer.count

                    workingDirectory.withCString { cwd in
                        config.working_directory = cwd
                        Self.withOptionalCString(command) { cmdPtr in
                            config.command = cmdPtr
                            let rawSurface = ghostty_surface_new(app, &config)
                            if let rawSurface {
                                ghosttySurface = GhosttySurface(surface: rawSurface)
                                // Start unfocused — focus is granted explicitly via makeFirstResponder
                                ghosttySurface?.setFocus(false)
                            }
                        }
                    }
                }

                free(paneKey)
                free(paneVal)
                free(pathKey)
                free(pathVal)
            }
        }
    }

    /// Passes the UTF-8 C representation of `string` to `body`, or nil if `string` is nil.
    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        if let string {
            return string.withCString { body($0) }
        }
        return body(nil)
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
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let translationEvent = translationEvent(for: event)
        let markedTextBefore = hasMarkedText()

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translationEvent])

        let accumulated = keyTextAccumulator ?? []

        if !accumulated.isEmpty {
            // Composition committed one or more strings. Emit one key event per string
            // with composing=false. This handles US International dead-key failure,
            // where AppKit fires insertText twice (e.g. "'" then "s") in a single keyDown.
            for text in accumulated {
                var key = Self.keyEvent(
                    from: event,
                    action: action,
                    translationFlags: translationEvent.modifierFlags
                )
                key.composing = false
                sendKey(key, text: Self.ghosttyText(from: text))
            }
        } else {
            // No committed text. Either a pure preedit update, a bare key (arrow, enter),
            // or a composing keypress. `composing` is true if we're still in preedit now,
            // or if marked text existed before and was cleared by this event.
            var key = Self.keyEvent(
                from: event,
                action: action,
                translationFlags: translationEvent.modifierFlags
            )
            key.composing = hasMarkedText() || markedTextBefore
            sendKey(key, text: Self.ghosttyText(from: Self.ghosttyCharacters(from: translationEvent)))
        }
    }

    private func sendKey(_ key: ghostty_input_key_s, text: String?) {
        guard let text else {
            _ = ghosttySurface?.sendKey(key)
            return
        }
        var keyWithText = key
        text.withCString { ptr in
            keyWithText.text = ptr
            _ = ghosttySurface?.sendKey(keyWithText)
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
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool = switch event.keyCode {
            case 0x3C:
                event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

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
        let str: String
        switch string {
        case let v as NSAttributedString:
            str = v.string
        case let v as String:
            str = v
        default:
            return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            // Inside a keyDown: accumulate for the post-interpret loop.
            // AppKit may call insertText multiple times per keyDown.
            keyTextAccumulator?.append(str)
        } else {
            // Outside keyDown (dictation, services menu paste, drag-drop): send directly.
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

        // Outside keyDown (e.g. IME layout switch mid-compose), push preedit so the
        // terminal can render it. Inside keyDown the preedit state is conveyed by
        // the key event's composing flag.
        if keyTextAccumulator == nil {
            ghosttySurface?.sendPreedit(str)
        }
    }

    func unmarkText() {
        let hadMarked = markedText.length > 0
        markedText = NSMutableAttributedString()
        // Only push the clear to ghostty when outside keyDown. Inside keyDown, the next
        // key event's composing flag (and preedit updates) already convey the state.
        if hadMarked, keyTextAccumulator == nil {
            ghosttySurface?.sendPreedit("")
        }
    }

    func selectedRange() -> NSRange {
        guard let surface = ghosttySurface else {
            return NSRange(location: NSNotFound, length: 0)
        }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface.surface, &text) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let range = NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
        ghostty_surface_free_text(surface.surface, &text)
        return range
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

    func firstRect(forCharacterRange range: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let surface = ghosttySurface else {
            return window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        }
        var (x, y, w, h) = surface.imePoint()

        // Dictation indicator requests range.length == 0. A positive width
        // confuses the microphone overlay, so collapse it (matches Ghostty #8493).
        if range.length == 0, w > 0 {
            let cellWidth = w
            w = 0
            x += cellWidth * Double(range.location + range.length)
        }

        let viewRect = NSRect(
            x: x,
            y: frame.height - y,
            width: w,
            height: h
        )
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func characterIndex(for _: NSPoint) -> Int {
        0
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: Set(Self.dropTypes)) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content: String? = if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            urls
                .map { Self.shellEscape($0.isFileURL ? $0.path : $0.absoluteString) }
                .joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            str
        } else {
            nil
        }

        if let content {
            insertText(content, replacementRange: NSRange(location: 0, length: 0))
            return true
        }
        return false
    }

    /// Escape shell-sensitive characters so dropped paths are safe to paste into a terminal.
    static let shellEscapeChars = CharacterSet(charactersIn: " \\()[]{}<>\"'`!#$&;|*?\t")

    static func shellEscape(_ str: String) -> String {
        var result = ""
        result.reserveCapacity(str.count)
        for char in str.unicodeScalars {
            if shellEscapeChars.contains(char) {
                result.append("\\")
            }
            result.append(Character(char))
        }
        return result
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    // MARK: - Helpers

    private func translationEvent(for event: NSEvent) -> NSEvent {
        guard let surface = ghosttySurface?.surface else { return event }

        let translationMods = Self.eventModifierFlags(
            fromMods: ghostty_surface_key_translation_mods(
                surface,
                Self.mods(from: event)
            )
        )

        // Preserve hidden modifier bits that matter for AppKit/dead-key handling,
        // only toggling the visible modifiers ghostty asked us to translate with.
        var modifierFlags = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationMods.contains(flag) {
                modifierFlags.insert(flag)
            } else {
                modifierFlags.remove(flag)
            }
        }

        guard modifierFlags != event.modifierFlags else { return event }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: modifierFlags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

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

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(rawValue: raw)
    }

    static func eventModifierFlags(fromMods mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { flags.insert(.capsLock) }
        return flags
    }

    static func ghosttyCharacters(from event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700, scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    /// Final filter on the text passed into a libghostty key event's `key.text`.
    /// Returns nil for empty input or for strings whose first UTF-8 byte is a C0
    /// control code (< 0x20). When nil, the caller should send the key without
    /// `text` set so libghostty's keymap encodes the proper escape sequence
    /// (e.g. ESC [ Z for Shift+Tab, where macOS otherwise hands us 0x19).
    ///
    /// Mirrors upstream Ghostty's `keyAction` filter in SurfaceView_AppKit.swift.
    /// Note: this checks the first UTF-8 byte (not Unicode scalar), so emoji /
    /// astral chars and ZWJ sequences pass through unchanged.
    static func ghosttyText(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if let firstByte = text.utf8.first, firstByte < 0x20 {
            return nil
        }
        return text
    }

    static func keyEvent(
        from event: NSEvent,
        action: ghostty_input_action_e,
        translationFlags: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = mods(from: event)
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false

        // consumed_mods tells ghostty which modifiers were already applied by the
        // platform's text input system. Control and command never contribute to text
        // translation, so exclude them — everything else (shift, option, caps) is consumed.
        let consumedFlags = (translationFlags ?? event.modifierFlags).subtracting([.control, .command])
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
