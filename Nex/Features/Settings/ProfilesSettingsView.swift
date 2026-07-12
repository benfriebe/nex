import SwiftUI

/// Settings tab for creating and editing workspace profiles — the named
/// env-var sets injected into pane PTYs (see `WorkspaceProfilesClient`).
///
/// Master-detail layout (Terminal.app profiles style): profile list on the
/// left with add/remove controls, selected profile's name + variables on
/// the right.
///
/// The config file is the source of truth: this view loads it on appear and
/// writes through on every edit via `ConfigParser.writeProfiles`. Because
/// profile definitions are re-read from disk at every surface spawn, edits
/// here apply to the next pane opened in an assigned workspace with no
/// restart. Parsing uses `expandTilde: false` so a round-trip through this
/// editor never rewrites the user's `~` paths.
struct ProfilesSettingsView: View {
    @Environment(\.chromeTheme) private var chromeTheme

    /// Editable row models. Identity is minted once per row so SwiftUI
    /// focus doesn't jump while typing (dictionary-keyed rows would
    /// re-identify on every keystroke of the key field).
    private struct EditableVar: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    private struct EditableProfile: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var vars: [EditableVar]
    }

    @State private var profiles: [EditableProfile] = []
    @State private var selectedID: UUID?
    /// Guards write-through until the initial load has populated state.
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                profileList
                    .frame(width: 170)

                Divider()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Config: ~/.config/nex/config")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Changes apply to panes opened afterwards — live panes keep the env they were born with.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(10)
        }
        .background(chromeTheme.surfaceBackground)
        .onAppear(perform: load)
        .onChange(of: profiles) { _, _ in
            guard loaded else { return }
            persist()
        }
    }

    // MARK: - Left column

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(profiles) { profile in
                    Label(
                        profile.name.isEmpty ? "Untitled" : profile.name,
                        systemImage: "person.badge.key"
                    )
                    .tag(profile.id)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()

            // Standard macOS add/remove strip.
            HStack(spacing: 0) {
                Button(action: addProfile) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Add profile")

                Divider().frame(height: 14)

                Button(action: removeSelectedProfile) {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil || isDefaultSelected)
                .help("Remove selected profile")

                Spacer()
            }
        }
    }

    // MARK: - Right column

    @ViewBuilder
    private var detail: some View {
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) {
            profileDetail($profiles[index])
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text(profiles.isEmpty ? "No workspace profiles" : "No profile selected")
                    .font(.headline)
                Text("A profile is a named set of environment variables injected into every pane opened in a workspace it's assigned to — e.g. one CLAUDE_CONFIG_DIR per Claude account. Assign profiles from the workspace context menu or inspector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                if profiles.isEmpty {
                    Button("Add Profile", action: addProfile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func profileDetail(_ profile: Binding<EditableProfile>) -> some View {
        let isDefault = profile.wrappedValue.name == WorkspaceProfilesClient.defaultProfileName
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField(
                    "Profile name",
                    text: Binding(
                        get: { profile.wrappedValue.name },
                        set: { newValue in
                            // Names can't contain ":" or "=" (they'd break
                            // the `profile = name:KEY=value` line format),
                            // and the built-in default name is reserved.
                            let sanitized = sanitizedName(newValue)
                            guard sanitized != WorkspaceProfilesClient.defaultProfileName
                            else { return }
                            profile.wrappedValue.name = sanitized
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .disabled(isDefault)
            }

            if isDefault {
                Text("Built-in baseline — applies to every workspace without an explicit profile.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("Environment Variables")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    markerRow(profile)
                    ForEach(profile.vars) { $variable in
                        varRow($variable, in: profile)
                    }
                }
            }

            Button {
                profile.wrappedValue.vars.append(EditableVar(key: "", value: ""))
            } label: {
                Label("Add Variable", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    /// The locked NEX_PROFILE row shown first on every profile. The marker
    /// is injected automatically at spawn and always matches the profile
    /// name, so it's displayed as an uneditable value derived live from the
    /// name field rather than stored in the editable model.
    private func markerRow(_ profile: Binding<EditableProfile>) -> some View {
        HStack(spacing: 6) {
            TextField("", text: .constant("NEX_PROFILE"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 180)
                .disabled(true)

            Text("=")
                .foregroundStyle(.tertiary)

            TextField("", text: .constant(profile.wrappedValue.name))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disabled(true)

            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Injected automatically — always matches the profile name")
        }
    }

    private func varRow(
        _ variable: Binding<EditableVar>,
        in profile: Binding<EditableProfile>
    ) -> some View {
        HStack(spacing: 6) {
            TextField(
                "KEY",
                text: Binding(
                    get: { variable.wrappedValue.key },
                    // Keys can't contain "=" (terminates the key on parse).
                    set: { variable.wrappedValue.key = $0.replacingOccurrences(of: "=", with: "") }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 180)

            Text("=")
                .foregroundStyle(.tertiary)

            TextField("value (leading ~ expands at spawn)", text: variable.value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            Button {
                profile.wrappedValue.vars.removeAll { $0.id == variable.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove variable")
        }
    }

    // MARK: - Model plumbing

    private var isDefaultSelected: Bool {
        profiles.first(where: { $0.id == selectedID })?.name
            == WorkspaceProfilesClient.defaultProfileName
    }

    private func sanitizedName(_ raw: String) -> String {
        raw.filter { $0 != ":" && $0 != "=" }
    }

    private func load() {
        let parsed = ConfigParser.parseProfiles(
            fromFile: KeybindingService.configPath,
            expandTilde: false
        )
        var editable = parsed.map { profile in
            EditableProfile(
                name: profile.name,
                vars: profile.env
                    // The marker is derived from the name (locked row), so a
                    // stored NEX_PROFILE line never becomes an editable row.
                    .filter { $0.key != "NEX_PROFILE" }
                    .sorted(by: { $0.key < $1.key })
                    .map { EditableVar(key: $0.key, value: $0.value) }
            )
        }
        // The built-in default always exists and leads the list — virtual
        // (synthesized here) until the user gives it vars.
        if let defaultIndex = editable.firstIndex(where: {
            $0.name == WorkspaceProfilesClient.defaultProfileName
        }) {
            editable.insert(editable.remove(at: defaultIndex), at: 0)
        } else {
            editable.insert(
                EditableProfile(name: WorkspaceProfilesClient.defaultProfileName, vars: []),
                at: 0
            )
        }
        profiles = editable
        selectedID = profiles.first?.id
        loaded = true
    }

    private func persist() {
        let toWrite: [ConfigParser.Profile] = profiles.compactMap { profile in
            var env = Dictionary(
                profile.vars
                    .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
                uniquingKeysWith: { _, last in last }
            )
            // The built-in default stays out of the config while it has no
            // vars of its own (it's re-synthesized on load), keeping the
            // user's file free of a redundant marker-only line.
            if profile.name == WorkspaceProfilesClient.defaultProfileName, env.isEmpty {
                return nil
            }
            // Serialize the marker so a name-only profile still has a line
            // in the file (the format needs one line per variable, and a
            // profile with zero lines wouldn't survive a round-trip).
            // resolveEnv overrides it with the canonical name at spawn
            // regardless of what's stored.
            env["NEX_PROFILE"] = profile.name.trimmingCharacters(in: .whitespaces)
            return ConfigParser.Profile(name: profile.name, env: env)
        }
        ConfigParser.writeProfiles(toWrite, toFile: KeybindingService.configPath)
    }

    private func addProfile() {
        let existing = Set(profiles.map(\.name))
        var counter = profiles.count + 1
        var name = "profile-\(counter)"
        while existing.contains(name) {
            counter += 1
            name = "profile-\(counter)"
        }
        // New profiles start with just the locked NEX_PROFILE marker —
        // enough to persist and be assignable; add real vars as needed.
        let profile = EditableProfile(name: name, vars: [])
        profiles.append(profile)
        selectedID = profile.id
    }

    private func removeSelectedProfile() {
        guard let selectedID,
              let index = profiles.firstIndex(where: { $0.id == selectedID }),
              profiles[index].name != WorkspaceProfilesClient.defaultProfileName
        else { return }
        profiles.remove(at: index)
        self.selectedID = profiles.indices.contains(index)
            ? profiles[index].id
            : profiles.last?.id
    }
}
