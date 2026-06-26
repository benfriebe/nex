import ComposableArchitecture
import SwiftUI

/// Fixed column widths so the colour controls, text-colour control, and
/// preview line up vertically across the add row and every preset row. The
/// name field flexes to fill the gap, keeping trailing columns aligned.
private enum LabelCol {
    static let bgColor: CGFloat = 150
    static let textColor: CGFloat = 124
    static let preview: CGFloat = 80
    static let action: CGFloat = 40
}

/// Settings tab for defining workspace label presets (name + colour + text
/// colour). Picking a preset from a workspace's context menu adds its name
/// as a label; chips whose text matches a preset render in its colours.
struct LabelPresetsSettingsView: View {
    let store: StoreOf<AppReducer>

    @Environment(\.chromeTheme) private var chromeTheme
    @State private var newName = ""
    @State private var newColor: LabelColor = .named(.blue)
    @State private var newTextColor: LabelColor?

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
                                onSetTextColor: { textColor in
                                    store.send(.setLabelPresetTextColor(
                                        id: preset.id,
                                        textColor: textColor
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
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(chromeTheme.surfaceBackground)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No label presets yet")
                .foregroundStyle(.secondary)
            Text("Define reusable labels with colours, then assign them from a workspace's right-click menu.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newStyle: ResolvedLabelStyle {
        ResolvedLabelStyle(
            background: newColor.color,
            text: newTextColor?.color ?? newColor.color.contrastingText
        )
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            LabelColorField(color: $newColor)

            TextField("New label name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .onSubmit(commitNew)

            LabelTextColorField(textColor: $newTextColor, background: newColor.color)

            LabelChip(text: trimmedNewName.isEmpty ? "label" : trimmedNewName, style: newStyle)
                .opacity(trimmedNewName.isEmpty ? 0.5 : 1)
                .frame(width: LabelCol.preview, alignment: .leading)

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
        let normalized = WorkspaceFeature.normalizeLabel(trimmedNewName)
        // Only set the text colour when the add will actually create a new
        // preset — otherwise the addLabelPreset no-ops on a duplicate name
        // but setLabelPresetTextColor would still recolour the *existing*
        // preset with this id.
        let isNew = !store.labelPresets.contains { $0.name == normalized }
        store.send(.addLabelPreset(name: trimmedNewName, color: newColor))
        if isNew, let textColor = newTextColor {
            store.send(.setLabelPresetTextColor(id: normalized, textColor: textColor))
        }
        newName = ""
        newTextColor = nil
    }
}

/// One editable preset row: background-colour control, an inline-renamable
/// name, a text-colour control, a live chip preview, and a delete button.
/// Rename commits on submit or focus loss (like the web favourites rows).
private struct LabelPresetRow: View {
    let preset: LabelPreset
    /// True when `candidate` could be committed as this row's name (it
    /// equals the current name, or no other preset already uses it).
    let isNameAvailable: (String) -> Bool
    let onRename: (String) -> Void
    let onRecolor: (LabelColor) -> Void
    let onSetTextColor: (LabelColor?) -> Void
    let onRemove: () -> Void

    @State private var editingName: String
    @State private var color: LabelColor
    @State private var textColor: LabelColor?
    @FocusState private var isFocused: Bool

    init(
        preset: LabelPreset,
        isNameAvailable: @escaping (String) -> Bool,
        onRename: @escaping (String) -> Void,
        onRecolor: @escaping (LabelColor) -> Void,
        onSetTextColor: @escaping (LabelColor?) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.preset = preset
        self.isNameAvailable = isNameAvailable
        self.onRename = onRename
        self.onRecolor = onRecolor
        self.onSetTextColor = onSetTextColor
        self.onRemove = onRemove
        _editingName = State(initialValue: preset.name)
        _color = State(initialValue: preset.color)
        _textColor = State(initialValue: preset.textColor)
    }

    private var previewText: String {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? preset.name : trimmed
    }

    private var previewStyle: ResolvedLabelStyle {
        ResolvedLabelStyle(
            background: color.color,
            text: textColor?.color ?? color.color.contrastingText
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            LabelColorField(color: Binding(
                get: { color },
                set: { newColor in
                    color = newColor
                    onRecolor(newColor)
                }
            ))

            TextField("Label name", text: $editingName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .focused($isFocused)
                .onSubmit(commitRename)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitRename() }
                }

            LabelTextColorField(
                textColor: Binding(
                    get: { textColor },
                    set: { newValue in
                        textColor = newValue
                        onSetTextColor(newValue)
                    }
                ),
                background: color.color
            )

            LabelChip(text: previewText, style: previewStyle)
                .frame(width: LabelCol.preview, alignment: .leading)

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
        .onChange(of: preset.textColor) { _, newValue in
            textColor = newValue
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

/// Background-colour selector: a dropdown of the eight named workspace
/// colours plus a "Custom…" entry, and an always-visible system colour
/// well (the colour "pill") for picking/fine-tuning any colour.
private struct LabelColorField: View {
    @Binding var color: LabelColor

    var body: some View {
        HStack(spacing: 6) {
            // Well first (leftmost) so the wells line up in a column across
            // every row regardless of the colour name's width. Adjusting it
            // makes the colour custom; named quick-picks stay in the menu.
            ColorPicker("", selection: customBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Pick a custom colour")

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
                HStack(spacing: 4) {
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

            Spacer(minLength: 0)
        }
        .frame(width: LabelCol.bgColor, alignment: .leading)
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { color.color },
            set: { color = .custom($0.hexString) }
        )
    }
}

/// Text-colour selector for a label preset: Auto (black/white by contrast),
/// Black, White, or a custom colour. The "Aa" chip previews the chosen text
/// colour on the label's background so legibility is obvious.
private struct LabelTextColorField: View {
    @Binding var textColor: LabelColor?
    let background: Color

    private static let black = "#000000"
    private static let white = "#ffffff"

    var body: some View {
        HStack(spacing: 6) {
            // Well first (leftmost), seeded from the resolved text colour
            // (the auto black/white on Auto) so the wells line up in a column
            // and a custom pick starts readable, not a dim grey. Dragging it
            // switches to a custom colour.
            ColorPicker("", selection: resolvedBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Pick a text colour")

            Menu {
                Button { textColor = nil } label: {
                    Label("Auto", systemImage: textColor == nil ? "checkmark" : "textformat")
                }
                Button { textColor = .custom(Self.black) } label: {
                    Label { Text("Black") } icon: {
                        Color.black.menuSwatch(checked: isHex(Self.black))
                    }
                }
                Button { textColor = .custom(Self.white) } label: {
                    Label { Text("White") } icon: {
                        Color.white.menuSwatch(checked: isHex(Self.white))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Aa")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(textColor?.color ?? background.contrastingText)
                    Text(currentLabel)
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
            .accessibilityLabel("Text colour: \(currentLabel)")

            Spacer(minLength: 0)
        }
        .frame(width: LabelCol.textColor, alignment: .leading)
    }

    private var currentLabel: String {
        guard let textColor else { return "Auto" }
        switch textColor.hex.lowercased() {
        case Self.black: return "Black"
        case Self.white: return "White"
        default: return "Custom"
        }
    }

    private func isHex(_ hex: String) -> Bool {
        textColor?.hex.lowercased() == hex
    }

    /// Reads the resolved text colour (explicit override, or the auto
    /// black/white for the background); writing always sets a custom colour.
    private var resolvedBinding: Binding<Color> {
        Binding(
            get: { textColor?.color ?? background.contrastingText },
            set: { textColor = .custom($0.hexString) }
        )
    }
}
