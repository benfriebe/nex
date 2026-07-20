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

    /// One-shot latch for the initial-size rescue in `layout()` (issue #194).
    /// Flips true the first time the view lays out with a live window and
    /// non-zero bounds, at which point we force a `setSize` + draw. Guards
    /// against re-sizing on every subsequent layout pass (ongoing resizes go
    /// through `setFrameSize`'s debounce as before).
    private var hasSyncedInitialSize = false

    private static let dropTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string
    ]

    init(
        paneID: UUID,
        workingDirectory: String,
        backgroundOpacity: Double = 1.0,
        command: String? = nil,
        env: [String: String] = [:]
    ) {
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

        // Every key/value is strdup'd; libghostty copies the strings during
        // ghostty_surface_new, so all allocations are freed unconditionally
        // after the call returns.
        var envVars: [ghostty_env_var_s] = []
        var envAllocations: [UnsafeMutablePointer<CChar>] = []
        func appendEnv(_ key: String, _ value: String) {
            let keyPtr = strdup(key)!
            let valuePtr = strdup(value)!
            envAllocations.append(keyPtr)
            envAllocations.append(valuePtr)
            var entry = ghostty_env_var_s()
            entry.key = UnsafePointer(keyPtr)
            entry.value = UnsafePointer(valuePtr)
            envVars.append(entry)
        }

        for (key, value) in Self.mergedEnvVars(
            paneID: paneIDString, path: modifiedPath, profileEnv: env
        ) {
            appendEnv(key, value)
        }

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

        for pointer in envAllocations {
            free(pointer)
        }
    }

    /// Env keys the app owns; workspace-profile entries for these are ignored.
    private static let reservedEnvKeys: Set = ["NEX_PANE_ID", "PATH"]

    /// Build the ordered env list for a new surface: built-ins first, then
    /// profile vars in deterministic (sorted) order with reserved keys
    /// filtered out. Pure — split out so the filtering/ordering is
    /// unit-testable (`init` early-returns in test mode, so the actual
    /// env assembly never runs under test).
    static func mergedEnvVars(
        paneID: String,
        path: String,
        profileEnv: [String: String]
    ) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = [
            ("NEX_PANE_ID", paneID),
            ("PATH", path)
        ]
        for (key, value) in profileEnv.sorted(by: { $0.key < $1.key })
            where !reservedEnvKeys.contains(key) {
            result.append((key, value))
        }
        return result
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
        // Fallback only: the normal teardown path goes through
        // SurfaceManager.destroySurface → detachForTeardown(), which nils
        // ghosttySurface, so this is a no-op for managed surfaces. It still
        // frees a surface for any view dropped without manager teardown
        // (e.g. an orphaned/duplicate view that never registered).
        //
        // This fallback is intentionally synchronous: deinit cannot retain
        // the dying view to keep its layer alive across an off-main free, so
        // routing it through freeSurfaceAsync would risk a use-after-free of
        // the NSView's layer during teardown. The cost is that an *unmanaged*
        // view holding a SIGHUP-trapping surface would re-introduce the #136
        // hang here — but no managed path hits this (all real teardowns go
        // through destroySurface), so it stays the safe choice.
        ghosttySurface?.destroy()
    }

    /// Synchronously sever this view from its live libghostty surface
    /// ahead of an off-main `ghostty_surface_free` (issue #136). Cancels
    /// the pending resize, drops first-responder and view-hierarchy ties
    /// so the view stops driving the dead surface, and hands the raw
    /// surface pointer to the caller.
    ///
    /// Nil-ing `ghosttySurface` here is load-bearing beyond avoiding a
    /// `deinit` double-free: every deferred main-thread block that touches
    /// the surface — the `viewDidMoveToWindow` refresh/resize hop and the
    /// `setFrameSize` debounce work item — guards on `ghosttySurface?`, so
    /// clearing it on this same main-thread turn disarms any already-queued
    /// block from poking a surface that is about to be freed off-main.
    func detachForTeardown() -> ghostty_surface_t? {
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
        removeFromSuperview()
        let raw = ghosttySurface?.surface
        ghosttySurface = nil
        return raw
    }

    // MARK: - Layer

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        ghosttySurface?.draw()
    }

    override func layout() {
        super.layout()
        syncSublayerFrames()

        // Initial-size rescue (issue #194). A surface created while its window
        // was zero-bounds or occluded never gets a non-zero setSize or a draw:
        // the viewDidMoveToWindow async and setFrameSize debounce both
        // silently no-op on zero bounds / nil window, with no retry queued.
        // layout() fires when AppKit finally resolves real bounds, so seize
        // that first non-zero pass to size the surface and request a draw.
        // Latched so ongoing resizes still flow through setFrameSize's debounce.
        if !hasSyncedInitialSize, let window, bounds.width > 0, bounds.height > 0 {
            let scale = window.backingScaleFactor
            let w = UInt32(bounds.width * scale)
            let h = UInt32(bounds.height * scale)
            if w > 0, h > 0 {
                hasSyncedInitialSize = true
                ghosttySurface?.setSize(width: w, height: h)
                needsDisplay = true
            }
        }
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

    /// Force a size + draw re-sync for a surface that is currently in a live
    /// window (issue #194). Called when the app reactivates / a window becomes
    /// key so panes created while Nex was background/occluded — which may have
    /// missed their output-driven and layout-driven draw — repaint. No-op for
    /// detached surfaces (nil window, e.g. a pane in an inactive workspace);
    /// those re-sync via viewDidMoveToWindow when reattached.
    func resyncForRedraw() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        syncSublayerFrames()
        let scale = window.backingScaleFactor
        let w = UInt32(bounds.width * scale)
        let h = UInt32(bounds.height * scale)
        if w > 0, h > 0 {
            ghosttySurface?.setSize(width: w, height: h)
        }
        ghosttySurface?.refresh()
        needsDisplay = true
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
            // Mirror to sync-input peers (issue #121). No-op when this
            // pane isn't in any sync group, so the overhead is a single
            // dictionary lookup in `SurfaceManager`.
            SurfaceManager.liveValue.broadcastKey(from: paneID, key: key)
            return
        }
        var keyWithText = key
        text.withCString { ptr in
            keyWithText.text = ptr
            _ = ghosttySurface?.sendKey(keyWithText)
            // Broadcast inside `withCString` so `keyWithText.text`
            // (which points into this stack frame) is still live for
            // each sibling's `sendKey` call.
            SurfaceManager.liveValue.broadcastKey(from: paneID, key: keyWithText)
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

    /// Finds a link at a ghostty-space point by reading that row's text and
    /// matching it with `NSDataDetector`. Used only for the mouse-captured
    /// cmd-click path (see `mouseDown`) — libghostty's own link detection is
    /// unavailable there, so this re-derives "what's under the cursor" from
    /// scratch. Column math assumes one grid column per character, which
    /// holds for the ASCII URLs/paths this targets; it isn't attempted for
    /// wide (e.g. CJK) text preceding the link on the same row.
    private func detectLink(at point: NSPoint) -> String? {
        guard let ghosttySurface else { return nil }
        let size = ghosttySurface.size
        guard size.cell_width_px > 0, size.cell_height_px > 0, size.columns > 0, size.rows > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2.0
        let cellWidth = CGFloat(size.cell_width_px) / scale
        let cellHeight = CGFloat(size.cell_height_px) / scale
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let row = Int(point.y / cellHeight)
        let col = Int(point.x / cellWidth)
        guard row >= 0, row < Int(size.rows), col >= 0 else { return nil }

        guard let rowText = ghosttySurface.readText(row: UInt32(row), columns: UInt32(size.columns)),
              let detector = Self.linkDetector else { return nil }
        let nsText = rowText as NSString
        for match in detector.matches(in: rowText, range: NSRange(location: 0, length: nsText.length))
            where match.range.location <= col && col < match.range.location + match.range.length {
            return nsText.substring(with: match.range)
        }
        return nil
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Link found under the cursor by `mouseDown`'s cmd-click interception,
    /// carried through to `mouseUp` so the actual open happens on release
    /// (matching the drag-away-cancels convention of a normal click) — nil
    /// means this click isn't a link-open, so `mouseUp` forwards normally.
    private var interceptedLinkClick: String?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = mousePoint(from: event)

        // A cmd-click on a link normally opens it via libghostty's own
        // GHOSTTY_ACTION_OPEN_URL (fired from ghostty_surface_mouse_button).
        // But when the foreground program has captured the mouse (e.g. a
        // fullscreen TUI like Claude Code, running in the alternate screen
        // buffer with mouse reporting enabled), forwarding the click instead
        // hands it to the program as a raw mouse-report escape sequence — the
        // program doesn't understand it as "open this link" and the browser
        // never opens (issue #189). libghostty's own link detection doesn't
        // help here either: it skips hover/click link matching entirely on a
        // captured surface. So detect the link ourselves from the clicked
        // row's text and, if found, intercept the click instead of
        // forwarding anything to the captured program.
        interceptedLinkClick = nil
        if event.modifierFlags.contains(.command), ghosttySurface?.mouseCaptured == true {
            interceptedLinkClick = detectLink(at: point)
            if interceptedLinkClick != nil {
                return
            }
        }

        ghosttySurface?.sendMousePos(x: point.x, y: point.y, mods: Self.mods(from: event))
        _ = ghosttySurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: Self.mods(from: event)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if let link = interceptedLinkClick {
            interceptedLinkClick = nil
            let surface = ghosttySurface?.surface
            MainActor.assumeIsolated {
                GhosttyApp.openExternalLink(link, surface: surface)
            }
            return
        }

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
            // Mirror to sync-input peers (issue #121). The keyDown path
            // covers normal typing; this branch covers IME / dictation /
            // paste fall-throughs.
            SurfaceManager.liveValue.broadcastText(from: paneID, text: str)
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
