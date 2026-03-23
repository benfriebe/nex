import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct SettingsFeatureTests {
    private func makeStore(
        state: SettingsFeature.State = SettingsFeature.State()
    ) -> TestStoreOf<SettingsFeature> {
        let store = TestStore(initialState: state) {
            SettingsFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test func setBackgroundOpacityUpdatesState() async {
        let store = makeStore()

        await store.send(.setBackgroundOpacity(0.75)) { state in
            #expect(state.backgroundOpacity == 0.75)
        }
    }

    @Test func setBackgroundColorUpdatesState() async {
        let store = makeStore()

        await store.send(.setBackgroundColor(r: 0.2, g: 0.4, b: 0.6)) { state in
            #expect(state.backgroundColorR == 0.2)
            #expect(state.backgroundColorG == 0.4)
            #expect(state.backgroundColorB == 0.6)
        }
    }

    @Test func setWorktreeBasePathUpdatesState() async {
        let store = makeStore()

        await store.send(.setWorktreeBasePath("/custom/path")) { state in
            #expect(state.worktreeBasePath == "/custom/path")
        }
    }

    @Test func resolvedWorktreeBasePathExpandsTilde() {
        var state = SettingsFeature.State()
        state.worktreeBasePath = "~/nex/workspaces"
        let expected = ("~/nex/workspaces" as NSString).expandingTildeInPath
        #expect(state.resolvedWorktreeBasePath == expected)
    }
}
