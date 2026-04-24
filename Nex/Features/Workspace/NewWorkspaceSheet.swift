import ComposableArchitecture
import SwiftUI

/// Sheet for creating a new workspace with name, color, and optional repo associations.
struct NewWorkspaceSheet: View {
    /// Focusable controls in reading order. Tab / Shift+Tab hop between these
    /// via the `.focused(...)` bindings. The color row is a single focus stop
    /// (arrow keys move the selection within it) so the tab loop mirrors a
    /// macOS radio group rather than producing one stop per swatch (#64).
    private enum Field: Hashable {
        case name
        case color
        case group
        case removeRepo(UUID)
        case addRepository
        case cancel
        case create
    }

    let store: StoreOf<AppReducer>

    @State private var name = ""
    @State private var color: WorkspaceColor
    @State private var selectedRepos: [Repo] = []
    @State private var isRepoPickerPresented = false
    @State private var selectedGroupID: UUID?
    @FocusState private var focusedField: Field?

    init(store: StoreOf<AppReducer>) {
        self.store = store
        _color = State(initialValue: store.workspaces.nextRandomColor())
        // Preselect the active workspace's group when inheritance is enabled,
        // so the sheet opens pointing at the group the user is likely to want.
        // They can always flip to "No group" or pick a different one.
        let defaultGroupID: UUID? = {
            guard store.settings.inheritGroupOnNewWorkspace,
                  let activeID = store.activeWorkspaceID else { return nil }
            return store.state.groupID(forWorkspace: activeID)
        }()
        _selectedGroupID = State(initialValue: defaultGroupID)
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 16) {
                Text("New Workspace")
                    .font(.headline)

                TextField("Workspace name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit(create)
                    .onKeyPress(keys: [.tab]) { handleTab($0) }

                HStack(spacing: 8) {
                    ForEach(WorkspaceColor.allCases) { c in
                        Circle()
                            .fill(c.color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary, lineWidth: c == color ? 2 : 0)
                            )
                            .onTapGesture { color = c }
                    }
                }
                .focusable()
                .focused($focusedField, equals: .color)
                .onKeyPress(.leftArrow) { cycleColor(-1) }
                .onKeyPress(.rightArrow) { cycleColor(1) }
                .onKeyPress(keys: [.tab]) { handleTab($0) }

                if !store.groups.isEmpty {
                    HStack {
                        Text("Group")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Group", selection: $selectedGroupID) {
                            Text("No group").tag(UUID?.none)
                            ForEach(store.groups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .focused($focusedField, equals: .group)
                        .onKeyPress(keys: [.tab]) { handleTab($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Repositories section
                if !store.repoRegistry.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repositories")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !selectedRepos.isEmpty {
                            ForEach(selectedRepos) { repo in
                                HStack {
                                    Image(systemName: "externaldrive")
                                        .foregroundStyle(.secondary)
                                    Text(repo.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Button(action: { removeRepo(repo.id) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .focused($focusedField, equals: .removeRepo(repo.id))
                                    .onKeyPress(keys: [.tab]) { handleTab($0) }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button(action: { isRepoPickerPresented = true }) {
                            Label("Add Repository", systemImage: "plus")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .focused($focusedField, equals: .addRepository)
                        .onKeyPress(keys: [.tab]) { handleTab($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Cancel") {
                        store.send(.dismissNewWorkspaceSheet)
                    }
                    .keyboardShortcut(.cancelAction)
                    .focused($focusedField, equals: .cancel)
                    .onKeyPress(keys: [.tab]) { handleTab($0) }

                    Spacer()

                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isCreateEnabled)
                        .focused($focusedField, equals: .create)
                        .onKeyPress(keys: [.tab]) { handleTab($0) }
                }
            }
            .padding(20)
            .frame(width: 360)
            .onAppear {
                // Dispatching lets the sheet finish presenting before we
                // steal first responder. Without this, the TextField
                // sometimes loses focus back to the window on macOS.
                DispatchQueue.main.async { focusedField = .name }
            }
            .sheet(isPresented: $isRepoPickerPresented) {
                RepoPickerView(
                    repos: store.repoRegistry,
                    alreadyAssociatedRepoIDs: Set(selectedRepos.map(\.id)),
                    onSelect: { repo in
                        selectedRepos.append(repo)
                        isRepoPickerPresented = false
                    },
                    onCancel: {
                        isRepoPickerPresented = false
                    }
                )
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        store.send(.createWorkspace(
            name: trimmed,
            color: color,
            repos: selectedRepos,
            groupID: selectedGroupID
        ))
    }

    private func cycleColor(_ delta: Int) -> KeyPress.Result {
        let cases = WorkspaceColor.allCases
        guard let idx = cases.firstIndex(of: color) else { return .ignored }
        let count = cases.count
        let newIdx = (idx + delta + count) % count
        color = cases[newIdx]
        return .handled
    }

    /// macOS's "Keyboard navigation" system setting gates whether Tab reaches
    /// buttons/pickers. We bypass that by driving focus ourselves from a Tab
    /// handler on every focusable control in the sheet (#64).
    ///
    /// `.create` is omitted while the button is disabled — AppKit refuses to
    /// make a disabled button first responder, so including it would silently
    /// break the cycle when the name field is empty.
    private var visibleFields: [Field] {
        var fields: [Field] = [.name, .color]
        if !store.groups.isEmpty {
            fields.append(.group)
        }
        if !store.repoRegistry.isEmpty {
            fields.append(contentsOf: selectedRepos.map { Field.removeRepo($0.id) })
            fields.append(.addRepository)
        }
        fields.append(.cancel)
        if isCreateEnabled {
            fields.append(.create)
        }
        return fields
    }

    private var isCreateEnabled: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Move focus off the row being deleted before mutating the array, so
    /// `focusedField` never points at a removed case (which would strand the
    /// tab loop until the user clicked somewhere). Prefer the next row, then
    /// fall back to the Add Repository button.
    private func removeRepo(_ id: UUID) {
        guard let idx = selectedRepos.firstIndex(where: { $0.id == id }) else { return }
        let wasFocused = focusedField == .removeRepo(id)
        selectedRepos.remove(at: idx)
        guard wasFocused else { return }
        if idx < selectedRepos.count {
            focusedField = .removeRepo(selectedRepos[idx].id)
        } else {
            focusedField = .addRepository
        }
    }

    private func handleTab(_ press: KeyPress) -> KeyPress.Result {
        advanceFocus(by: press.modifiers.contains(.shift) ? -1 : 1)
    }

    private func advanceFocus(by delta: Int) -> KeyPress.Result {
        let fields = visibleFields
        guard let current = focusedField,
              let idx = fields.firstIndex(of: current) else { return .ignored }
        let count = fields.count
        focusedField = fields[(idx + delta + count) % count]
        return .handled
    }
}
