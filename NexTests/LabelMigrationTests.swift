import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Existing free-form workspace labels (which predate the label-presets
/// feature) must be back-filled into presets on launch, so they survive being
/// unapplied from a workspace.
@MainActor
struct LabelMigrationTests {
    private func workspace(labels: [String]) -> WorkspaceFeature.State {
        var ws = WorkspaceFeature.State(name: "WS")
        ws.labels = labels
        return ws
    }

    private func store(_ state: AppReducer.State) -> TestStoreOf<AppReducer> {
        let store = TestStore(initialState: state) { AppReducer() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            // Isolated so the one-shot migration flag starts unset per test (the
            // shared testValue dict otherwise leaks the flag across tests).
            $0.userDefaults = .ephemeral()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test func existingLabelsBackFillToDefaultPresets() async {
        var initial = AppReducer.State()
        initial.workspaces = [workspace(labels: ["Alpha", "Beta"])]
        initial.didRestoreWorkspaces = true // workspaces already restored

        let store = store(initial)
        // Presets load (none stored) → triggers the migration.
        await store.send(.labelPresetsLoaded([]))
        await store.receive(\.migrateLabelsToPresets) { state in
            #expect(state.labelPresets.map(\.name) == ["Alpha", "Beta"])
            #expect(state.labelPresets.allSatisfy { $0.color == .named(.gray) })
        }
        await store.finish()
    }

    @Test func existingPresetsAreNeitherOverwrittenNorDuplicated() async {
        var initial = AppReducer.State()
        initial.workspaces = [workspace(labels: ["Alpha", "Beta"])]
        initial.didRestoreWorkspaces = true

        let store = store(initial)
        // "Alpha" already has a blue preset → only "Beta" is back-filled.
        await store.send(.labelPresetsLoaded([LabelPreset(name: "Alpha", color: .named(.blue))]))
        await store.receive(\.migrateLabelsToPresets) { state in
            #expect(state.labelPresets.count == 2)
            #expect(state.labelPresets.first { $0.name == "Alpha" }?.color == .named(.blue))
            #expect(state.labelPresets.first { $0.name == "Beta" }?.color == .named(.gray))
        }
        await store.finish()
    }

    @Test func migrationWaitsForBothLoads() async {
        var initial = AppReducer.State()
        initial.workspaces = [workspace(labels: ["Alpha"])]
        // didRestoreWorkspaces stays false: presets loading alone must not migrate.

        let store = store(initial)
        await store.send(.labelPresetsLoaded([]))
        await store.receive(\.migrateLabelsToPresets) { state in
            #expect(state.labelPresets.isEmpty)
        }
        await store.finish()
    }

    /// A fresh install marks the migration done immediately (see the empty
    /// `stateLoaded` path). This asserts the safety that buys: once the flag is
    /// set, a later launch whose workspaces now carry the user's *own* labels
    /// must NOT back-fill them into gray presets (which would also resurrect any
    /// preset they deleted in the meantime).
    @Test func migrationIsSkippedOnceMarkedDone() async {
        let defaults = UserDefaultsClient.ephemeral()
        defaults.setBool(true, LabelPresetsStorage.migratedKey)
        var initial = AppReducer.State()
        initial.workspaces = [workspace(labels: ["Alpha", "Beta"])]
        initial.didRestoreWorkspaces = true

        let store = TestStore(initialState: initial) { AppReducer() } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.userDefaults = defaults
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.labelPresetsLoaded([]))
        await store.receive(\.migrateLabelsToPresets) { state in
            #expect(state.labelPresets.isEmpty)
        }
        await store.finish()
    }
}
