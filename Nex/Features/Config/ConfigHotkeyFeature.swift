import AppKit
import ComposableArchitecture
import Foundation

/// Child reducer owning user-configuration state that no other domain
/// writes: in-app keybindings, the focus-follows-mouse settings, the TCP
/// listener port, and the global (system-wide) hotkey. Extracted from
/// `AppReducer` as a pure structural move -- behavior is identical.
///
/// Bootstrap stays in `AppReducer`: `appLaunched` loads the config off
/// disk and forwards the parsed values into this reducer via
/// `keybindingsLoaded` / `applyLoadedConfig`, while `AppReducer.configLoaded`
/// still fires the cross-domain effects (theme selection, hotkey
/// registration) itself.
@Reducer
struct ConfigHotkeyFeature {
    @ObservableState
    struct State: Equatable {
        var keybindings: KeyBindingMap = .defaults
        var focusFollowsMouse: Bool = false
        var focusFollowsMouseDelay: Int = 100
        var tcpPort: Int = 0
        var tcpPortError: String?
        var globalHotkey: KeyTrigger?
        var globalHotkeyHideOnRepress: Bool = true
        var globalHotkeyRegistrationError: String?

        /// Collision between the current global hotkey and an in-app
        /// keybinding. Computed so it always reflects the latest state --
        /// `keybindings` and `globalHotkey` can land in state in either
        /// order during `appLaunched`, and either one may change later.
        var globalHotkeyConflictWithInApp: KeybindingConflict? {
            guard let trigger = globalHotkey else { return nil }
            return KeybindingConflict.check(
                trigger: trigger,
                in: keybindings,
                globalHotkey: nil,
                ignoreGlobalHotkey: true
            )
        }
    }

    enum Action: Equatable {
        // Keybindings
        case keybindingsLoaded(KeyBindingMap)
        case setKeybinding(KeyTrigger, NexAction)
        case removeKeybinding(KeyTrigger)
        case resetBindingsForAction(NexAction)
        case resetKeybindings

        /// General config
        /// Forwarded from `AppReducer.configLoaded` once the config file
        /// has been parsed off disk. Carries the config/hotkey fields this
        /// reducer owns; `AppReducer` keeps firing the theme + hotkey
        /// registration effects itself.
        case applyLoadedConfig(
            focusFollowsMouse: Bool,
            focusFollowsMouseDelay: Int,
            tcpPort: Int,
            globalHotkey: KeyTrigger?,
            globalHotkeyHideOnRepress: Bool
        )
        case setFocusFollowsMouse(Bool)
        case setFocusFollowsMouseDelay(Int)
        case setTCPPort(Int)
        case tcpPortStartFailed(Int)

        // Global Hotkey
        case setGlobalHotkey(KeyTrigger?)
        case setGlobalHotkeyHideOnRepress(Bool)
        case globalHotkeyPressed
        case globalHotkeyRegistrationFailed(reason: String)
        case globalHotkeyRegistrationRejected(revertTo: KeyTrigger?, reason: String)
    }

    @Dependency(\.globalHotkeyService) var globalHotkeyService
    @Dependency(\.socketServer) var socketServer

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            // MARK: - Keybindings

            case .keybindingsLoaded(let bindings):
                state.keybindings = bindings
                return .none

            case .setKeybinding(let trigger, let action):
                state.keybindings.setBinding(trigger: trigger, action: action)
                return .run { [keybindings = state.keybindings] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(keybindings, toFile: path)
                }

            case .removeKeybinding(let trigger):
                state.keybindings.removeBinding(trigger: trigger)
                return .run { [keybindings = state.keybindings] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(keybindings, toFile: path)
                }

            case .resetBindingsForAction(let action):
                state.keybindings.removeAllBindings(for: action)
                for trigger in KeyBindingMap.defaults.triggers(for: action) {
                    state.keybindings.setBinding(trigger: trigger, action: action)
                }
                return .run { [keybindings = state.keybindings] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(keybindings, toFile: path)
                }

            case .resetKeybindings:
                state.keybindings = .defaults
                return .run { _ in
                    let path = KeybindingService.configPath
                    ConfigParser.writeKeybindings(.defaults, toFile: path)
                }

            // MARK: - General Config

            case .applyLoadedConfig(
                let focusFollowsMouse,
                let focusFollowsMouseDelay,
                let tcpPort,
                let globalHotkey,
                let globalHotkeyHideOnRepress
            ):
                state.focusFollowsMouse = focusFollowsMouse
                state.focusFollowsMouseDelay = focusFollowsMouseDelay
                state.tcpPort = tcpPort
                state.globalHotkey = globalHotkey
                state.globalHotkeyHideOnRepress = globalHotkeyHideOnRepress
                state.globalHotkeyRegistrationError = nil
                return .none

            case .setFocusFollowsMouse(let enabled):
                state.focusFollowsMouse = enabled
                return .run { _ in
                    let path = KeybindingService.configPath
                    ConfigParser.setGeneralSetting(
                        "focus-follows-mouse",
                        value: enabled ? "true" : "false",
                        inFile: path
                    )
                }

            case .setFocusFollowsMouseDelay(let ms):
                state.focusFollowsMouseDelay = max(0, ms)
                return .run { [delay = state.focusFollowsMouseDelay] _ in
                    let path = KeybindingService.configPath
                    ConfigParser.setGeneralSetting(
                        "focus-follows-mouse-delay",
                        value: "\(delay)",
                        inFile: path
                    )
                }

            case .setTCPPort(let port):
                state.tcpPort = max(0, min(port, 65535))
                state.tcpPortError = nil
                return .run { [port = state.tcpPort] send in
                    socketServer.stopTCP()
                    if port > 0 {
                        let started = socketServer.startTCP(port: port)
                        if !started {
                            await send(.tcpPortStartFailed(port))
                            return
                        }
                    }
                    ConfigParser.setGeneralSetting(
                        "tcp-port",
                        value: "\(port)",
                        inFile: KeybindingService.configPath
                    )
                }

            case .tcpPortStartFailed(let port):
                state.tcpPortError = "Port \(port) is unavailable"
                return .none

            // MARK: - Global Hotkey

            case .setGlobalHotkey(let trigger):
                // Optimistically update state; if Carbon rejects the new
                // trigger, `globalHotkeyRegistrationRejected` will roll it
                // back to `previousTrigger` and the config file is left
                // untouched. The service keeps the previous registration
                // alive on failure, so the user's working hotkey is never
                // silently dropped.
                let previousTrigger = state.globalHotkey
                state.globalHotkey = trigger
                state.globalHotkeyRegistrationError = nil
                return .run { [trigger, previousTrigger, service = globalHotkeyService] send in
                    do {
                        try await service.register(trigger)
                    } catch {
                        await send(.globalHotkeyRegistrationRejected(
                            revertTo: previousTrigger,
                            reason: "\(error)"
                        ))
                        return
                    }
                    ConfigParser.setGeneralSetting(
                        "global-hotkey",
                        value: trigger?.configString ?? "none",
                        inFile: KeybindingService.configPath
                    )
                }

            case .setGlobalHotkeyHideOnRepress(let hide):
                state.globalHotkeyHideOnRepress = hide
                return .run { _ in
                    ConfigParser.setGeneralSetting(
                        "global-hotkey-hide-on-repress",
                        value: hide ? "true" : "false",
                        inFile: KeybindingService.configPath
                    )
                }

            case .globalHotkeyPressed:
                return .run { [hide = state.globalHotkeyHideOnRepress] _ in
                    await MainActor.run {
                        toggleAppFrontmost(hideOnRepress: hide)
                    }
                }

            case .globalHotkeyRegistrationFailed(let reason):
                // Used only by the config-load path -- we want state to keep
                // reflecting what's in the config file so the user can see
                // and edit the failing value from Settings.
                state.globalHotkeyRegistrationError = reason
                return .none

            case .globalHotkeyRegistrationRejected(let revertTo, let reason):
                state.globalHotkey = revertTo
                state.globalHotkeyRegistrationError = reason
                return .none
            }
        }
    }
}
