import ComposableArchitecture
import SwiftUI

/// Settings tab for defining workspace label presets (name + color).
/// Picking a preset in the workspace inspector adds its name as a label;
/// chips whose text matches a preset name render in the preset's color.
struct LabelPresetsSettingsView: View {
    let store: StoreOf<AppReducer>

    @State private var newName = ""
    @State private var newColor: WorkspaceColor = .blue

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if store.labelPresets.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.labelPresets) { preset in
                            LabelPresetRow(
                                preset: preset,
                                isNameAvailable: { candidate in
                                    // Mirror the reducer's guard so a doomed
                                    // rename isn't dispatched and the field
                                    // can restore instead of showing a value
                                    // that was silently rejected.
                                    candidate == preset.name
                                        || !store.labelPresets.contains { $0.name == candidate }
                                },
                                onRename: { newName in
                                    store.send(.updateLabelPreset(
                                        id: preset.id,
                                        name: newName,
                                        color: preset.color
                                    ))
                                },
                                onRecolor: { color in
                                    store.send(.updateLabelPreset(
                                        id: preset.id,
                                        name: preset.name,
                                        color: color
                                    ))
                                },
                                onRemove: {
                                    store.send(.removeLabelPreset(id: preset.id))
                                }
                            )
                            .tag(preset.id)
                        }
                        .onMove { source, destination in
                            guard let from = source.first else { return }
                            store.send(.moveLabelPreset(fromIndex: from, toIndex: destination))
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }

                Divider()

                addRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No label presets yet")
                .foregroundStyle(.secondary)
            Text("Define reusable labels with colors, then pick them in a workspace's inspector.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            ColorSwatchMenu(selection: $newColor)

            TextField("New label name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(commitNew)

            Button("Add", action: commitNew)
                .disabled(trimmedNewName.isEmpty)
        }
        .padding(12)
    }

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNew() {
        guard !trimmedNewName.isEmpty else { return }
        store.send(.addLabelPreset(name: trimmedNewName, color: newColor))
        newName = ""
    }
}

/// One editable preset row: a color menu, an inline-renamable name, and a
/// delete button. Rename commits on submit or focus loss (like the web
/// favourites rows).
private struct LabelPresetRow: View {
    let preset: LabelPreset
    /// True when `candidate` could be committed as this row's name (it
    /// equals the current name, or no other preset already uses it).
    let isNameAvailable: (String) -> Bool
    let onRename: (String) -> Void
    let onRecolor: (WorkspaceColor) -> Void
    let onRemove: () -> Void

    @State private var editingName: String
    @State private var color: WorkspaceColor
    @FocusState private var isFocused: Bool

    init(
        preset: LabelPreset,
        isNameAvailable: @escaping (String) -> Bool,
        onRename: @escaping (String) -> Void,
        onRecolor: @escaping (WorkspaceColor) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.preset = preset
        self.isNameAvailable = isNameAvailable
        self.onRename = onRename
        self.onRecolor = onRecolor
        self.onRemove = onRemove
        _editingName = State(initialValue: preset.name)
        _color = State(initialValue: preset.color)
    }

    var body: some View {
        HStack(spacing: 8) {
            ColorSwatchMenu(selection: Binding(
                get: { color },
                set: { newColor in
                    color = newColor
                    onRecolor(newColor)
                }
            ))

            TextField("Label name", text: $editingName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .medium))
                .focused($isFocused)
                .onSubmit(commitRename)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitRename() }
                }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove preset")
        }
        .padding(.vertical, 2)
        // Keep the local editors in sync if the store rewrites this row
        // (e.g. a rejected rename collision leaves the stored name intact).
        .onChange(of: preset.name) { _, newValue in
            if !isFocused { editingName = newValue }
        }
        .onChange(of: preset.color) { _, newValue in
            color = newValue
        }
    }

    private func commitRename() {
        // Normalize the same way the reducer does so the availability
        // check and the dispatched value agree.
        let normalized = WorkspaceFeature.normalizeLabel(editingName)
        // No-op, empty, or a name another preset already uses: the
        // reducer would reject it, so restore the field to the stored
        // name rather than leaving the rejected text on screen.
        guard !normalized.isEmpty,
              normalized != preset.name,
              isNameAvailable(normalized)
        else {
            editingName = preset.name
            return
        }
        onRename(normalized)
    }
}

/// A small color picker shown as a swatch that opens a menu of the eight
/// workspace colors. Reused by the add row and each preset row.
private struct ColorSwatchMenu: View {
    @Binding var selection: WorkspaceColor

    var body: some View {
        Menu {
            ForEach(WorkspaceColor.allCases) { c in
                Button {
                    selection = c
                } label: {
                    Label {
                        Text(c.displayName)
                    } icon: {
                        Image(systemName: selection == c ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(c.color)
                    }
                }
            }
        } label: {
            Circle()
                .fill(selection.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a color")
        .accessibilityLabel("Color: \(selection.displayName)")
    }
}
