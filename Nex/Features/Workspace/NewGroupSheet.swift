import SwiftUI

/// Small sheet for naming a new workspace group, used by the bulk
/// "Group Selected Workspaces..." flow.
struct NewGroupSheet: View {
    let workspaceCount: Int
    let defaultName: String
    let onCreate: (String, WorkspaceColor?) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var selectedColor: WorkspaceColor?
    @Environment(\.chromeTheme) private var chromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Group")
                .font(.headline)

            Text("Group \(workspaceCount) selected workspace\(workspaceCount == 1 ? "" : "s").")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Group name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)

            HStack(spacing: 6) {
                Text("Color")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { selectedColor = nil }) {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                        .frame(width: 16, height: 16)
                        .overlay {
                            if selectedColor == nil {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                }
                .buttonStyle(.plain)
                ForEach(WorkspaceColor.allCases) { color in
                    Button(action: { selectedColor = color }) {
                        Circle()
                            .fill(color.color)
                            .frame(width: 16, height: 16)
                            .overlay {
                                if selectedColor == color {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
        .background(chromeTheme.surfaceBackground)
        .onAppear { text = defaultName }
    }

    private func create() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, selectedColor)
    }
}
