import AppKit
import Carbon.HIToolbox
import ComposableArchitecture
import Foundation
import os.log

enum GlobalHotkeyError: Error, CustomStringConvertible {
    case registrationFailed(osStatus: OSStatus)
    case handlerInstallFailed(osStatus: OSStatus)

    var description: String {
        switch self {
        case .registrationFailed(let status):
            if status == Int32(eventHotKeyExistsErr) {
                return "This shortcut is already claimed by another app."
            }
            return "Could not register hotkey (OSStatus \(status))."
        case .handlerInstallFailed(let status):
            return "Could not install hotkey handler (OSStatus \(status))."
        }
    }
}

/// Service wrapping Carbon `RegisterEventHotKey` for a single app-wide global hotkey.
/// Thread-safety: all methods must be called from the main actor.
@MainActor
final class GlobalHotkeyService: @unchecked Sendable {
    static let shared = GlobalHotkeyService()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.benfriebe.nex",
        category: "GlobalHotkeyService"
    )

    private static let hotKeySignature: FourCharCode = {
        let chars = Array("NEX1".utf8)
        return (FourCharCode(chars[0]) << 24)
            | (FourCharCode(chars[1]) << 16)
            | (FourCharCode(chars[2]) << 8)
            | FourCharCode(chars[3])
    }()

    private var hotKeyRef: EventHotKeyRef?
    private var currentTrigger: KeyTrigger?
    private var nextHotKeyID: UInt32 = 0
    private var handlerRef: EventHandlerRef?

    /// Invoked on the main actor when the hotkey is pressed.
    var onPressed: (() -> Void)?

    private init() {}

    /// Register a trigger as the global hotkey, replacing any existing registration.
    /// Passing `nil` clears the hotkey.
    ///
    /// Performs a staged swap: the new trigger is registered first, and only
    /// after Carbon accepts it do we unregister the previous one. If Carbon
    /// rejects the new trigger (e.g. another app owns the combo), the old
    /// registration is left intact and this call throws — callers should treat
    /// a throw as "no change happened" and roll back their own state.
    func register(_ trigger: KeyTrigger?) throws {
        guard let trigger else {
            unregister()
            return
        }

        // No-op when the current registration already matches.
        if currentTrigger == trigger, hotKeyRef != nil { return }

        try installHandlerIfNeeded()

        nextHotKeyID &+= 1
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: nextHotKeyID)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(trigger.keyCode),
            Self.carbonFlags(for: trigger.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newRef
        )

        guard status == noErr, let newRef else {
            Self.logger.warning(
                "RegisterEventHotKey failed with OSStatus \(status); preserving previous registration"
            )
            throw GlobalHotkeyError.registrationFailed(osStatus: status)
        }

        // Success: drop the previous registration (if any) and swap.
        if let oldRef = hotKeyRef {
            UnregisterEventHotKey(oldRef)
        }
        hotKeyRef = newRef
        currentTrigger = trigger
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        currentTrigger = nil
    }

    // MARK: - Private

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.eventHandler,
            1,
            &spec,
            userData,
            &ref
        )
        guard status == noErr, let ref else {
            Self.logger.error("InstallEventHandler failed with OSStatus \(status)")
            throw GlobalHotkeyError.handlerInstallFailed(osStatus: status)
        }
        handlerRef = ref
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        // Match on signature only — the `id` rotates on every successful
        // `register(...)` call so a stale event (registered with an older
        // id) still gets dispatched correctly.
        guard status == noErr,
              hotKeyID.signature == GlobalHotkeyService.hotKeySignature
        else {
            return status
        }

        let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                service.onPressed?()
            }
        }
        return noErr
    }

    private static func carbonFlags(for modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }
}

// MARK: - TCA Dependency

/// Protocol abstraction so tests can substitute a no-op implementation without touching Carbon.
protocol GlobalHotkeyServicing: Sendable {
    func register(_ trigger: KeyTrigger?) async throws
}

struct LiveGlobalHotkeyService: GlobalHotkeyServicing {
    func register(_ trigger: KeyTrigger?) async throws {
        try await MainActor.run {
            // Belt-and-braces: never touch Carbon during XCTest runs.
            // `isTestMode` is main-actor-isolated, so read it here.
            guard !NexApp.isTestMode else { return }
            try GlobalHotkeyService.shared.register(trigger)
        }
    }
}

struct NoopGlobalHotkeyService: GlobalHotkeyServicing {
    func register(_: KeyTrigger?) async throws {}
}

private enum GlobalHotkeyServiceKey: DependencyKey {
    static let liveValue: any GlobalHotkeyServicing = LiveGlobalHotkeyService()
    static let testValue: any GlobalHotkeyServicing = NoopGlobalHotkeyService()
}

extension DependencyValues {
    var globalHotkeyService: any GlobalHotkeyServicing {
        get { self[GlobalHotkeyServiceKey.self] }
        set { self[GlobalHotkeyServiceKey.self] = newValue }
    }
}
