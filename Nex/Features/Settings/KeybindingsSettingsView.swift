import AppKit
import ComposableArchitecture
import SwiftUI

/// Settings tab for viewing and editing keybindings.
struct KeybindingsSettingsView: View {
    let store: StoreOf<AppReducer>
    @State private var recordingAction: NexAction?
    @State private var recordingGlobal: Bool = false

    private static let categoryOrder = [
        "Pane Management", "Navigation", "Workspaces", "View", "Files", "Search"
    ]

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                List {
                    Section("Global") {
                        globalHotkeyRow
                        Toggle(
                            "Press again to hide",
                            isOn: Binding(
                                get: { store.globalHotkeyHideOnRepress },
                                set: { store.send(.setGlobalHotkeyHideOnRepress($0)) }
                            )
                        )
                        .disabled(store.globalHotkey == nil)

                        if let reason = store.globalHotkeyRegistrationError {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let conflict = store.globalHotkeyConflictWithInApp {
                            Label(
                                "Shadows in-app shortcut: \(conflict.message). The in-app shortcut will not fire while Nex is frontmost.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }

                    ForEach(Self.categoryOrder, id: \.self) { category in
                        let actions = NexAction.bindableActions.filter { $0.category == category }
                        if !actions.isEmpty {
                            Section(category) {
                                ForEach(actions, id: \.rawValue) { action in
                                    keybindingRow(action: action)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

                Divider()

                HStack {
                    Text("Config: ~/.config/nex/config")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All to Defaults") {
                        store.send(.resetKeybindings)
                    }
                }
                .padding(12)
            }
            .sheet(item: recordingActionBinding) { action in
                KeyRecorderSheet(
                    action: action,
                    currentMap: store.keybindings,
                    globalHotkey: store.globalHotkey
                ) { trigger in
                    if let trigger {
                        store.send(.setKeybinding(trigger, action))
                    }
                    recordingAction = nil
                }
            }
            .sheet(isPresented: $recordingGlobal) {
                GlobalKeyRecorderSheet(
                    currentMap: store.keybindings,
                    currentGlobalHotkey: store.globalHotkey
                ) { trigger in
                    if let trigger {
                        store.send(.setGlobalHotkey(trigger))
                    }
                    recordingGlobal = false
                }
            }
        }
    }

    private var globalHotkeyRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Global Hotkey")
                Text("Works from any app. No Accessibility permission required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trigger = store.globalHotkey {
                HStack(spacing: 2) {
                    Text(trigger.displayString)
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                        )

                    Button {
                        store.send(.setGlobalHotkey(nil))
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(minWidth: 120, alignment: .trailing)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 120, alignment: .trailing)
            }

            Button("Record") {
                recordingGlobal = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func keybindingRow(action: NexAction) -> some View {
        let triggers = store.keybindings.triggers(for: action)
        HStack {
            Text(action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            if triggers.isEmpty {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 120, alignment: .trailing)
            } else {
                HStack(spacing: 4) {
                    ForEach(triggers, id: \.self) { trigger in
                        HStack(spacing: 2) {
                            Text(trigger.displayString)
                                .font(.system(.body, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.quaternary)
                                )

                            Button {
                                store.send(.removeKeybinding(trigger))
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minWidth: 120, alignment: .trailing)
            }

            Button("Record") {
                recordingAction = action
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            let hasNonDefaultBinding = triggers != KeyBindingMap.defaults.triggers(for: action)
            Button("Reset") {
                store.send(.resetBindingsForAction(action))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!hasNonDefaultBinding)
        }
        .padding(.vertical, 2)
    }

    private var recordingActionBinding: Binding<NexAction?> {
        Binding(
            get: { recordingAction },
            set: { recordingAction = $0 }
        )
    }
}

// MARK: - NexAction Identifiable for sheet

extension NexAction: Identifiable {
    var id: String { rawValue }
}

// MARK: - Global Hotkey Recorder Sheet

/// Modal sheet for capturing the system-wide global hotkey.
/// Rejects combos that are already bound to an in-app action; the user can
/// press another combo without closing the sheet.
private struct GlobalKeyRecorderSheet: View {
    let currentMap: KeyBindingMap
    let currentGlobalHotkey: KeyTrigger?
    let onComplete: (KeyTrigger?) -> Void

    @State private var conflictMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Record Global Hotkey")
                .font(.headline)

            Text("Press a key combination to bring Nex forward from any app.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            KeyRecorderView { trigger in
                let conflict = KeybindingConflict.check(
                    trigger: trigger,
                    in: currentMap,
                    globalHotkey: currentGlobalHotkey,
                    ignoreGlobalHotkey: true
                )
                if let conflict {
                    conflictMessage = conflict.message
                    return
                }
                conflictMessage = nil
                onComplete(trigger)
            }
            .frame(width: 240, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.selection, lineWidth: 2)
            )

            if let conflictMessage {
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") {
                    onComplete(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Key Recorder Sheet

/// Modal sheet that captures a single key combination.
/// Rejects combos that collide with the global hotkey or a different action;
/// re-recording the same combo for the same action is a no-op.
private struct KeyRecorderSheet: View {
    let action: NexAction
    let currentMap: KeyBindingMap
    let globalHotkey: KeyTrigger?
    let onComplete: (KeyTrigger?) -> Void

    @State private var conflictMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Record Shortcut")
                .font(.headline)

            Text("Press a key combination for \"\(action.displayName)\"")
                .foregroundStyle(.secondary)

            KeyRecorderView { trigger in
                let conflict = KeybindingConflict.check(
                    trigger: trigger,
                    in: currentMap,
                    globalHotkey: globalHotkey,
                    excluding: action
                )
                if let conflict {
                    conflictMessage = conflict.message
                    return
                }
                conflictMessage = nil
                onComplete(trigger)
            }
            .frame(width: 200, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.selection, lineWidth: 2)
            )

            if let conflictMessage {
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") {
                    onComplete(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

// MARK: - Key Recorder NSView

/// NSViewRepresentable that captures keyDown events and returns a KeyTrigger.
private struct KeyRecorderView: NSViewRepresentable {
    let onKeyRecorded: (KeyTrigger) -> Void

    func makeNSView(context _: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onKeyRecorded = onKeyRecorded
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context _: Context) {
        nsView.onKeyRecorded = onKeyRecorded
    }
}

private final class KeyRecorderNSView: NSView {
    var onKeyRecorded: ((KeyTrigger) -> Void)?
    private let label = NSTextField(labelWithString: "Press a key combo...")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let trigger = KeyTrigger(event: event)

        // Require at least one modifier (except for special keys like Escape, F-keys)
        let hasModifier = !trigger.modifiers.isEmpty
        let fKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        let isSpecialKey = event.keyCode == 53 // Escape
            || fKeyCodes.contains(event.keyCode)

        if hasModifier || isSpecialKey {
            label.stringValue = trigger.displayString
            label.textColor = .labelColor
            label.font = .systemFont(ofSize: 15, weight: .medium)
            onKeyRecorded?(trigger)
        }
    }
}
