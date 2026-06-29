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

/// Which sidebar fill/stroke opacity a `setSidebarStyle` action targets.
enum SidebarStyleParam: String, Equatable {
    case avatarFill
    case avatarStroke
    case groupFill
    case groupStroke
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
        var confirmQuitWhenActive: Bool = true
        /// Master toggle for the status-bar system stats.
        var showSystemStats: Bool = true
        /// Which metrics are shown (rawValues of `SystemStatKind`).
        var enabledSystemStats: Set<String> = ["cpu", "memory", "load"]
        /// Render an inline sparkline next to each enabled metric.
        var showSystemStatGraphs: Bool = false
        /// Sparkline colour as `"RRGGBB"`; empty = adaptive chrome default.
        var sparklineColorHex: String = ""
        /// Inline sparkline width in points.
        var sparklineWidth: Double = 28
        /// Sparkline render style (`SparklineStyle` rawValue: line / dots).
        var sparklineStyle: String = "line"
        /// Warm app-chrome palette preference. Drives the sidebar / title bar /
        /// status bar appearance independently of the Ghostty terminal theme.
        var chromeAppearance: ChromeAppearance = .system
        /// Per-appearance chrome colour overrides. Keyed `"<light|dark>:<key>"`
        /// (see `ChromeColorKey`) → `"RRGGBB"`. Empty = use the presets.
        var chromeColorOverrides: [String: String] = [:]
        /// Multiplier on the opacity of the sidebar's WorkspaceColour-tinted
        /// elements (group bands + workspace avatars). 1 = preset intensity.
        var sidebarColorIntensity: Double = 1.0
        /// Per-element fill/stroke opacities for sidebar groups + icons.
        /// `groupFill < 0` means "use the per-appearance preset".
        var sidebarAvatarFillOpacity: Double = 0.20
        var sidebarAvatarStrokeOpacity: Double = 0.45
        var sidebarGroupFillOpacity: Double = -1
        var sidebarGroupStrokeOpacity: Double = 0.0

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
        case setConfirmQuitWhenActive(Bool)
        case setShowSystemStats(Bool)
        case setSystemStatEnabled(SystemStatKind, Bool)
        case setShowSystemStatGraphs(Bool)
        case setSparklineColor(String)
        case setSparklineWidth(Double)
        case setSparklineStyle(String)
        case setChromeAppearance(ChromeAppearance)
        case setChromeColor(key: String, hex: String?)
        case resetChromeColors
        case setSidebarColorIntensity(Double)
        case setSidebarStyle(SidebarStyleParam, Double)
        case refreshConfirmQuitWhenActive
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
    static let defaultsKeyConfirmQuitWhenActive = QuitGateDefaults.confirmQuit
    static let defaultsKeyShowSystemStats = "settings.showSystemStats"
    static let defaultsKeyEnabledSystemStats = "settings.enabledSystemStats"
    static let defaultsKeyShowSystemStatGraphs = "settings.showSystemStatGraphs"
    static let defaultsKeySparklineColor = "settings.sparklineColor"
    static let defaultsKeySparklineWidth = "settings.sparklineWidth"
    static let defaultsKeySparklineStyle = "settings.sparklineStyle"
    static let defaultsKeyChromeAppearance = "settings.chromeAppearance"
    static let defaultsKeyChromeColors = "settings.chromeColors"
    static let defaultsKeySidebarColorIntensity = "settings.sidebarColorIntensity"
    static let defaultsKeySidebarAvatarFill = "settings.sidebarAvatarFill"
    static let defaultsKeySidebarAvatarStroke = "settings.sidebarAvatarStroke"
    static let defaultsKeySidebarGroupFill = "settings.sidebarGroupFill"
    static let defaultsKeySidebarGroupStroke = "settings.sidebarGroupStroke"

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
                if userDefaults.hasKey(Self.defaultsKeyConfirmQuitWhenActive) {
                    state.confirmQuitWhenActive = userDefaults.boolForKey(Self.defaultsKeyConfirmQuitWhenActive)
                }
                if userDefaults.hasKey(Self.defaultsKeyShowSystemStats) {
                    state.showSystemStats = userDefaults.boolForKey(Self.defaultsKeyShowSystemStats)
                }
                if let raw = userDefaults.stringForKey(Self.defaultsKeyEnabledSystemStats) {
                    state.enabledSystemStats = Set(raw.split(separator: ",").map(String.init))
                }
                if userDefaults.hasKey(Self.defaultsKeyShowSystemStatGraphs) {
                    state.showSystemStatGraphs = userDefaults.boolForKey(Self.defaultsKeyShowSystemStatGraphs)
                }
                if let hex = userDefaults.stringForKey(Self.defaultsKeySparklineColor) {
                    state.sparklineColorHex = hex
                }
                if userDefaults.hasKey(Self.defaultsKeySparklineWidth) {
                    state.sparklineWidth = userDefaults.doubleForKey(Self.defaultsKeySparklineWidth)
                }
                if let style = userDefaults.stringForKey(Self.defaultsKeySparklineStyle), !style.isEmpty {
                    state.sparklineStyle = style
                }
                if let raw = userDefaults.stringForKey(Self.defaultsKeyChromeAppearance),
                   let appearance = ChromeAppearance(rawValue: raw) {
                    state.chromeAppearance = appearance
                }
                if let json = userDefaults.stringForKey(Self.defaultsKeyChromeColors),
                   let data = json.data(using: .utf8),
                   let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                    state.chromeColorOverrides = dict
                }
                if userDefaults.hasKey(Self.defaultsKeySidebarColorIntensity) {
                    state.sidebarColorIntensity = userDefaults.doubleForKey(Self.defaultsKeySidebarColorIntensity)
                }
                if userDefaults.hasKey(Self.defaultsKeySidebarAvatarFill) {
                    state.sidebarAvatarFillOpacity = userDefaults.doubleForKey(Self.defaultsKeySidebarAvatarFill)
                }
                if userDefaults.hasKey(Self.defaultsKeySidebarAvatarStroke) {
                    state.sidebarAvatarStrokeOpacity = userDefaults.doubleForKey(Self.defaultsKeySidebarAvatarStroke)
                }
                if userDefaults.hasKey(Self.defaultsKeySidebarGroupFill) {
                    state.sidebarGroupFillOpacity = userDefaults.doubleForKey(Self.defaultsKeySidebarGroupFill)
                }
                if userDefaults.hasKey(Self.defaultsKeySidebarGroupStroke) {
                    state.sidebarGroupStrokeOpacity = userDefaults.doubleForKey(Self.defaultsKeySidebarGroupStroke)
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

            case .setConfirmQuitWhenActive(let enabled):
                state.confirmQuitWhenActive = enabled
                userDefaults.setBool(enabled, Self.defaultsKeyConfirmQuitWhenActive)
                return .none

            case .setShowSystemStats(let enabled):
                state.showSystemStats = enabled
                userDefaults.setBool(enabled, Self.defaultsKeyShowSystemStats)
                return .none

            case .setSystemStatEnabled(let kind, let enabled):
                if enabled {
                    state.enabledSystemStats.insert(kind.rawValue)
                } else {
                    state.enabledSystemStats.remove(kind.rawValue)
                }
                userDefaults.setString(
                    state.enabledSystemStats.sorted().joined(separator: ","),
                    Self.defaultsKeyEnabledSystemStats
                )
                return .none

            case .setShowSystemStatGraphs(let enabled):
                state.showSystemStatGraphs = enabled
                userDefaults.setBool(enabled, Self.defaultsKeyShowSystemStatGraphs)
                return .none

            case .setSparklineColor(let hex):
                state.sparklineColorHex = hex
                userDefaults.setString(hex, Self.defaultsKeySparklineColor)
                return .none

            case .setSparklineWidth(let width):
                state.sparklineWidth = width
                userDefaults.setDouble(width, Self.defaultsKeySparklineWidth)
                return .none

            case .setSparklineStyle(let style):
                state.sparklineStyle = style
                userDefaults.setString(style, Self.defaultsKeySparklineStyle)
                return .none

            case .setChromeAppearance(let appearance):
                // Chrome-only: persist and let RootChromeView re-resolve the
                // palette. Deliberately decoupled from `.applyAppearance` —
                // this must NOT rebuild the ghostty terminal config.
                state.chromeAppearance = appearance
                userDefaults.setString(appearance.rawValue, Self.defaultsKeyChromeAppearance)
                return .none

            case .setChromeColor(let key, let hex):
                // Chrome-only, like setChromeAppearance: persist and let the
                // chrome wrappers re-resolve. nil hex resets that one colour.
                if let hex {
                    state.chromeColorOverrides[key] = hex
                } else {
                    state.chromeColorOverrides.removeValue(forKey: key)
                }
                if let data = try? JSONEncoder().encode(state.chromeColorOverrides),
                   let json = String(data: data, encoding: .utf8) {
                    userDefaults.setString(json, Self.defaultsKeyChromeColors)
                }
                return .none

            case .resetChromeColors:
                state.chromeColorOverrides = [:]
                userDefaults.setString("", Self.defaultsKeyChromeColors)
                return .none

            case .setSidebarColorIntensity(let intensity):
                state.sidebarColorIntensity = intensity
                userDefaults.setDouble(intensity, Self.defaultsKeySidebarColorIntensity)
                return .none

            case .setSidebarStyle(let param, let value):
                switch param {
                case .avatarFill:
                    state.sidebarAvatarFillOpacity = value
                    userDefaults.setDouble(value, Self.defaultsKeySidebarAvatarFill)
                case .avatarStroke:
                    state.sidebarAvatarStrokeOpacity = value
                    userDefaults.setDouble(value, Self.defaultsKeySidebarAvatarStroke)
                case .groupFill:
                    state.sidebarGroupFillOpacity = value
                    userDefaults.setDouble(value, Self.defaultsKeySidebarGroupFill)
                case .groupStroke:
                    state.sidebarGroupStrokeOpacity = value
                    userDefaults.setDouble(value, Self.defaultsKeySidebarGroupStroke)
                }
                return .none

            case .refreshConfirmQuitWhenActive:
                // Triggered when the dialog's "Don't ask again" checkbox
                // writes UserDefaults from outside the reducer. Re-read
                // so the Settings toggle doesn't go stale (issue #129).
                if userDefaults.hasKey(Self.defaultsKeyConfirmQuitWhenActive) {
                    state.confirmQuitWhenActive = userDefaults.boolForKey(Self.defaultsKeyConfirmQuitWhenActive)
                } else {
                    state.confirmQuitWhenActive = true
                }
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
                        // Let the SwiftUI environment re-inject so the markdown /
                        // scratchpad / diff panes pick up the new background live.
                        NotificationCenter.default.post(name: GhosttyConfigClient.changedNotification, object: nil)

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
