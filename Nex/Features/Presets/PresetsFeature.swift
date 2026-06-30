import ComposableArchitecture
import Foundation
import SwiftUI // Array.move(fromOffsets:toOffset:) is a SwiftUI extension

/// Child reducer owning the two flat, UserDefaults-backed preset lists that
/// no other domain writes: web favourites and workspace label presets.
/// Extracted from `AppReducer` as a pure structural move -- behavior is
/// identical.
///
/// The one-time label→preset migration stays coordinated by `AppReducer`:
/// it owns the gate (workspaces + `didRestoreWorkspaces` + the migrated
/// flag) and passes the collected labels into this reducer via
/// `applyMigratedLabels`. This reducer signals "presets finished loading"
/// back to core via `.delegate(.didLoadLabelPresets)` so core can run the
/// gate.
@Reducer
struct PresetsFeature {
    @ObservableState
    struct State: Equatable {
        var favourites: [Favourite] = []

        /// User-defined workspace label presets (name + color). A flat
        /// global list, persisted in UserDefaults like `favourites`. Used
        /// to offer canned labels in the inspector and to tint chips whose
        /// text matches a preset name.
        var labelPresets: [LabelPreset] = []

        /// One half of the one-time label→preset migration gate (the other,
        /// `didRestoreWorkspaces`, stays in `AppReducer.State`). Set once the
        /// (UserDefaults) presets have loaded; core's gate also requires the
        /// workspaces to have restored before it back-fills.
        var didLoadLabelPresets = false

        /// Color for a workspace label string, or nil when no preset
        /// matches (chip renders in the neutral free-form style). Match is
        /// exact and case-sensitive, mirroring how `addLabel` stores
        /// labels (trim/clamp only, no lowercasing).
        func colorForLabel(_ label: String) -> LabelColor? {
            labelPresets.color(for: label)
        }
    }

    enum Action: Equatable {
        // MARK: - Web favourites

        case favouritesLoaded([Favourite])
        case removeFavourite(id: UUID)
        case renameFavourite(id: UUID, title: String)
        case moveFavourite(fromIndex: Int, toIndex: Int)
        /// Star toggle: add when missing, remove when present.
        /// URL match is case-insensitive with trailing-slash stripped.
        case toggleFavourite(url: String, title: String)

        // MARK: - Label presets

        case labelPresetsLoaded([LabelPreset])
        /// Back-fill a preset (default colour) for every passed-in workspace
        /// label that predates the presets feature, so they survive being
        /// unapplied. Core's `migrateLabelsToPresets` gate decides whether to
        /// fire this and which labels to pass; the dedup against the existing
        /// presets happens here, against this reducer's own `labelPresets`.
        case applyMigratedLabels(labels: [String])
        /// Add a preset. Name is normalized (trim/clamp); empty or a
        /// case-sensitive duplicate name is ignored.
        case addLabelPreset(name: String, color: LabelColor)
        /// Edit a preset addressed by its current name. Renaming to
        /// collide with another preset's name is ignored.
        case updateLabelPreset(id: String, name: String, color: LabelColor)
        /// Set (or clear, with nil = auto black/white) a preset's text colour.
        case setLabelPresetTextColor(id: String, textColor: LabelColor?)
        case removeLabelPreset(id: String)
        case moveLabelPreset(fromIndex: Int, toIndex: Int)

        case delegate(Delegate)

        /// Cross-domain signals consumed by `AppReducer`.
        enum Delegate: Equatable {
            /// Emitted after `labelPresetsLoaded` lands the presets + flag so
            /// core can run the one-time migration gate.
            case didLoadLabelPresets
        }
    }

    @Dependency(\.userDefaults) var userDefaults
    @Dependency(\.uuid) var uuid

    private func persistFavourites(_ favourites: [Favourite]) -> Effect<Action> {
        let json = FavouritesStorage.encode(favourites)
        return .run { [userDefaults] _ in
            userDefaults.setString(json, FavouritesStorage.defaultsKey)
        }
    }

    private func persistLabelPresets(_ presets: [LabelPreset]) -> Effect<Action> {
        // Write immediately (like favourites) rather than debouncing: a
        // debounce would drop a preset add/remove/rename made within the
        // window of a Cmd-Q (the effect is cancelled on terminate). The
        // colour-picker drag that motivated a debounce only produces cheap,
        // off-main, cfprefsd-coalesced UserDefaults writes anyway.
        let json = LabelPresetsStorage.encode(presets)
        return .run { [userDefaults] _ in
            userDefaults.setString(json, LabelPresetsStorage.defaultsKey)
        }
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            // MARK: - Web favourites

            case .favouritesLoaded(let list):
                state.favourites = list
                return .none

            case .removeFavourite(let id):
                guard let idx = state.favourites.firstIndex(where: { $0.id == id })
                else { return .none }
                state.favourites.remove(at: idx)
                return persistFavourites(state.favourites)

            case .renameFavourite(let id, let title):
                guard let idx = state.favourites.firstIndex(where: { $0.id == id })
                else { return .none }
                state.favourites[idx].title = title
                return persistFavourites(state.favourites)

            case .moveFavourite(let from, let to):
                guard from >= 0, from < state.favourites.count,
                      to >= 0, to <= state.favourites.count, from != to
                else { return .none }
                state.favourites.move(fromOffsets: IndexSet(integer: from), toOffset: to)
                return persistFavourites(state.favourites)

            case .toggleFavourite(let url, let title):
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }
                if let existing = state.favourites.firstMatching(url: trimmed) {
                    state.favourites.removeAll { $0.id == existing.id }
                } else {
                    state.favourites.append(Favourite(id: uuid(), url: trimmed, title: title))
                }
                return persistFavourites(state.favourites)

            // MARK: - Label presets

            case .labelPresetsLoaded(let list):
                state.labelPresets = list
                state.didLoadLabelPresets = true
                return .send(.delegate(.didLoadLabelPresets))

            case .applyMigratedLabels(let labels):
                // Dedup against the presets this reducer already owns (a label
                // that's already a preset is left untouched), and against
                // itself so a label passed twice is added once.
                var seen = Set(state.labelPresets.map(\.name))
                var added: [LabelPreset] = []
                for label in labels where !seen.contains(label) {
                    seen.insert(label)
                    // Default colour; the user can recolour it in Settings.
                    added.append(LabelPreset(name: label, color: .named(.gray)))
                }
                state.labelPresets.append(contentsOf: added)
                return persistLabelPresets(state.labelPresets)

            case .addLabelPreset(let name, let color):
                let normalized = WorkspaceFeature.normalizeLabel(name)
                guard !normalized.isEmpty,
                      !state.labelPresets.contains(where: { $0.name == normalized })
                else { return .none }
                state.labelPresets.append(LabelPreset(name: normalized, color: color))
                return persistLabelPresets(state.labelPresets)

            case .updateLabelPreset(let id, let name, let color):
                guard let idx = state.labelPresets.firstIndex(where: { $0.id == id })
                else { return .none }
                let normalized = WorkspaceFeature.normalizeLabel(name)
                guard !normalized.isEmpty else { return .none }
                // Reject a rename that collides with a *different* preset.
                // Excluding the edited row by id means a recolor or a
                // whitespace-only edit of the same row is never a
                // self-collision.
                if state.labelPresets.contains(where: { $0.id != id && $0.name == normalized }) {
                    return .none
                }
                state.labelPresets[idx].name = normalized
                state.labelPresets[idx].color = color
                return persistLabelPresets(state.labelPresets)

            case .setLabelPresetTextColor(let id, let textColor):
                guard let idx = state.labelPresets.firstIndex(where: { $0.id == id })
                else { return .none }
                state.labelPresets[idx].textColor = textColor
                return persistLabelPresets(state.labelPresets)

            case .removeLabelPreset(let id):
                guard let idx = state.labelPresets.firstIndex(where: { $0.id == id })
                else { return .none }
                state.labelPresets.remove(at: idx)
                return persistLabelPresets(state.labelPresets)

            case .moveLabelPreset(let from, let to):
                guard from >= 0, from < state.labelPresets.count,
                      to >= 0, to <= state.labelPresets.count, from != to
                else { return .none }
                state.labelPresets.move(fromOffsets: IndexSet(integer: from), toOffset: to)
                return persistLabelPresets(state.labelPresets)

            case .delegate:
                return .none
            }
        }
    }
}
