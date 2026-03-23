import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
    let store: StoreOf<AppReducer>

    var body: some View {
        WithPerceptionTracking {
            TabView {
                GeneralSettingsView(store: store.scope(state: \.settings, action: \.settings))
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
            }
            .frame(width: 500, height: 400)
        }
    }
}

/// General settings tab.
private struct GeneralSettingsView: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Form {
            Section("Worktrees") {
                HStack {
                    Text("Base path")
                    TextField("", text: $store.worktreeBasePath.sending(\.setWorktreeBasePath))
                        .textFieldStyle(.plain)
                }
                Text("Worktrees are created at <base path>/<workspace>/<name>")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        .onAppear {
            store.send(.loadSettings)
        }
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
