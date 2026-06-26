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
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        WithPerceptionTracking {
            let appearance = store.settings.chromeAppearance
            let theme = ChromeTheme.resolve(
                appearance: appearance,
                system: systemScheme,
                overrides: store.settings.chromeColorOverrides
            )
            content
                .environment(\.chromeTheme, theme)
                .environment(\.sidebarColorIntensity, store.settings.sidebarColorIntensity)
                .preferredColorScheme(appearance.explicitScheme)
                .tint(theme.accent)
        }
    }
}
