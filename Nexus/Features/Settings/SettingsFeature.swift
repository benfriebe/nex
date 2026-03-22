import AppKit
import ComposableArchitecture
import Foundation

@Reducer
struct SettingsFeature {
    static let defaultWorktreeBasePath = "~/nexus/workspaces"

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

    private static let defaultsKeyOpacity = "settings.backgroundOpacity"
    private static let defaultsKeyColorR = "settings.backgroundColorR"
    private static let defaultsKeyColorG = "settings.backgroundColorG"
    private static let defaultsKeyColorB = "settings.backgroundColorB"
    private static let defaultsKeyHasCustomColor = "settings.hasCustomColor"
    private static let defaultsKeyWorktreeBasePath = "settings.worktreeBasePath"

    @Dependency(\.surfaceManager) var surfaceManager

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadSettings:
                let defaults = UserDefaults.standard
                if defaults.object(forKey: Self.defaultsKeyOpacity) != nil {
                    state.backgroundOpacity = defaults.double(forKey: Self.defaultsKeyOpacity)
                }
                if let basePath = defaults.string(forKey: Self.defaultsKeyWorktreeBasePath) {
                    state.worktreeBasePath = basePath
                }
                if defaults.bool(forKey: Self.defaultsKeyHasCustomColor) {
                    state.backgroundColorR = defaults.double(forKey: Self.defaultsKeyColorR)
                    state.backgroundColorG = defaults.double(forKey: Self.defaultsKeyColorG)
                    state.backgroundColorB = defaults.double(forKey: Self.defaultsKeyColorB)
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
                UserDefaults.standard.set(path, forKey: Self.defaultsKeyWorktreeBasePath)
                return .none

            case .applyAppearance(let opacity, let r, let g, let b):
                // Persist to UserDefaults
                let defaults = UserDefaults.standard
                defaults.set(opacity, forKey: Self.defaultsKeyOpacity)
                defaults.set(r, forKey: Self.defaultsKeyColorR)
                defaults.set(g, forKey: Self.defaultsKeyColorG)
                defaults.set(b, forKey: Self.defaultsKeyColorB)
                defaults.set(true, forKey: Self.defaultsKeyHasCustomColor)

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

                        let overridePath = NSTemporaryDirectory() + "nexus-config-override"
                        try? overrideContent.write(
                            toFile: overridePath,
                            atomically: true,
                            encoding: .utf8
                        )

                        // Rebuild ghostty config with overrides
                        let newConfig = GhosttyConfig(overrideFile: overridePath)
                        newConfig.finalize()

                        if let app = GhosttyApp.shared.app {
                            ghostty_app_update_config(app, newConfig.rawConfig)
                        }
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
