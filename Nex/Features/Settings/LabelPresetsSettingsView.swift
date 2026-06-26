import ComposableArchitecture
import SwiftUI

/// Fixed column widths so the preview, colour dropdown, and action button
/// line up vertically across the add row and every preset row regardless
/// of name length or selected colour. The name field flexes to fill the
/// gap, keeping the trailing columns at a constant offset.
private enum LabelCol {
    static let preview: CGFloat = 96
    static let color: CGFloat = 150
    static let action: CGFloat = 56
}

/// Settings tab for defining workspace label presets (name + colour).
/// Picking a preset in the workspace inspector adds its name as a label;
/// chips whose text matches a preset name render in the preset's colour.
struct LabelPresetsSettingsView: View {
    let store: StoreOf<AppReducer>

    @State private var newName = ""
    @State private var newColor: LabelColor = .named(.blue)

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                addRow

                Divider()

                if store.labelPresets.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.labelPresets) { preset in
                            LabelPresetRow(
                                preset: preset,
                                isNameAvailable: { candidate in
                                    candidate == preset.name
                                        || !store.labelPresets.contains { $0.name == candidate }
                                },
                                onRename: { name in
                                    store.send(.updateLabelPreset(
                                        id: preset.id,
                                        name: name,
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
            Text("Define reusable labels with colours, then pick them in a workspace's inspector.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            LabelChip(text: trimmedNewName.isEmpty ? "label" : trimmedNewName, tint: newColor.color)
                .opacity(trimmedNewName.isEmpty ? 0.5 : 1)
                .frame(width: LabelCol.preview, alignment: .leading)

            TextField("New label name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .onSubmit(commitNew)

            LabelColorField(color: $newColor)

            Button("Add", action: commitNew)
                .frame(width: LabelCol.action, alignment: .trailing)
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

/// One editable preset row: a live chip preview, an inline-renamable name,
/// a colour dropdown, and a delete button. Rename commits on submit or
/// focus loss (like the web favourites rows).
private struct LabelPresetRow: View {
    let preset: LabelPreset
    /// True when `candidate` could be committed as this row's name (it
    /// equals the current name, or no other preset already uses it).
    let isNameAvailable: (String) -> Bool
    let onRename: (String) -> Void
    let onRecolor: (LabelColor) -> Void
    let onRemove: () -> Void

    @State private var editingName: String
    @State private var color: LabelColor
    @FocusState private var isFocused: Bool

    init(
        preset: LabelPreset,
        isNameAvailable: @escaping (String) -> Bool,
        onRename: @escaping (String) -> Void,
        onRecolor: @escaping (LabelColor) -> Void,
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

    private var previewText: String {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? preset.name : trimmed
    }

    var body: some View {
        HStack(spacing: 10) {
            LabelChip(text: previewText, tint: color.color)
                .frame(width: LabelCol.preview, alignment: .leading)

            TextField("Label name", text: $editingName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .focused($isFocused)
                .onSubmit(commitRename)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitRename() }
                }

            LabelColorField(color: Binding(
                get: { color },
                set: { newColor in
                    color = newColor
                    onRecolor(newColor)
                }
            ))

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: LabelCol.action, alignment: .trailing)
            .help("Remove preset")
        }
        .padding(.vertical, 3)
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

/// Colour selector for a label preset: a dropdown of the eight named
/// workspace colours plus a "Custom…" entry. When the colour is custom, a
/// system colour well appears next to the dropdown for fine-tuning.
private struct LabelColorField: View {
    @Binding var color: LabelColor

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(WorkspaceColor.allCases) { workspaceColor in
                    Button {
                        color = .named(workspaceColor)
                    } label: {
                        Label {
                            Text(workspaceColor.displayName)
                        } icon: {
                            workspaceColor.color.menuSwatch(checked: color.namedColor == workspaceColor)
                        }
                    }
                }
                Divider()
                Button {
                    // Switch to custom, seeded from the current colour so
                    // the well opens on something sensible.
                    color = .custom(color.hex)
                } label: {
                    if color.namedColor == nil {
                        Label { Text("Custom\u{2026}") } icon: {
                            color.color.menuSwatch(checked: true)
                        }
                    } else {
                        Label("Custom\u{2026}", systemImage: "eyedropper")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(color.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                    Text(color.namedColor?.displayName ?? "Custom")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Colour: \(color.namedColor?.displayName ?? "Custom")")

            if color.namedColor == nil {
                ColorPicker("", selection: customBinding, supportsOpacity: false)
                    .labelsHidden()
                    .help("Pick a custom colour")
            }

            Spacer(minLength: 0)
        }
        .frame(width: LabelCol.color, alignment: .leading)
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { color.color },
            set: { color = .custom($0.hexString) }
        )
    }
}
