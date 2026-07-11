import SwiftUI

/// Settings tab for creating and editing workspace profiles — the named
/// env-var sets injected into pane PTYs (see `WorkspaceProfilesClient`).
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
    /// Guards write-through until the initial load has populated state.
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            if profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach($profiles) { $profile in
                        profileSection($profile)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
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
                Button("Add Profile") { addProfile() }
            }
            .padding(12)
        }
        .background(chromeTheme.surfaceBackground)
        .onAppear(perform: load)
        .onChange(of: profiles) { _, _ in
            guard loaded else { return }
            persist()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No workspace profiles")
                .font(.headline)
            Text("A profile is a named set of environment variables injected into every pane opened in a workspace it's assigned to — e.g. one CLAUDE_CONFIG_DIR per Claude account. Assign profiles from the workspace context menu or inspector.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func profileSection(_ profile: Binding<EditableProfile>) -> some View {
        Section {
            ForEach(profile.vars) { $variable in
                varRow($variable, in: profile)
            }

            HStack {
                Button {
                    profile.wrappedValue.vars.append(EditableVar(key: "", value: ""))
                } label: {
                    Label("Add Variable", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if profile.wrappedValue.vars.allSatisfy({ $0.key.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text("A profile needs at least one variable to be saved.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            HStack {
                TextField(
                    "Profile name",
                    text: Binding(
                        get: { profile.wrappedValue.name },
                        // Names can't contain ":" or "=" (they'd break the
                        // `profile = name:KEY=value` line format).
                        set: { profile.wrappedValue.name = sanitizedName($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    profiles.removeAll { $0.id == profile.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete profile")
            }
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
            .font(.system(.body, design: .monospaced))
            .frame(width: 200)

            Text("=")
                .foregroundStyle(.tertiary)

            TextField("value (leading ~ expands at spawn)", text: variable.value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Button {
                profile.wrappedValue.vars.removeAll { $0.id == variable.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove variable")
        }
    }

    private func sanitizedName(_ raw: String) -> String {
        raw.filter { $0 != ":" && $0 != "=" }
    }

    private func load() {
        let parsed = ConfigParser.parseProfiles(
            fromFile: KeybindingService.configPath,
            expandTilde: false
        )
        profiles = parsed.map { profile in
            EditableProfile(
                name: profile.name,
                vars: profile.env
                    .sorted(by: { $0.key < $1.key })
                    .map { EditableVar(key: $0.key, value: $0.value) }
            )
        }
        loaded = true
    }

    private func persist() {
        let toWrite = profiles.map { profile in
            ConfigParser.Profile(
                name: profile.name,
                env: Dictionary(
                    profile.vars
                        .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
                    uniquingKeysWith: { _, last in last }
                )
            )
        }
        ConfigParser.writeProfiles(toWrite, toFile: KeybindingService.configPath)
    }

    private func addProfile() {
        let existing = Set(profiles.map(\.name))
        var name = "profile-\(profiles.count + 1)"
        var counter = profiles.count + 1
        while existing.contains(name) {
            counter += 1
            name = "profile-\(counter)"
        }
        profiles.append(EditableProfile(
            name: name,
            vars: [EditableVar(key: "", value: "")]
        ))
    }
}
