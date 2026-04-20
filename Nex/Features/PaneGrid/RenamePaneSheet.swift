import SwiftUI

/// Small sheet for renaming (relabelling) a pane. Submitting an empty string
/// clears the label so the pane falls back to its working directory / title.
struct RenamePaneSheet: View {
    let currentName: String
    let onRename: (String) -> Void
    let onDismiss: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Pane")
                .font(.headline)

            TextField("Pane label (leave empty to clear)", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)

            HStack {
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { text = currentName }
    }

    private func rename() {
        onRename(text.trimmingCharacters(in: .whitespaces))
    }
}
