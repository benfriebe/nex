import AppKit
import ComposableArchitecture
import SwiftUI

/// Settings tab for viewing and editing keybindings.
struct KeybindingsSettingsView: View {
    let store: StoreOf<AppReducer>
    @State private var recordingAction: NexAction?

    private static let categoryOrder = [
        "Pane Management", "Navigation", "Workspaces", "View", "Files", "Search"
    ]

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                List {
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
                KeyRecorderSheet(action: action) { trigger in
                    if let trigger {
                        store.send(.setKeybinding(trigger, action))
                    }
                    recordingAction = nil
                }
            }
        }
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
                    .frame(width: 120, alignment: .trailing)
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
                .frame(width: 120, alignment: .trailing)
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

// MARK: - Key Recorder Sheet

/// Modal sheet that captures a single key combination.
private struct KeyRecorderSheet: View {
    let action: NexAction
    let onComplete: (KeyTrigger?) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Record Shortcut")
                .font(.headline)

            Text("Press a key combination for \"\(action.displayName)\"")
                .foregroundStyle(.secondary)

            KeyRecorderView { trigger in
                onComplete(trigger)
            }
            .frame(width: 200, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.selection, lineWidth: 2)
            )

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
