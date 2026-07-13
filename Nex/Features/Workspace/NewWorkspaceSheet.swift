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
        case profile
        case removeRepo(UUID)
        case addRepository
        case worktreeToggle
        case worktreeName
        case worktreeBranch
        case updateMain
        case cancel
        case create
    }

    let store: StoreOf<AppReducer>

    @State private var name = ""
    @State private var color: WorkspaceColor
    @State private var selectedRepos: [Repo] = []
    @State private var isRepoPickerPresented = false
    @State private var selectedGroupID: UUID?
    /// Workspace profile for the new workspace. Defaults to the built-in
    /// baseline; `.setProfile`-style normalization in the reducer maps it
    /// back to nil.
    @State private var selectedProfile = WorkspaceProfilesClient.defaultProfileName
    /// Loaded once per sheet appearance — `listProfiles()` reads the config
    /// file, which must stay out of the render path.
    @State private var availableProfiles: [String] = []
    // Inline worktree creation (issue #222). Only offered when exactly one
    // repo is selected (there must be a single repo to branch from).
    @State private var createWorktree = false
    @State private var worktreeName = ""
    @State private var worktreeBranch = ""
    /// Tracks whether the user hand-edited the branch, so we stop mirroring
    /// the worktree name into it (mirrors `CreateWorktreeSheet`).
    @State private var branchEdited = false
    @State private var updateMain = false
    /// True while the async worktree create is in flight. Disables the Create
    /// button so a second click can't race the same `git worktree add`
    /// (review of #222). Reset when `worktreeCreationError` surfaces (the
    /// sheet stays open on failure); on success the sheet is dismissed.
    @State private var isSubmittingWorktree = false
    @FocusState private var focusedField: Field?
    @Environment(\.chromeTheme) private var chromeTheme
    @Dependency(\.workspaceProfiles) private var workspaceProfiles

    init(store: StoreOf<AppReducer>) {
        self.store = store
        _color = State(initialValue: store.workspaces.nextRandomColor())
        // When the sheet was opened scoped to a specific group (e.g. from the
        // empty-group context menu), honour that first. Otherwise fall back to
        // preselecting the active workspace's group when inheritance is
        // enabled. Either way the user can still flip to "No group" or pick a
        // different one.
        let defaultGroupID: UUID? = {
            if let pending = store.pendingSheetGroupID { return pending }
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

                HStack {
                    Text("Profile")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Profile", selection: $selectedProfile) {
                        ForEach(profileOptions, id: \.self) { profileName in
                            Text(profileName).tag(profileName)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .focused($focusedField, equals: .profile)
                    .onKeyPress(keys: [.tab]) { handleTab($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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

                // Inline worktree creation (issue #222). Requires exactly one
                // selected repo to branch from.
                if selectedRepos.count == 1 {
                    worktreeSection
                }

                if let error = store.worktreeCreationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Cancel") {
                        store.send(.dismissWorktreeCreationError)
                        store.send(.dismissNewWorkspaceSheet)
                    }
                    .keyboardShortcut(.cancelAction)
                    .focused($focusedField, equals: .cancel)
                    .onKeyPress(keys: [.tab]) { handleTab($0) }

                    Spacer()

                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isCreateEnabled || isSubmittingWorktree)
                        .focused($focusedField, equals: .create)
                        .onKeyPress(keys: [.tab]) { handleTab($0) }
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(chromeTheme.surfaceBackground)
            // A surfaced worktree error means the async create finished and
            // failed — re-enable Create so the user can fix the input and
            // retry (review of #222).
            .onChange(of: store.worktreeCreationError) { _, error in
                if error != nil { isSubmittingWorktree = false }
            }
            .onAppear {
                availableProfiles = workspaceProfiles.listProfiles()
                // Dispatching lets the sheet finish presenting before we
                // steal first responder. Without this, the TextField
                // sometimes loses focus back to the window on macOS.
                DispatchQueue.main.async { focusedField = .name }
            }
            .sheet(isPresented: $isRepoPickerPresented) {
                RepoPickerView(
                    repos: store.repoRegistry,
                    alreadyAssociatedRepoIDs: Set(selectedRepos.map(\.id)),
                    selectionMode: .multiple,
                    onConfirm: { chosen in
                        selectedRepos.append(contentsOf: chosen)
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

        // Inline worktree route (issue #222): validate + create the worktree,
        // then the workspace's first pane opens in it. On success the reducer
        // dismisses the sheet; on failure it surfaces `worktreeCreationError`
        // (shown inline) and keeps the sheet open.
        if createWorktree, let repo = selectedRepos.first, selectedRepos.count == 1 {
            // Guard against a second submit while the first `git worktree add`
            // is still running (review of #222).
            guard !isSubmittingWorktree else { return }
            isSubmittingWorktree = true
            store.send(.createWorkspaceWithWorktree(
                name: trimmed,
                color: color,
                repo: repo,
                worktreeName: worktreeName,
                branchName: worktreeBranch,
                updateMain: updateMain,
                groupID: selectedGroupID,
                profileName: selectedProfile
            ))
            return
        }

        store.send(.createWorkspace(
            name: trimmed,
            color: color,
            repos: selectedRepos,
            groupID: selectedGroupID,
            profileName: selectedProfile
        ))
    }

    /// Optional "create a git worktree" section, revealed when a single repo
    /// is selected. Mirrors `CreateWorktreeSheet`: sanitized live preview and
    /// worktree-name → branch-name mirroring until the branch is hand-edited.
    private var worktreeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $createWorktree) {
                Text("Create git worktree")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .focused($focusedField, equals: .worktreeToggle)
            .onKeyPress(keys: [.tab]) { handleTab($0) }

            if createWorktree {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Worktree name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", text: $worktreeName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .worktreeName)
                        .onChange(of: worktreeName) { _, new in
                            if !branchEdited { worktreeBranch = new }
                        }
                        .onKeyPress(keys: [.tab]) { handleTab($0) }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Branch name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", text: $worktreeBranch)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .worktreeBranch)
                        .onChange(of: worktreeBranch) { _, new in
                            branchEdited = (new != worktreeName)
                        }
                        // Enter-to-create parity with `CreateWorktreeSheet`.
                        .onSubmit { if isCreateEnabled { create() } }
                        .onKeyPress(keys: [.tab]) { handleTab($0) }
                }

                Toggle(isOn: $updateMain) {
                    Text("Update main first (fetch + branch off origin)")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .focused($focusedField, equals: .updateMain)
                .onKeyPress(keys: [.tab]) { handleTab($0) }

                // Live preview of what will actually be created — names are
                // sanitized (spaces/unsafe chars → hyphens) so the user sees
                // the real folder + branch up front (issue #218).
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(worktreeBasePath)/\(sanitizedWorktreeName ?? "<name>")")
                    Text("branch: \(sanitizedWorktreeBranch ?? "<branch>")")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var worktreeBasePath: String {
        store.settings.resolvedWorktreeBasePath(forRepoPath: selectedRepos.first?.path)
    }

    private var sanitizedWorktreeName: String? {
        WorkspaceFeature.State.sanitizedGitName(from: worktreeName)
    }

    private var sanitizedWorktreeBranch: String? {
        WorkspaceFeature.State.sanitizedGitName(from: worktreeBranch)
    }

    /// Built-in default first, then config-defined profiles.
    private var profileOptions: [String] {
        [WorkspaceProfilesClient.defaultProfileName]
            + availableProfiles.filter { $0 != WorkspaceProfilesClient.defaultProfileName }
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
        fields.append(.profile)
        if !store.repoRegistry.isEmpty {
            fields.append(contentsOf: selectedRepos.map { Field.removeRepo($0.id) })
            fields.append(.addRepository)
        }
        if selectedRepos.count == 1 {
            fields.append(.worktreeToggle)
            if createWorktree {
                fields.append(contentsOf: [.worktreeName, .worktreeBranch, .updateMain])
            }
        }
        fields.append(.cancel)
        if isCreateEnabled {
            fields.append(.create)
        }
        return fields
    }

    private var isCreateEnabled: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // When creating a worktree, both the folder and branch must sanitize
        // to something usable, otherwise the create button stays disabled.
        if createWorktree, selectedRepos.count == 1 {
            return sanitizedWorktreeName != nil && sanitizedWorktreeBranch != nil
        }
        return true
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
