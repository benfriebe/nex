import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Chrome appearance / colour / theme changes recolour the agent-status dots.
/// The SwiftUI chrome re-reads them from the environment automatically, but the
/// imperative AppKit menu-bar icon + popover are only refreshed when the reducer
/// dispatches `.updateExternalIndicators`. These assert that each chrome-mutating
/// settings action triggers that refresh — and so guards against the case being
/// shadowed (and thus dead) behind the catch-all `case .settings:`.
@MainActor
struct ChromeIndicatorRefreshTests {
    private func store() -> TestStoreOf<AppReducer> {
        let store = TestStore(initialState: AppReducer.State()) { AppReducer() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.userDefaults = .ephemeral()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test func setChromeColorRefreshesIndicators() async {
        let store = store()
        await store.send(.settings(.setChromeColor(key: "dark:statusRunning", hex: "FF0000")))
        await store.receive(\.updateExternalIndicators)
        await store.finish()
    }

    @Test func setChromeAppearanceRefreshesIndicators() async {
        let store = store()
        await store.send(.settings(.setChromeAppearance(.dark)))
        await store.receive(\.updateExternalIndicators)
        await store.finish()
    }

    @Test func resetChromeColorsRefreshesIndicators() async {
        let store = store()
        await store.send(.settings(.resetChromeColors))
        await store.receive(\.updateExternalIndicators)
        await store.finish()
    }

    @Test func applyStyleThemeRefreshesIndicators() async {
        let store = store()
        // A preset/imported theme can recolour the status dots, so it must
        // refresh the AppKit indicators too (the gap that adding it to the
        // refresh list closes).
        let theme = BuiltInChromeTheme.all[0].styleTheme
        await store.send(.settings(.applyStyleTheme(theme)))
        await store.receive(\.updateExternalIndicators)
        await store.finish()
    }
}
