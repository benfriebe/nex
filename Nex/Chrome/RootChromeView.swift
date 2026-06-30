import AppKit
import ComposableArchitecture
import SwiftUI

/// App-root wrapper that resolves the warm `ChromeTheme` from the user's
/// `chromeAppearance` preference + the system colour scheme and injects it
/// into the environment for the whole window.
///
/// This is a deliberately small, distinct child view: `WithPerceptionTracking`
/// is a no-op in Release builds, so the theme would never re-resolve on a
/// preference change if this read lived inside `ContentView`'s large body.
/// Isolating it here guarantees the sun/moon toggle actually repaints the
/// chrome in Release. `ContentView(store:)` sits at a stable type+position,
/// so re-creating this wrapper on a preference change preserves the pane-grid
/// (terminal surface) subtree identity untouched.
struct RootChromeView: View {
    let store: StoreOf<AppReducer>
    /// The window's resolved scheme. Only consulted in the `.system` branch
    /// (where we don't force a scheme), so the read-then-override can't loop.
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.ghosttyConfig) private var ghosttyConfig

    var body: some View {
        WithPerceptionTracking {
            let theme = ChromeTheme.resolve(
                appearance: store.settings.chromeAppearance,
                system: systemScheme,
                overrides: store.settings.chromeColorOverrides
            )
            ChromeThemed(store: store) {
                ContentView(store: store)
                    .background {
                        // Only paint the opaque chrome backdrop when the
                        // terminal is fully opaque. With `background-opacity < 1`
                        // the window is non-opaque (see NexApp) so transparent
                        // shell surfaces can see through to the desktop — an
                        // opaque backdrop here would defeat that.
                        if ghosttyConfig.backgroundOpacity >= 1 {
                            theme.windowBackground.ignoresSafeArea()
                        }
                    }
            }
        }
    }
}

/// Resolves the chrome palette from the appearance preference + system scheme
/// and injects it (theme + preferredColorScheme + tint) for any subtree.
///
/// Shared by `RootChromeView` (the main window) and the `Settings` scene so
/// both honour the appearance preference. Like `RootChromeView`, the work
/// lives inside `WithPerceptionTracking` in this small, distinct child view so
/// a preference change actually re-resolves the theme in Release builds.
struct ChromeThemed<Content: View>: View {
    let store: StoreOf<AppReducer>
    @ViewBuilder var content: Content
    /// The true OS scheme, read from `NSApp.effectiveAppearance` and kept live —
    /// NOT `@Environment(\.colorScheme)`, which reflects this window's forced
    /// override and so can't tell us what "System" should resolve to.
    @StateObject private var systemAppearance = SystemAppearanceModel()

    var body: some View {
        WithPerceptionTracking {
            let appearance = store.settings.chromeAppearance
            let systemScheme = systemAppearance.colorScheme
            // Always resolve to a CONCRETE scheme. `.preferredColorScheme(nil)`
            // (the old `.system` path) does not reliably revert a window that was
            // previously forced to .light/.dark — that left the surfaces resolving
            // light while text/native chrome followed the dark window. Forcing a
            // concrete scheme makes every transition concrete→concrete (reliable),
            // and `systemAppearance` keeps `.system` following the OS live.
            let effective: ColorScheme = switch appearance {
            case .system: systemScheme
            case .light: .light
            case .dark: .dark
            }
            let theme = ChromeTheme.resolve(
                appearance: appearance,
                system: systemScheme,
                overrides: store.settings.chromeColorOverrides
            )
            content
                .environment(\.chromeTheme, theme)
                .environment(\.sidebarColorIntensity, store.settings.sidebarColorIntensity)
                .environment(\.sidebarFillStroke, SidebarFillStroke(
                    avatarFill: store.settings.sidebarAvatarFillOpacity,
                    avatarStroke: store.settings.sidebarAvatarStrokeOpacity,
                    groupFill: store.settings.sidebarGroupFillOpacity,
                    groupStroke: store.settings.sidebarGroupStrokeOpacity
                ))
                .preferredColorScheme(effective)
                .tint(theme.accent)
        }
    }
}

/// Publishes the true system colour scheme from `NSApp.effectiveAppearance`,
/// independent of any window's `.preferredColorScheme` override. Drives the
/// `.system` chrome preference: we force this concrete scheme rather than
/// `.preferredColorScheme(nil)` (which doesn't reliably revert a previously
/// forced window), and re-publish when the OS flips light/dark so `.system`
/// stays live (e.g. the auto day/night schedule).
@MainActor
final class SystemAppearanceModel: ObservableObject {
    @Published private(set) var colorScheme: ColorScheme
    private var observation: NSKeyValueObservation?

    init() {
        colorScheme = SystemAppearanceModel.current()
        // NSKeyValueObservation invalidates itself on deinit, so no manual
        // teardown is needed.
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let scheme = SystemAppearanceModel.current()
        if colorScheme != scheme { colorScheme = scheme }
    }

    private static func current() -> ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}
