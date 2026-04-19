import AppKit
import SwiftUI

/// Small sheet the user drops an arbitrary emoji into for a group's
/// header icon. Input is truncated to the first grapheme cluster so a
/// compound glyph (e.g. flag emoji, skin-toned emoji) survives
/// intact while anything wider than one visual character is dropped.
///
/// The macOS character picker (searchable, covers every emoji) is
/// one click away via the `Browse All Emoji…` button — it calls
/// `NSApp.orderFrontCharacterPalette(_:)`, which routes the
/// user's selection into the focused `TextField` below.
struct GroupCustomEmojiSheet: View {
    let groupName: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var emoji: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Emoji for \"\(groupName)\"")
                .font(.headline)

            Text("Type or paste a single emoji. Use \u{2303}\u{2318}Space, or the button below, to search every emoji. Non-emoji input is rejected.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("🔥", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20))
                    .focused($fieldFocused)
                    .onChange(of: emoji) { _, newValue in
                        // Collapse to one grapheme cluster so the user
                        // can't accidentally stash a whole sentence in
                        // a 4pt slot. A ZWJ sequence (e.g. 👨‍👩‍👧‍👦)
                        // is one grapheme so it survives intact.
                        if let first = newValue.first {
                            let trimmed = String(first)
                            if newValue != trimmed {
                                emoji = trimmed
                            }
                        }
                    }
                    .onSubmit { commit() }
                    .onAppear { fieldFocused = true }

                Button {
                    // Make sure the TextField is first responder so
                    // the picker's chosen glyph lands there.
                    fieldFocused = true
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .help("Browse All Emoji (⌃⌘Space)")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Set Icon", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidEmoji)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var isValidEmoji: Bool {
        guard let first = emoji.trimmingCharacters(in: .whitespacesAndNewlines).first
        else { return false }
        return first.isGraphemeEmoji
    }

    private func commit() {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isGraphemeEmoji else { return }
        onConfirm(String(first))
    }
}
