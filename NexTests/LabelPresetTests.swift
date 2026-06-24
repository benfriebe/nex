import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct LabelPresetTests {
    private func makeStore(
        labelPresets: [LabelPreset] = [],
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = []
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.labelPresets = labelPresets
        appState.workspaces = workspaces

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            // Fresh in-memory UserDefaults so persist effects don't touch
            // the shared test store or the real defaults.
            $0.userDefaults = makeEphemeralUserDefaults()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func makeEphemeralUserDefaults() -> UserDefaultsClient {
        let lock = NSLock()
        nonisolated(unsafe) var dict: [String: Any] = [:]
        return UserDefaultsClient(
            boolForKey: { key in lock.withLock { dict[key] as? Bool ?? false } },
            doubleForKey: { key in lock.withLock { dict[key] as? Double ?? 0 } },
            stringForKey: { key in lock.withLock { dict[key] as? String } },
            hasKey: { key in lock.withLock { dict[key] != nil } },
            setBool: { val, key in lock.withLock { dict[key] = val } },
            setDouble: { val, key in lock.withLock { dict[key] = val } },
            setString: { val, key in lock.withLock { dict[key] = val } }
        )
    }

    // MARK: - add

    @Test func addAppendsPreset() async {
        let store = makeStore()
        await store.send(.addLabelPreset(name: "backend", color: .blue)) {
            $0.labelPresets = [LabelPreset(name: "backend", color: .blue)]
        }
    }

    @Test func addNormalizesWhitespace() async {
        let store = makeStore()
        await store.send(.addLabelPreset(name: "  backend  ", color: .green)) {
            $0.labelPresets = [LabelPreset(name: "backend", color: .green)]
        }
    }

    @Test func addRejectsEmptyName() async {
        let store = makeStore()
        await store.send(.addLabelPreset(name: "   ", color: .red))
        #expect(store.state.labelPresets.isEmpty)
    }

    @Test func addRejectsDuplicateName() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .blue)])
        await store.send(.addLabelPreset(name: "backend", color: .red))
        #expect(store.state.labelPresets == [LabelPreset(name: "backend", color: .blue)])
    }

    @Test func addTreatsCaseAsDistinct() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .blue)])
        await store.send(.addLabelPreset(name: "Backend", color: .purple)) {
            $0.labelPresets = [
                LabelPreset(name: "backend", color: .blue),
                LabelPreset(name: "Backend", color: .purple)
            ]
        }
    }

    // MARK: - update

    @Test func updateRenamesAndRecolors() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .blue)])
        await store.send(.updateLabelPreset(id: "backend", name: "api", color: .orange)) {
            $0.labelPresets = [LabelPreset(name: "api", color: .orange)]
        }
    }

    @Test func updateRecolorOnly() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .blue)])
        await store.send(.updateLabelPreset(id: "backend", name: "backend", color: .pink)) {
            $0.labelPresets = [LabelPreset(name: "backend", color: .pink)]
        }
    }

    @Test func updateRecolorOnlyWithSiblingDoesNotSelfCollide() async {
        // A recolor (name unchanged) must not be rejected as a collision
        // just because the row's own name is still present in the list.
        let store = makeStore(labelPresets: [
            LabelPreset(name: "backend", color: .blue),
            LabelPreset(name: "frontend", color: .green)
        ])
        await store.send(.updateLabelPreset(id: "backend", name: "backend", color: .pink)) {
            $0.labelPresets = [
                LabelPreset(name: "backend", color: .pink),
                LabelPreset(name: "frontend", color: .green)
            ]
        }
    }

    @Test func updateNormalizesWhitespace() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .blue)])
        await store.send(.updateLabelPreset(id: "backend", name: "  api  ", color: .orange)) {
            $0.labelPresets = [LabelPreset(name: "api", color: .orange)]
        }
    }

    @Test func updateRejectsEmptyName() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .blue)])
        await store.send(.updateLabelPreset(id: "backend", name: "  ", color: .red))
        #expect(store.state.labelPresets == [LabelPreset(name: "backend", color: .blue)])
    }

    @Test func updateRejectsRenameCollision() async {
        let store = makeStore(labelPresets: [
            LabelPreset(name: "backend", color: .blue),
            LabelPreset(name: "frontend", color: .green)
        ])
        await store.send(.updateLabelPreset(id: "frontend", name: "backend", color: .red))
        #expect(store.state.labelPresets == [
            LabelPreset(name: "backend", color: .blue),
            LabelPreset(name: "frontend", color: .green)
        ])
    }

    @Test func updateUnknownIDIsNoOp() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .blue)])
        await store.send(.updateLabelPreset(id: "ghost", name: "x", color: .red))
        #expect(store.state.labelPresets == [LabelPreset(name: "backend", color: .blue)])
    }

    // MARK: - remove

    @Test func removeDropsPreset() async {
        let store = makeStore(labelPresets: [
            LabelPreset(name: "backend", color: .blue),
            LabelPreset(name: "frontend", color: .green)
        ])
        await store.send(.removeLabelPreset(id: "backend")) {
            $0.labelPresets = [LabelPreset(name: "frontend", color: .green)]
        }
    }

    @Test func removeLeavesAppliedWorkspaceLabelIntact() async {
        let wsID = UUID()
        var ws = WorkspaceFeature.State(id: wsID, name: "WS", color: .blue)
        ws.labels = ["backend"]
        let store = makeStore(
            labelPresets: [LabelPreset(name: "backend", color: .blue)],
            workspaces: [ws]
        )
        await store.send(.removeLabelPreset(id: "backend")) {
            $0.labelPresets = []
        }
        // Presets are a color lookup only; the workspace keeps its label,
        // which now renders in the neutral style.
        #expect(store.state.workspaces[id: wsID]?.labels == ["backend"])
        #expect(store.state.colorForLabel("backend") == nil)
    }

    // MARK: - move

    @Test func moveReorders() async {
        let store = makeStore(labelPresets: [
            LabelPreset(name: "a", color: .red),
            LabelPreset(name: "b", color: .green),
            LabelPreset(name: "c", color: .blue)
        ])
        await store.send(.moveLabelPreset(fromIndex: 0, toIndex: 3)) {
            $0.labelPresets = [
                LabelPreset(name: "b", color: .green),
                LabelPreset(name: "c", color: .blue),
                LabelPreset(name: "a", color: .red)
            ]
        }
    }

    @Test func moveToSameIndexIsNoOp() async {
        let presets = [
            LabelPreset(name: "a", color: .red),
            LabelPreset(name: "b", color: .green)
        ]
        let store = makeStore(labelPresets: presets)
        await store.send(.moveLabelPreset(fromIndex: 1, toIndex: 1))
        #expect(store.state.labelPresets == presets)
    }

    @Test func moveOutOfBoundsIsNoOp() async {
        let presets = [
            LabelPreset(name: "a", color: .red),
            LabelPreset(name: "b", color: .green)
        ]
        let store = makeStore(labelPresets: presets)
        await store.send(.moveLabelPreset(fromIndex: 5, toIndex: 0))
        #expect(store.state.labelPresets == presets)
    }

    // MARK: - load + colorForLabel

    @Test func loadReplacesPresets() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "old", color: .gray)])
        let loaded = [LabelPreset(name: "new", color: .yellow)]
        await store.send(.labelPresetsLoaded(loaded)) {
            $0.labelPresets = loaded
        }
    }

    @Test func colorForLabelMatchesExactCaseSensitive() {
        var state = AppReducer.State()
        state.labelPresets = [LabelPreset(name: "backend", color: .blue)]
        #expect(state.colorForLabel("backend") == .blue)
        #expect(state.colorForLabel("Backend") == nil)
        #expect(state.colorForLabel("missing") == nil)
    }

    // MARK: - storage round-trip

    @Test func storageRoundTrips() {
        let presets = [
            LabelPreset(name: "backend", color: .blue),
            LabelPreset(name: "urgent", color: .red)
        ]
        let json = LabelPresetsStorage.encode(presets)
        #expect(LabelPresetsStorage.decode(json) == presets)
    }

    @Test func storageDecodesEmptyAndGarbage() {
        #expect(LabelPresetsStorage.decode(nil).isEmpty)
        #expect(LabelPresetsStorage.decode("").isEmpty)
        #expect(LabelPresetsStorage.decode("not json").isEmpty)
    }
}
