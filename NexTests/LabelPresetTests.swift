import Clocks
import ComposableArchitecture
import Foundation
@testable import Nex
import SwiftUI
import Testing

@MainActor
struct LabelPresetTests {
    private func makeStore(
        labelPresets: [LabelPreset] = [],
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = []
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.presets.labelPresets = labelPresets
        appState.workspaces = workspaces

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            // Immediate clock so the debounced persist effect completes.
            $0.continuousClock = ImmediateClock()
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
        await store.send(.presets(.addLabelPreset(name: "backend", color: .named(.blue)))) {
            $0.presets.labelPresets = [LabelPreset(name: "backend", color: .named(.blue))]
        }
    }

    @Test func addCustomColorPreset() async {
        let store = makeStore()
        await store.send(.presets(.addLabelPreset(name: "brand", color: .custom("#123456")))) {
            $0.presets.labelPresets = [LabelPreset(name: "brand", color: .custom("#123456"))]
        }
    }

    @Test func addNormalizesWhitespace() async {
        let store = makeStore()
        await store.send(.presets(.addLabelPreset(name: "  backend  ", color: .named(.green)))) {
            $0.presets.labelPresets = [LabelPreset(name: "backend", color: .named(.green))]
        }
    }

    @Test func addRejectsEmptyName() async {
        let store = makeStore()
        await store.send(.presets(.addLabelPreset(name: "   ", color: .named(.red))))
        #expect(store.state.presets.labelPresets.isEmpty)
    }

    @Test func addRejectsDuplicateName() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.addLabelPreset(name: "backend", color: .named(.red))))
        #expect(store.state.presets.labelPresets == [LabelPreset(name: "backend", color: .named(.blue))])
    }

    @Test func addTreatsCaseAsDistinct() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.addLabelPreset(name: "Backend", color: .named(.purple)))) {
            $0.presets.labelPresets = [
                LabelPreset(name: "backend", color: .named(.blue)),
                LabelPreset(name: "Backend", color: .named(.purple))
            ]
        }
    }

    // MARK: - update

    @Test func updateRenamesAndRecolors() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.updateLabelPreset(id: "backend", name: "api", color: .named(.orange)))) {
            $0.presets.labelPresets = [LabelPreset(name: "api", color: .named(.orange))]
        }
    }

    @Test func updateRecolorOnly() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.updateLabelPreset(id: "backend", name: "backend", color: .custom("#abcdef")))) {
            $0.presets.labelPresets = [LabelPreset(name: "backend", color: .custom("#abcdef"))]
        }
    }

    @Test func updateRecolorOnlyWithSiblingDoesNotSelfCollide() async {
        // A recolor (name unchanged) must not be rejected as a collision
        // just because the row's own name is still present in the list.
        let store = makeStore(labelPresets: [
            LabelPreset(name: "backend", color: .named(.blue)),
            LabelPreset(name: "frontend", color: .named(.green))
        ])
        await store.send(.presets(.updateLabelPreset(id: "backend", name: "backend", color: .named(.pink)))) {
            $0.presets.labelPresets = [
                LabelPreset(name: "backend", color: .named(.pink)),
                LabelPreset(name: "frontend", color: .named(.green))
            ]
        }
    }

    @Test func updateNormalizesWhitespace() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.updateLabelPreset(id: "backend", name: "  api  ", color: .named(.orange)))) {
            $0.presets.labelPresets = [LabelPreset(name: "api", color: .named(.orange))]
        }
    }

    @Test func updateRejectsEmptyName() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.updateLabelPreset(id: "backend", name: "  ", color: .named(.red))))
        #expect(store.state.presets.labelPresets == [LabelPreset(name: "backend", color: .named(.blue))])
    }

    @Test func updateRejectsRenameCollision() async {
        let store = makeStore(labelPresets: [
            LabelPreset(name: "backend", color: .named(.blue)),
            LabelPreset(name: "frontend", color: .named(.green))
        ])
        await store.send(.presets(.updateLabelPreset(id: "frontend", name: "backend", color: .named(.red))))
        #expect(store.state.presets.labelPresets == [
            LabelPreset(name: "backend", color: .named(.blue)),
            LabelPreset(name: "frontend", color: .named(.green))
        ])
    }

    @Test func updateUnknownIDIsNoOp() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.updateLabelPreset(id: "ghost", name: "x", color: .named(.red))))
        #expect(store.state.presets.labelPresets == [LabelPreset(name: "backend", color: .named(.blue))])
    }

    // MARK: - remove

    // MARK: - text colour

    @Test func setTextColorUpdatesAndClears() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.setLabelPresetTextColor(id: "backend", textColor: .custom("#ffffff")))) {
            $0.presets.labelPresets = [LabelPreset(name: "backend", color: .named(.blue), textColor: .custom("#ffffff"))]
        }
        await store.send(.presets(.setLabelPresetTextColor(id: "backend", textColor: nil))) {
            $0.presets.labelPresets = [LabelPreset(name: "backend", color: .named(.blue), textColor: nil)]
        }
    }

    @Test func setTextColorUnknownIDIsNoOp() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "backend", color: .named(.blue))])
        await store.send(.presets(.setLabelPresetTextColor(id: "ghost", textColor: .custom("#ffffff"))))
        #expect(store.state.presets.labelPresets == [LabelPreset(name: "backend", color: .named(.blue))])
    }

    @Test func resolvedStyleUsesAutoOrExplicitText() {
        // Auto: a dark background resolves to white text.
        #expect(LabelPreset(name: "a", color: .named(.blue)).resolvedStyle.text == .white)
        // An explicit text colour overrides the auto choice.
        let explicit = LabelPreset(name: "b", color: .named(.blue), textColor: .custom("#000000"))
        #expect(explicit.resolvedStyle.text == Color(hex: "#000000"))
    }

    @Test func removeDropsPreset() async {
        let store = makeStore(labelPresets: [
            LabelPreset(name: "backend", color: .named(.blue)),
            LabelPreset(name: "frontend", color: .named(.green))
        ])
        await store.send(.presets(.removeLabelPreset(id: "backend"))) {
            $0.presets.labelPresets = [LabelPreset(name: "frontend", color: .named(.green))]
        }
    }

    @Test func removeLeavesAppliedWorkspaceLabelIntact() async {
        let wsID = UUID()
        var ws = WorkspaceFeature.State(id: wsID, name: "WS", color: .blue)
        ws.labels = ["backend"]
        let store = makeStore(
            labelPresets: [LabelPreset(name: "backend", color: .named(.blue))],
            workspaces: [ws]
        )
        await store.send(.presets(.removeLabelPreset(id: "backend"))) {
            $0.presets.labelPresets = []
        }
        // Presets are a colour lookup only; the workspace keeps its label,
        // which now renders in the neutral style.
        #expect(store.state.workspaces[id: wsID]?.labels == ["backend"])
        #expect(store.state.presets.colorForLabel("backend") == nil)
    }

    // MARK: - move

    @Test func moveReorders() async {
        let store = makeStore(labelPresets: [
            LabelPreset(name: "a", color: .named(.red)),
            LabelPreset(name: "b", color: .named(.green)),
            LabelPreset(name: "c", color: .named(.blue))
        ])
        await store.send(.presets(.moveLabelPreset(fromIndex: 0, toIndex: 3))) {
            $0.presets.labelPresets = [
                LabelPreset(name: "b", color: .named(.green)),
                LabelPreset(name: "c", color: .named(.blue)),
                LabelPreset(name: "a", color: .named(.red))
            ]
        }
    }

    @Test func moveToSameIndexIsNoOp() async {
        let presets = [
            LabelPreset(name: "a", color: .named(.red)),
            LabelPreset(name: "b", color: .named(.green))
        ]
        let store = makeStore(labelPresets: presets)
        await store.send(.presets(.moveLabelPreset(fromIndex: 1, toIndex: 1)))
        #expect(store.state.presets.labelPresets == presets)
    }

    @Test func moveOutOfBoundsIsNoOp() async {
        let presets = [
            LabelPreset(name: "a", color: .named(.red)),
            LabelPreset(name: "b", color: .named(.green))
        ]
        let store = makeStore(labelPresets: presets)
        await store.send(.presets(.moveLabelPreset(fromIndex: 5, toIndex: 0)))
        #expect(store.state.presets.labelPresets == presets)
    }

    // MARK: - load + colorForLabel

    @Test func loadReplacesPresets() async {
        let store = makeStore(labelPresets: [LabelPreset(name: "old", color: .named(.gray))])
        let loaded = [LabelPreset(name: "new", color: .named(.yellow))]
        await store.send(.presets(.labelPresetsLoaded(loaded))) {
            $0.presets.labelPresets = loaded
        }
    }

    @Test func colorForLabelMatchesExactCaseSensitive() {
        var state = AppReducer.State()
        state.presets.labelPresets = [LabelPreset(name: "backend", color: .named(.blue))]
        #expect(state.presets.colorForLabel("backend") == .named(.blue))
        #expect(state.presets.colorForLabel("Backend") == nil)
        #expect(state.presets.colorForLabel("missing") == nil)
    }

    // MARK: - storage round-trip + LabelColor

    @Test func storageRoundTrips() {
        let presets = [
            LabelPreset(name: "backend", color: .named(.blue)),
            LabelPreset(name: "brand", color: .custom("#ff8800"))
        ]
        let json = LabelPresetsStorage.encode(presets)
        #expect(LabelPresetsStorage.decode(json) == presets)
    }

    @Test func storageDecodesEmptyAndGarbage() {
        #expect(LabelPresetsStorage.decode(nil).isEmpty)
        #expect(LabelPresetsStorage.decode("").isEmpty)
        #expect(LabelPresetsStorage.decode("not json").isEmpty)
    }

    @Test func storageDecodesLegacyNamedColorString() {
        // Pre-custom data stored color as a bare WorkspaceColor raw value,
        // and pre-textColor data has no textColor key (decodes to nil).
        let json = #"[{"name":"old","color":"green"}]"#
        #expect(LabelPresetsStorage.decode(json) == [LabelPreset(name: "old", color: .named(.green))])
    }

    @Test func storageRoundTripsTextColor() {
        let presets = [LabelPreset(name: "x", color: .named(.blue), textColor: .custom("#ffffff"))]
        let json = LabelPresetsStorage.encode(presets)
        #expect(LabelPresetsStorage.decode(json) == presets)
    }

    // MARK: - reducer -> UserDefaults persistence (full effect path)

    @Test func mutationsPersistThroughTheEffect() async {
        // Exercises the real persistLabelPresets effect end to end: a
        // mutation must land in UserDefaults under the storage key.
        let lock = NSLock()
        nonisolated(unsafe) var dict: [String: Any] = [:]
        let defaults = UserDefaultsClient(
            boolForKey: { key in lock.withLock { dict[key] as? Bool ?? false } },
            doubleForKey: { key in lock.withLock { dict[key] as? Double ?? 0 } },
            stringForKey: { key in lock.withLock { dict[key] as? String } },
            hasKey: { key in lock.withLock { dict[key] != nil } },
            setBool: { val, key in lock.withLock { dict[key] = val } },
            setDouble: { val, key in lock.withLock { dict[key] = val } },
            setString: { val, key in lock.withLock { dict[key] = val } }
        )
        let store = TestStore(initialState: AppReducer.State()) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.continuousClock = ImmediateClock()
            $0.userDefaults = defaults
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.presets(.addLabelPreset(name: "backend", color: .named(.blue))))
        await store.send(.presets(.setLabelPresetTextColor(id: "backend", textColor: .custom("#ffffff"))))
        await store.finish()

        let json = lock.withLock { dict[LabelPresetsStorage.defaultsKey] as? String }
        #expect(LabelPresetsStorage.decode(json) == [
            LabelPreset(name: "backend", color: .named(.blue), textColor: .custom("#ffffff"))
        ])
    }

    @Test func labelColorNamedResolvesToWorkspaceColor() {
        #expect(LabelColor.named(.blue).color == WorkspaceColor.blue.color)
        #expect(LabelColor.named(.red).namedColor == .red)
        #expect(LabelColor.custom("#ff8800").namedColor == nil)
    }

    @Test func colorHexParsesAndRoundTrips() {
        #expect(Color(hex: "#ff8800") != nil)
        #expect(Color(hex: "ff8800") != nil)
        #expect(Color(hex: "nonsense") == nil)
        #expect(Color(hex: "#12345") == nil)
        #expect(Color(hex: "+f8800") == nil)
        #expect(Color(hex: "#gggggg") == nil)
        #expect(Color(hex: "#ff8800")?.hexString == "#ff8800")
    }

    @Test func labelColorCustomCodableRoundTrips() throws {
        let original = LabelColor.custom("#0a1b2c")
        let data = try JSONEncoder().encode(original)
        #expect(String(data: data, encoding: .utf8) == "\"#0a1b2c\"")
        #expect(try JSONDecoder().decode(LabelColor.self, from: data) == original)
    }

    @Test func labelColorNamedHexIsValidRRGGBB() {
        // Drives the named->custom "Custom…" seeding: must be a real hex,
        // not a gray/black fallback.
        let hex = LabelColor.named(.red).hex
        #expect(hex.hasPrefix("#"))
        #expect(hex.count == 7)
        #expect(Color(hex: hex) != nil)
    }

    @Test func contrastingTextPicksReadableColor() {
        #expect(Color(hex: "#ffffff")?.contrastingText == .black)
        #expect(Color(hex: "#000000")?.contrastingText == .white)
        #expect(WorkspaceColor.yellow.color.contrastingText == .black)
        #expect(WorkspaceColor.blue.color.contrastingText == .white)
    }
}
