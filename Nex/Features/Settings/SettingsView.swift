import AppKit
import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
    let store: StoreOf<AppReducer>

    var body: some View {
        WithPerceptionTracking {
            TabView {
                GeneralSettingsView(appStore: store)
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }

                AppearanceSettingsView(store: store.scope(state: \.settings, action: \.settings))
                    .tabItem {
                        Label("Appearance", systemImage: "paintbrush")
                    }

                RepoRegistryView(store: store)
                    .tabItem {
                        Label("Repositories", systemImage: "externaldrive")
                    }

                KeybindingsSettingsView(store: store)
                    .tabItem {
                        Label("Keybindings", systemImage: "command")
                    }
            }
            .frame(
                minWidth: 500, idealWidth: 600, maxWidth: .infinity,
                minHeight: 440, idealHeight: 520, maxHeight: .infinity
            )
            .background(WindowResizabilityModifier())
            // Listen here too: the main WindowGroup (and ContentView's
            // observer) may be closed while the Settings scene stays
            // open. Without this, the dialog's "Don't ask again" tick
            // would leave the toggle stale until next launch (issue #129).
            .onReceive(NotificationCenter.default.publisher(for: QuitGate.confirmQuitChangedNotification)) { _ in
                store.send(.settings(.refreshConfirmQuitWhenActive))
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
        }
    }
}

/// Appearance settings tab (extracted from original SettingsView).
private struct AppearanceSettingsView: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Form {
            Section("Appearance") {
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
    }

    private var themeBinding: Binding<NexTheme?> {
        Binding(
            get: { store.selectedTheme },
            set: { store.send(.selectTheme($0)) }
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
