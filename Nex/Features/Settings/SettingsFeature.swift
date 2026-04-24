import AppKit
import ComposableArchitecture
import Foundation

/// Controls where a newly created sidebar entry (group or workspace) is
/// inserted. Used by both `newGroupPlacement` and `newWorkspacePlacement`.
enum SidebarPlacement: String, CaseIterable, Codable, Equatable {
    /// Insert near the active workspace: at the top level, after its
    /// sidebar entry (or its parent group's entry when nested); inside a
    /// group, after the active workspace's slot in that group's children.
    /// Falls back to appending when there's no active workspace.
    case nearSelection = "near-selection"

    /// Always append to the end of the list (or the end of the target
    /// group's children). This is the default.
    case endOfList = "end-of-list"
}

@Reducer
struct SettingsFeature {
    static let defaultWorktreeBasePath = "~/nex/worktrees/<repo>"

    @ObservableState
    struct State: Equatable {
        var backgroundOpacity: Double = 1.0
        var backgroundColorR: Double = 0.0
        var backgroundColorG: Double = 0.0
        var backgroundColorB: Double = 0.0
        var worktreeBasePath: String = SettingsFeature.defaultWorktreeBasePath
        var selectedTheme: NexTheme?
        var autoDetectRepos: Bool = true
        var inheritGroupOnNewWorkspace: Bool = true
        var expandGroupOnWorkspaceDrop: Bool = true
        var newGroupPlacement: SidebarPlacement = .endOfList
        var newWorkspacePlacement: SidebarPlacement = .endOfList

        /// The resolved absolute worktree base path. Expands ~ and substitutes
        /// the `<repo>` placeholder:
        /// - At the start of the path, `<repo>` resolves to the full repository path.
        /// - Elsewhere in the path, `<repo>` resolves to the repository's directory name.
        func resolvedWorktreeBasePath(forRepoPath repoPath: String? = nil) -> String {
            var path = worktreeBasePath
            if let repoPath, path.hasPrefix("<repo>") {
                path = repoPath + path.dropFirst("<repo>".count)
            }
            if let repoPath {
                let repoName = (repoPath as NSString).lastPathComponent
                path = path.replacingOccurrences(of: "<repo>", with: repoName)
            }
            return (path as NSString).expandingTildeInPath
        }
    }

    enum Action: Equatable {
        case loadSettings
        case setBackgroundOpacity(Double)
        case setBackgroundColor(r: Double, g: Double, b: Double)
        case setWorktreeBasePath(String)
        case setAutoDetectRepos(Bool)
        case setInheritGroupOnNewWorkspace(Bool)
        case setExpandGroupOnWorkspaceDrop(Bool)
        case setNewGroupPlacement(SidebarPlacement)
        case setNewWorkspacePlacement(SidebarPlacement)
        case selectTheme(NexTheme?)
        case applyAppearance(opacity: Double, r: Double, g: Double, b: Double, theme: NexTheme?)
    }

    private enum AppearanceDebounceID: Hashable { case debounce }

    static let defaultsKeyOpacity = "settings.backgroundOpacity"
    static let defaultsKeyColorR = "settings.backgroundColorR"
    static let defaultsKeyColorG = "settings.backgroundColorG"
    static let defaultsKeyColorB = "settings.backgroundColorB"
    static let defaultsKeyHasCustomColor = "settings.hasCustomColor"
    static let defaultsKeyWorktreeBasePath = "settings.worktreeBasePath"
    static let defaultsKeySelectedTheme = "settings.selectedTheme"
    static let defaultsKeyAutoDetectRepos = "settings.autoDetectRepos"
    static let defaultsKeyInheritGroupOnNewWorkspace = "settings.inheritGroupOnNewWorkspace"
    static let defaultsKeyExpandGroupOnWorkspaceDrop = "settings.expandGroupOnWorkspaceDrop"
    static let defaultsKeyNewGroupPlacement = "settings.newGroupPlacement"
    static let defaultsKeyNewWorkspacePlacement = "settings.newWorkspacePlacement"

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
                if userDefaults.hasKey(Self.defaultsKeyAutoDetectRepos) {
                    state.autoDetectRepos = userDefaults.boolForKey(Self.defaultsKeyAutoDetectRepos)
                }
                if userDefaults.hasKey(Self.defaultsKeyInheritGroupOnNewWorkspace) {
                    state.inheritGroupOnNewWorkspace = userDefaults.boolForKey(Self.defaultsKeyInheritGroupOnNewWorkspace)
                }
                if userDefaults.hasKey(Self.defaultsKeyExpandGroupOnWorkspaceDrop) {
                    state.expandGroupOnWorkspaceDrop = userDefaults.boolForKey(Self.defaultsKeyExpandGroupOnWorkspaceDrop)
                }
                if let raw = userDefaults.stringForKey(Self.defaultsKeyNewGroupPlacement),
                   let placement = SidebarPlacement(rawValue: raw) {
                    state.newGroupPlacement = placement
                }
                if let raw = userDefaults.stringForKey(Self.defaultsKeyNewWorkspacePlacement),
                   let placement = SidebarPlacement(rawValue: raw) {
                    state.newWorkspacePlacement = placement
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

                if let name = userDefaults.stringForKey(Self.defaultsKeySelectedTheme),
                   let theme = NexTheme.named(name) {
                    state.selectedTheme = theme
                }

                return .send(.applyAppearance(
                    opacity: state.backgroundOpacity,
                    r: state.backgroundColorR,
                    g: state.backgroundColorG,
                    b: state.backgroundColorB,
                    theme: state.selectedTheme
                ))

            case .setBackgroundOpacity(let opacity):
                state.backgroundOpacity = opacity
                return .send(.applyAppearance(
                    opacity: opacity,
                    r: state.backgroundColorR,
                    g: state.backgroundColorG,
                    b: state.backgroundColorB,
                    theme: state.selectedTheme
                ))
                .cancellable(id: AppearanceDebounceID.debounce, cancelInFlight: true)

            case .setBackgroundColor(let r, let g, let b):
                state.backgroundColorR = r
                state.backgroundColorG = g
                state.backgroundColorB = b
                state.selectedTheme = nil
                userDefaults.setString("", Self.defaultsKeySelectedTheme)
                return .send(.applyAppearance(
                    opacity: state.backgroundOpacity,
                    r: r, g: g, b: b,
                    theme: nil
                ))
                .cancellable(id: AppearanceDebounceID.debounce, cancelInFlight: true)

            case .setWorktreeBasePath(let path):
                state.worktreeBasePath = path
                userDefaults.setString(path, Self.defaultsKeyWorktreeBasePath)
                return .none

            case .setAutoDetectRepos(let enabled):
                state.autoDetectRepos = enabled
                userDefaults.setBool(enabled, Self.defaultsKeyAutoDetectRepos)
                return .none

            case .setInheritGroupOnNewWorkspace(let enabled):
                state.inheritGroupOnNewWorkspace = enabled
                userDefaults.setBool(enabled, Self.defaultsKeyInheritGroupOnNewWorkspace)
                return .none

            case .setExpandGroupOnWorkspaceDrop(let enabled):
                state.expandGroupOnWorkspaceDrop = enabled
                userDefaults.setBool(enabled, Self.defaultsKeyExpandGroupOnWorkspaceDrop)
                return .none

            case .setNewGroupPlacement(let placement):
                state.newGroupPlacement = placement
                userDefaults.setString(placement.rawValue, Self.defaultsKeyNewGroupPlacement)
                return .none

            case .setNewWorkspacePlacement(let placement):
                state.newWorkspacePlacement = placement
                userDefaults.setString(placement.rawValue, Self.defaultsKeyNewWorkspacePlacement)
                return .none

            case .selectTheme(let theme):
                state.selectedTheme = theme
                userDefaults.setString(theme?.id ?? "", Self.defaultsKeySelectedTheme)
                return .send(.applyAppearance(
                    opacity: state.backgroundOpacity,
                    r: state.backgroundColorR,
                    g: state.backgroundColorG,
                    b: state.backgroundColorB,
                    theme: theme
                ))

            case .applyAppearance(let opacity, let r, let g, let b, let theme):
                // Persist opacity always; only persist custom color when not using a theme.
                userDefaults.setDouble(opacity, Self.defaultsKeyOpacity)
                if theme == nil {
                    userDefaults.setDouble(r, Self.defaultsKeyColorR)
                    userDefaults.setDouble(g, Self.defaultsKeyColorG)
                    userDefaults.setDouble(b, Self.defaultsKeyColorB)
                    userDefaults.setBool(true, Self.defaultsKeyHasCustomColor)
                }

                return .run { [surfaceManager] _ in
                    await MainActor.run {
                        // Build override file: use theme name when active, else explicit color.
                        let overrideContent: String
                        if let theme {
                            overrideContent = """
                            theme = \(theme.id)
                            background-opacity = \(opacity)
                            """
                        } else {
                            let hexR = String(format: "%02x", Int(r * 255))
                            let hexG = String(format: "%02x", Int(g * 255))
                            let hexB = String(format: "%02x", Int(b * 255))
                            overrideContent = """
                            background = #\(hexR)\(hexG)\(hexB)
                            background-opacity = \(opacity)
                            """
                        }

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

                        // Read resolved background from ghostty (correct for both theme and custom).
                        GhosttyConfigClient.liveValue.backgroundOpacity = opacity
                        GhosttyConfigClient.liveValue.backgroundColor = newConfig.backgroundColor

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
