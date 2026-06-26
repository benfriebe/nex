import AppKit
import ComposableArchitecture
import SwiftUI

/// Identifier for the Settings TabView's tabs, used for deep-linking
/// from the web pane's "Manage favourites…" menu.
enum SettingsTab: Hashable { case general, appearance, repos, labels, keybindings, web }

struct SettingsView: View {
    let store: StoreOf<AppReducer>

    @State private var selectedTab: SettingsTab = .general
    @Environment(\.chromeTheme) private var chromeTheme

    var body: some View {
        WithPerceptionTracking {
            TabView(selection: $selectedTab) {
                GeneralSettingsView(appStore: store)
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }
                    .tag(SettingsTab.general)

                AppearanceSettingsView(store: store.scope(state: \.settings, action: \.settings))
                    .tabItem {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    .tag(SettingsTab.appearance)

                RepoRegistryView(store: store)
                    .tabItem {
                        Label("Repositories", systemImage: "externaldrive")
                    }
                    .tag(SettingsTab.repos)

                LabelPresetsSettingsView(store: store)
                    .tabItem {
                        Label("Labels", systemImage: "tag")
                    }
                    .tag(SettingsTab.labels)

                KeybindingsSettingsView(store: store)
                    .tabItem {
                        Label("Keybindings", systemImage: "command")
                    }
                    .tag(SettingsTab.keybindings)

                WebFavouritesSettingsView(store: store)
                    .tabItem {
                        Label("Web", systemImage: "globe")
                    }
                    .tag(SettingsTab.web)
            }
            .frame(
                minWidth: 500, idealWidth: 600, maxWidth: .infinity,
                minHeight: 440, idealHeight: 520, maxHeight: .infinity
            )
            .background(WindowResizabilityModifier())
            .background(chromeTheme.surfaceBackground)
            // Listen here too: the main WindowGroup (and ContentView's
            // observer) may be closed while the Settings scene stays
            // open. Without this, the dialog's "Don't ask again" tick
            // would leave the toggle stale until next launch (issue #129).
            .onReceive(NotificationCenter.default.publisher(for: QuitGate.confirmQuitChangedNotification)) { _ in
                store.send(.settings(.refreshConfirmQuitWhenActive))
            }
            // Deep-link from a web pane's "Manage favourites…" menu.
            // `pendingSettingsTab` covers cold-open (notification has
            // no listener yet); `.onReceive` covers re-opens of an
            // already-mounted Settings scene.
            .onAppear {
                if let pending = WebPaneChrome.pendingSettingsTab {
                    selectedTab = pending
                    WebPaneChrome.pendingSettingsTab = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: WebPaneChrome.openSettingsTabNotification)) { note in
                if let tab = note.object as? SettingsTab {
                    selectedTab = tab
                }
                WebPaneChrome.pendingSettingsTab = nil
            }
        }
    }
}

/// Finds the hosting NSWindow and adds the resizable style mask.
private struct WindowResizabilityModifier: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.styleMask.insert(.resizable)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if let window = nsView.window {
            window.styleMask.insert(.resizable)
        }
    }
}

/// General settings tab.
private struct GeneralSettingsView: View {
    let appStore: StoreOf<AppReducer>
    @State private var tcpPortText: String = ""
    @Environment(\.chromeTheme) private var chromeTheme

    var body: some View {
        WithPerceptionTracking {
            let settingsStore = appStore.scope(state: \.settings, action: \.settings)
            Form {
                Section("Worktrees") {
                    HStack {
                        Text("Base path")
                        TextField("", text: Bindable(settingsStore).worktreeBasePath.sending(\.setWorktreeBasePath))
                            .textFieldStyle(.plain)
                    }
                    Text("Worktrees are created at <base path>/<name>. Use <repo> in the base path to substitute the repository: at the start it resolves to the full repo path (e.g., <repo>/.claude/worktrees), elsewhere it resolves to the repo directory name (e.g., ~/nex/worktrees/<repo>).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Repositories") {
                    Toggle("Auto-detect from pane directories", isOn: Binding(
                        get: { settingsStore.autoDetectRepos },
                        set: { settingsStore.send(.setAutoDetectRepos($0)) }
                    ))
                    Text("When a pane's working directory is inside a Git repository, automatically associate the repo (or worktree) with the workspace. Removed a few seconds after no pane remains in it. Manually added repos are never auto-removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Workspaces") {
                    Toggle("Inherit group when creating a new workspace", isOn: Binding(
                        get: { settingsStore.inheritGroupOnNewWorkspace },
                        set: { settingsStore.send(.setInheritGroupOnNewWorkspace($0)) }
                    ))
                    Text("When the active workspace belongs to a group, new workspaces are created inside that same group. Disable to always create at the top level.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Expand group when a workspace is dropped into it", isOn: Binding(
                        get: { settingsStore.expandGroupOnWorkspaceDrop },
                        set: { settingsStore.send(.setExpandGroupOnWorkspaceDrop($0)) }
                    ))
                    Text("When dragging a workspace into a collapsed group, expand the group on drop so the moved workspace is visible. Disable to keep the group collapsed and avoid disrupting the sidebar layout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("New workspace placement", selection: Binding(
                        get: { settingsStore.newWorkspacePlacement },
                        set: { settingsStore.send(.setNewWorkspacePlacement($0)) }
                    )) {
                        Text("Next to selection").tag(SidebarPlacement.nearSelection)
                        Text("End of list").tag(SidebarPlacement.endOfList)
                    }
                    Text("Where a newly created workspace is inserted. \"Next to selection\" places it immediately after the active workspace's slot (within the target group when creating into one, falling back to append when the active workspace isn't in that group). \"End of list\" always appends to the bottom of the sidebar (or the end of the target group).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("New group placement", selection: Binding(
                        get: { settingsStore.newGroupPlacement },
                        set: { settingsStore.send(.setNewGroupPlacement($0)) }
                    )) {
                        Text("Next to selection").tag(SidebarPlacement.nearSelection)
                        Text("End of list").tag(SidebarPlacement.endOfList)
                    }
                    Text("Where a newly created group is inserted in the sidebar. \"Next to selection\" places it after the active workspace (or its parent group when nested). \"End of list\" always appends it to the bottom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Panes") {
                    Toggle("Focus follows mouse", isOn: Binding(
                        get: { appStore.focusFollowsMouse },
                        set: { appStore.send(.setFocusFollowsMouse($0)) }
                    ))
                    Text("Automatically focus a pane when the mouse moves over it")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appStore.focusFollowsMouse {
                        HStack {
                            Text("Delay")
                            Slider(
                                value: Binding(
                                    get: { Double(appStore.focusFollowsMouseDelay) },
                                    set: { appStore.send(.setFocusFollowsMouseDelay(Int($0))) }
                                ),
                                in: 0 ... 500,
                                step: 25
                            )
                            Text("\(appStore.focusFollowsMouseDelay) ms")
                                .monospacedDigit()
                                .frame(width: 55, alignment: .trailing)
                        }
                    }
                }

                Section("Quit") {
                    Toggle("Confirm before quitting", isOn: Binding(
                        get: { settingsStore.confirmQuitWhenActive },
                        set: { settingsStore.send(.setConfirmQuitWhenActive($0)) }
                    ))
                    Text("Show a confirmation dialog on Cmd+Q. When agents are running or waiting for input, the dialog calls them out so an accidental quit doesn't lose work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Network") {
                    Toggle("TCP listener", isOn: Binding(
                        get: { appStore.tcpPort > 0 },
                        set: { enabled in
                            if enabled {
                                tcpPortText = "19400"
                                appStore.send(.setTCPPort(19400))
                            } else {
                                appStore.send(.setTCPPort(0))
                            }
                        }
                    ))
                    Text("Listen on 127.0.0.1 for dev containers and SSH tunnels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appStore.tcpPort > 0 {
                        HStack {
                            Text("Port")
                            TextField("", text: $tcpPortText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            if Int(tcpPortText) != appStore.tcpPort {
                                Button("Apply") {
                                    appStore.send(.setTCPPort(Int(tcpPortText) ?? 19400))
                                }
                            }
                        }
                    }

                    if let error = appStore.tcpPortError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .onAppear {
                    if appStore.tcpPort > 0 {
                        tcpPortText = "\(appStore.tcpPort)"
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(chromeTheme.surfaceBackground)
        }
    }
}

/// Appearance settings tab (extracted from original SettingsView).
private struct AppearanceSettingsView: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @Environment(\.chromeTheme) private var chromeTheme
    /// Resolved scheme inside the (themed) Settings scene — tells us which
    /// light/dark override bucket the colour pickers edit.
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        Form {
            Section("Chrome") {
                Picker(
                    "Appearance",
                    selection: $store.chromeAppearance.sending(\.setChromeAppearance)
                ) {
                    ForEach(ChromeAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Text("Themes the Nex window chrome (sidebar, title bar, status bar). "
                    + "Independent of the terminal theme below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Chrome Colours") {
                ForEach(ChromeColorKey.allCases) { key in
                    ColorPicker(
                        key.displayName,
                        selection: chromeColorBinding(key),
                        supportsOpacity: false
                    )
                }
                HStack {
                    Text("Editing the \(systemScheme == .dark ? "Dark" : "Light") palette — "
                        + "switch Appearance above to edit the other.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { store.send(.resetChromeColors) }
                }
            }

            Section("Sidebar") {
                HStack {
                    Text("Colour intensity")
                    Slider(
                        value: $store.sidebarColorIntensity.sending(\.setSidebarColorIntensity),
                        in: 0.0 ... 2.0,
                        step: 0.05
                    )
                    Text("\(Int(store.sidebarColorIntensity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Scales how vivid the group bands and workspace avatars are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Picker("Theme", selection: themeBinding) {
                    Text("None (Custom)").tag(NexTheme?.none)
                    ForEach(NexTheme.builtIn) { theme in
                        Text(theme.displayName).tag(Optional(theme))
                    }
                }

                if store.selectedTheme == nil {
                    ColorPicker(
                        "Background Color",
                        selection: backgroundColorBinding,
                        supportsOpacity: false
                    )
                }

                HStack {
                    Text("Background Opacity")
                    Slider(
                        value: $store.backgroundOpacity.sending(\.setBackgroundOpacity),
                        in: 0.1 ... 1.0,
                        step: 0.05
                    )
                    Text("\(Int(store.backgroundOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(chromeTheme.surfaceBackground)
    }

    private var themeBinding: Binding<NexTheme?> {
        Binding(
            get: { store.selectedTheme },
            set: { store.send(.selectTheme($0)) }
        )
    }

    /// Two-way binding for one customisable chrome colour. Reads the resolved
    /// value (override or preset) and writes the override into the bucket for
    /// the appearance currently shown.
    private func chromeColorBinding(_ key: ChromeColorKey) -> Binding<Color> {
        let storageKey = "\(systemScheme == .dark ? "dark" : "light"):\(key.rawValue)"
        return Binding(
            get: { key.value(in: chromeTheme) },
            set: { newColor in
                if let hex = newColor.chromeHexString {
                    store.send(.setChromeColor(key: storageKey, hex: hex))
                }
            }
        )
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: store.backgroundColorR,
                    green: store.backgroundColorG,
                    blue: store.backgroundColorB
                )
            },
            set: { newColor in
                if let components = NSColor(newColor).usingColorSpace(.sRGB) {
                    store.send(.setBackgroundColor(
                        r: Double(components.redComponent),
                        g: Double(components.greenComponent),
                        b: Double(components.blueComponent)
                    ))
                }
            }
        )
    }
}

private struct WebFavouritesSettingsView: View {
    let store: StoreOf<AppReducer>
    @State private var selection: Favourite.ID?
    @Environment(\.chromeTheme) private var chromeTheme

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if store.favourites.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No favourites yet")
                            .foregroundStyle(.secondary)
                        Text("Click the star button in a web pane's URL bar to save one.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(store.favourites) { fav in
                            FavouriteRow(
                                favourite: fav,
                                onRename: { newTitle in
                                    store.send(.renameFavourite(id: fav.id, title: newTitle))
                                },
                                onRemove: {
                                    store.send(.removeFavourite(id: fav.id))
                                }
                            )
                            .tag(fav.id)
                        }
                        .onMove { source, destination in
                            guard let from = source.first else { return }
                            store.send(.moveFavourite(fromIndex: from, toIndex: destination))
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(chromeTheme.surfaceBackground)
        }
    }
}

private struct FavouriteRow: View {
    let favourite: Favourite
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var editingTitle: String
    @FocusState private var isFocused: Bool

    init(favourite: Favourite, onRename: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.favourite = favourite
        self.onRename = onRename
        self.onRemove = onRemove
        _editingTitle = State(initialValue: favourite.title)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .foregroundStyle(Color.yellow)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $editingTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .medium))
                    .focused($isFocused)
                    .onSubmit(commitRename)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                Text(favourite.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove favourite")
        }
        .padding(.vertical, 2)
    }

    private func commitRename() {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != favourite.title {
            onRename(trimmed)
        }
    }
}
