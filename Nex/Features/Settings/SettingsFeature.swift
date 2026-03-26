import AppKit
import ComposableArchitecture
import Foundation

@Reducer
struct SettingsFeature {
    static let defaultWorktreeBasePath = "~/nex/workspaces"

    @ObservableState
    struct State: Equatable {
        var backgroundOpacity: Double = 1.0
        var backgroundColorR: Double = 0.0
        var backgroundColorG: Double = 0.0
        var backgroundColorB: Double = 0.0
        var worktreeBasePath: String = SettingsFeature.defaultWorktreeBasePath

        /// The resolved absolute worktree base path (expands ~).
        var resolvedWorktreeBasePath: String {
            (worktreeBasePath as NSString).expandingTildeInPath
        }
    }

    enum Action: Equatable {
        case loadSettings
        case setBackgroundOpacity(Double)
        case setBackgroundColor(r: Double, g: Double, b: Double)
        case setWorktreeBasePath(String)
        case applyAppearance(opacity: Double, r: Double, g: Double, b: Double)
    }

    private enum AppearanceDebounceID: Hashable { case debounce }

    static let defaultsKeyOpacity = "settings.backgroundOpacity"
    static let defaultsKeyColorR = "settings.backgroundColorR"
    static let defaultsKeyColorG = "settings.backgroundColorG"
    static let defaultsKeyColorB = "settings.backgroundColorB"
    static let defaultsKeyHasCustomColor = "settings.hasCustomColor"
    static let defaultsKeyWorktreeBasePath = "settings.worktreeBasePath"

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.userDefaults) var userDefaults

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadSettings:
                if userDefaults.hasKey(Self.defaultsKeyOpacity) {
                    state.backgroundOpacity = userDefaults.doubleForKey(Self.defaultsKeyOpacity)
                }
                if let basePath = userDefaults.stringForKey(Self.defaultsKeyWorktreeBasePath) {
                    state.worktreeBasePath = basePath
                }
                if userDefaults.boolForKey(Self.defaultsKeyHasCustomColor) {
                    state.backgroundColorR = userDefaults.doubleForKey(Self.defaultsKeyColorR)
                    state.backgroundColorG = userDefaults.doubleForKey(Self.defaultsKeyColorG)
                    state.backgroundColorB = userDefaults.doubleForKey(Self.defaultsKeyColorB)
                } else {
                    let config = GhosttyConfigClient.liveValue
                    let color = config.backgroundColor.usingColorSpace(.sRGB) ?? config.backgroundColor
                    state.backgroundColorR = Double(color.redComponent)
                    state.backgroundColorG = Double(color.greenComponent)
                    state.backgroundColorB = Double(color.blueComponent)
                }

                return .send(.applyAppearance(
                    opacity: state.backgroundOpacity,
                    r: state.backgroundColorR,
                    g: state.backgroundColorG,
                    b: state.backgroundColorB
                ))

            case .setBackgroundOpacity(let opacity):
                state.backgroundOpacity = opacity
                return .send(.applyAppearance(
                    opacity: opacity,
                    r: state.backgroundColorR,
                    g: state.backgroundColorG,
                    b: state.backgroundColorB
                ))
                .debounce(id: AppearanceDebounceID.debounce, for: .milliseconds(100), scheduler: DispatchQueue.main)

            case .setBackgroundColor(let r, let g, let b):
                state.backgroundColorR = r
                state.backgroundColorG = g
                state.backgroundColorB = b
                return .send(.applyAppearance(
                    opacity: state.backgroundOpacity,
                    r: r, g: g, b: b
                ))
                .debounce(id: AppearanceDebounceID.debounce, for: .milliseconds(100), scheduler: DispatchQueue.main)

            case .setWorktreeBasePath(let path):
                state.worktreeBasePath = path
                userDefaults.setString(path, Self.defaultsKeyWorktreeBasePath)
                return .none

            case .applyAppearance(let opacity, let r, let g, let b):
                // Persist to UserDefaults
                userDefaults.setDouble(opacity, Self.defaultsKeyOpacity)
                userDefaults.setDouble(r, Self.defaultsKeyColorR)
                userDefaults.setDouble(g, Self.defaultsKeyColorG)
                userDefaults.setDouble(b, Self.defaultsKeyColorB)
                userDefaults.setBool(true, Self.defaultsKeyHasCustomColor)

                // Update shared config client
                GhosttyConfigClient.liveValue.backgroundOpacity = opacity
                GhosttyConfigClient.liveValue.backgroundColor = NSColor(
                    red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0
                )

                return .run { [surfaceManager] _ in
                    await MainActor.run {
                        // Write override file with both opacity and color
                        let hexR = String(format: "%02x", Int(r * 255))
                        let hexG = String(format: "%02x", Int(g * 255))
                        let hexB = String(format: "%02x", Int(b * 255))

                        let overrideContent = """
                        background = #\(hexR)\(hexG)\(hexB)
                        background-opacity = \(opacity)
                        """

                        let overridePath = NSTemporaryDirectory() + "nex-config-override"
                        try? overrideContent.write(
                            toFile: overridePath,
                            atomically: true,
                            encoding: .utf8
                        )

                        // Rebuild ghostty config with overrides.
                        // Guard: ghostty_config_new() requires ghostty_init() to have run.
                        // This effect can fire before GhosttyApp.start() if the Settings
                        // window is opened before the main window appears.
                        guard GhosttyApp.shared.app != nil else { return }

                        let newConfig = GhosttyConfig(overrideFile: overridePath)
                        newConfig.finalize()

                        ghostty_app_update_config(GhosttyApp.shared.app!, newConfig.rawConfig)
                        GhosttyApp.shared.config = newConfig

                        // Update window compositing
                        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                            window.isOpaque = opacity >= 1.0
                            window.backgroundColor = opacity < 1.0
                                ? .white.withAlphaComponent(0.001)
                                : .windowBackgroundColor
                        }
                        surfaceManager.setAllSurfacesOpaque(opacity >= 1.0)
                    }
                }
            }
        }
    }
}
