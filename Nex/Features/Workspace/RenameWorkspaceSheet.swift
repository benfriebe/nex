import SwiftUI

/// Small sheet for renaming a workspace, presented via keyboard shortcut or context menu.
struct RenameWorkspaceSheet: View {
    let currentName: String
    let onRename: (String) -> Void
    let onDismiss: () -> Void

    @State private var text: String = ""
    @Environment(\.chromeTheme) private var chromeTheme

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Workspace")
                .font(.headline)

            TextField("Workspace name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)

            HStack {
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .background(chromeTheme.surfaceBackground)
        .onAppear { text = currentName }
    }

    private func rename() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
    }
}
