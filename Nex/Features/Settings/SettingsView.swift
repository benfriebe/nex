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
            .frame(width: 500, height: 400)
        }
    }
}

/// General settings tab.
private struct GeneralSettingsView: View {
    let appStore: StoreOf<AppReducer>

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
                    Text("Worktrees are created at <base path>/<workspace>/<name>")
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

                ColorPicker(
                    "Background Color",
                    selection: backgroundColorBinding,
                    supportsOpacity: false
                )
            }
        }
        .formStyle(.grouped)
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
