import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

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
            // Match the app's header/footer tone on the Settings tab strip.
            .toolbarBackground(chromeTheme.headerBackground, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
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

                Section("Status bar") {
                    Toggle("Show system stats", isOn: Binding(
                        get: { settingsStore.showSystemStats },
                        set: { settingsStore.send(.setShowSystemStats($0)) }
                    ))
                    if settingsStore.showSystemStats {
                        ForEach(SystemStatKind.allCases) { kind in
                            Toggle(isOn: Binding(
                                get: { settingsStore.enabledSystemStats.contains(kind.rawValue) },
                                set: { settingsStore.send(.setSystemStatEnabled(kind, $0)) }
                            )) {
                                Label(kind.displayName, systemImage: kind.systemImage)
                            }
                            .padding(.leading, 16)
                        }
                        DisclosureGroup("Mini graphs") {
                            Toggle("Show mini graphs", isOn: Binding(
                                get: { settingsStore.showSystemStatGraphs },
                                set: { settingsStore.send(.setShowSystemStatGraphs($0)) }
                            ))
                            Picker("Graph style", selection: Binding(
                                get: { SparklineStyle(rawValue: settingsStore.sparklineStyle) ?? .line },
                                set: { settingsStore.send(.setSparklineStyle($0.rawValue)) }
                            )) {
                                ForEach(SparklineStyle.allCases) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            ColorPicker("Graph colour", selection: Binding(
                                get: { Color(chromeHex: settingsStore.sparklineColorHex) ?? chromeTheme.textSecondary },
                                set: { if let hex = $0.chromeHexString { settingsStore.send(.setSparklineColor(hex)) } }
                            ), supportsOpacity: false)
                            HStack {
                                Text("Graph width")
                                Slider(value: Binding(
                                    get: { settingsStore.sparklineWidth },
                                    set: { settingsStore.send(.setSparklineWidth($0)) }
                                ), in: 16 ... 80, step: 2)
                                Text("\(Int(settingsStore.sparklineWidth))")
                                    .monospacedDigit()
                                    .frame(width: 32, alignment: .trailing)
                            }
                            Button("Reset graph colour") { settingsStore.send(.setSparklineColor("")) }
                        }
                    }
                    Text("Live system metrics on the right of the bottom status bar. Hover any metric for a detail graph over time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    /// Transient feedback for the Theme export/import/copy/paste actions.
    @State private var themeStatus: String?

    private let presetColumns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        Form {
            Section("Preset Themes") {
                LazyVGrid(columns: presetColumns, spacing: 12) {
                    ForEach(BuiltInChromeTheme.all) { preset in
                        presetCell(preset)
                    }
                }
                .padding(.vertical, 4)
                Text("One-click chrome palettes based on popular editor themes. Each "
                    + "recolours the sidebar, title bar, status bar and agent dots, and "
                    + "switches Light/Dark to suit. Your terminal theme is unchanged; "
                    + "tweak any colour below afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Save & Share") {
                HStack {
                    Button("Export…") { exportTheme() }
                    Button("Import…") { importTheme() }
                    Spacer()
                    Button("Copy Code") { copyThemeCode() }
                    Button("Paste Code") { pasteThemeCode() }
                }
                if let themeStatus {
                    Text(themeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Save your custom chrome colours and sidebar styling as a "
                        + "shareable .nextheme file or a copyable code. Importing restyles "
                        + "the chrome without changing your light/dark mode or terminal "
                        + "background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                ForEach(ChromeColorKey.allCases.filter { !$0.isAgentStatus }) { key in
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

            Section("Agent status") {
                ForEach(ChromeColorKey.allCases.filter(\.isAgentStatus)) { key in
                    ColorPicker(
                        key.displayName,
                        selection: chromeColorBinding(key),
                        supportsOpacity: false
                    )
                }
                Text("The dot / badge colour shown for each agent state across the "
                    + "status bar, sidebar, pane headers, title bar and menu-bar icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar") {
                sliderRow(
                    "Colour intensity",
                    value: $store.sidebarColorIntensity.sending(\.setSidebarColorIntensity),
                    in: 0.0 ... 2.0
                )
                Text("Scales how vivid the group bands and workspace avatars are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar fill & stroke") {
                opacityRow("Avatar fill", .avatarFill, store.sidebarAvatarFillOpacity)
                opacityRow("Avatar border", .avatarStroke, store.sidebarAvatarStrokeOpacity)
                opacityRow(
                    "Group band fill",
                    .groupFill,
                    store.sidebarGroupFillOpacity < 0
                        ? chromeTheme.groupBandOpacity
                        : store.sidebarGroupFillOpacity
                )
                opacityRow("Group band border", .groupStroke, store.sidebarGroupStrokeOpacity)
                Text("Fill = colour wash, border = outline. The intensity above multiplies these.")
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

                sliderRow(
                    "Background Opacity",
                    value: $store.backgroundOpacity.sending(\.setBackgroundOpacity),
                    in: 0.1 ... 1.0
                )
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

    private func opacityRow(_ label: String, _ param: SidebarStyleParam, _ value: Double) -> some View {
        sliderRow(
            label,
            value: Binding(get: { value }, set: { store.send(.setSidebarStyle(param, $0)) }),
            in: 0.0 ... 1.0
        )
    }

    /// Uniform slider row: fixed-width label + slider + fixed-width percent, so
    /// every slider in the Appearance tab lines up and is the same length.
    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 140, alignment: .leading)
            Slider(value: value, in: range, step: 0.05)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
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

    // MARK: - Preset themes

    private func presetCell(_ preset: BuiltInChromeTheme) -> some View {
        Button {
            applyPreset(preset)
        } label: {
            VStack(spacing: 5) {
                ThemeSwatch(palette: preset.palette)
                Text(preset.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .help("Apply the \(preset.name) theme (\(preset.appearance.displayName))")
    }

    private func applyPreset(_ preset: BuiltInChromeTheme) {
        // Switch to the palette's native mode, then overwrite the styling.
        store.send(.setChromeAppearance(preset.appearance))
        store.send(.applyStyleTheme(preset.styleTheme))
        themeStatus = "Applied \u{201C}\(preset.name)\u{201D} (\(preset.appearance.displayName))."
    }

    // MARK: - Theme export / import

    /// The chrome styling currently in settings, captured into a shareable theme.
    private func currentTheme(name: String? = nil) -> ChromeStyleTheme {
        store.withState { ChromeStyleTheme(capturing: $0, name: name) }
    }

    private static let themeUTType = UTType(filenameExtension: "nextheme") ?? .json

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.themeUTType]
        panel.nameFieldStringValue = "MyTheme.nextheme"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            try currentTheme(name: name).jsonData().write(to: url)
            themeStatus = "Exported \u{201C}\(name)\u{201D}."
        } catch {
            themeStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [Self.themeUTType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try ChromeStyleTheme(jsonData: Data(contentsOf: url))
            store.send(.applyStyleTheme(theme))
            let label = theme.name ?? url.deletingPathExtension().lastPathComponent
            themeStatus = "Imported \u{201C}\(label)\u{201D}."
        } catch let error as ChromeStyleThemeError {
            themeStatus = error.message
        } catch {
            themeStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    private func copyThemeCode() {
        do {
            let code = try currentTheme().shareCode()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            themeStatus = "Theme code copied to the clipboard."
        } catch {
            themeStatus = "Couldn't generate a theme code."
        }
    }

    private func pasteThemeCode() {
        guard let code = NSPasteboard.general.string(forType: .string),
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            themeStatus = "The clipboard has no theme code to paste."
            return
        }
        do {
            let theme = try ChromeStyleTheme(shareCode: code)
            store.send(.applyStyleTheme(theme))
            themeStatus = "Imported theme from the clipboard" + (theme.name.map { " (\u{201C}\($0)\u{201D})" } ?? "") + "."
        } catch let error as ChromeStyleThemeError {
            themeStatus = error.message
        } catch {
            themeStatus = "That clipboard text isn't a Nex theme."
        }
    }
}

/// A compact mock of the chrome — sidebar strip, header bar and three agent
/// status dots — painted in a preset's palette, so the gallery previews how a
/// theme actually looks before it's applied.
private struct ThemeSwatch: View {
    let palette: ChromePalette

    private func color(_ hex: String) -> Color {
        Color(chromeHex: hex) ?? .gray
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar: an accent pill + two muted "rows".
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(color(palette.accent)).frame(width: 18, height: 4)
                Capsule().fill(color(palette.divider)).frame(width: 13, height: 3)
                Capsule().fill(color(palette.divider)).frame(width: 15, height: 3)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 38, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(color(palette.sidebarBackground))

            // Main: a header strip over the surface, with three status dots.
            VStack(spacing: 0) {
                Rectangle().fill(color(palette.headerBackground)).frame(height: 10)
                HStack(spacing: 4) {
                    Circle().fill(color(palette.statusRunning)).frame(width: 5, height: 5)
                    Circle().fill(color(palette.statusWaiting)).frame(width: 5, height: 5)
                    Circle().fill(color(palette.statusInactive)).frame(width: 5, height: 5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5)
                .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color(palette.surfaceBackground))
        }
        .frame(height: 46)
        .background(color(palette.windowBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color(palette.divider), lineWidth: 1)
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
