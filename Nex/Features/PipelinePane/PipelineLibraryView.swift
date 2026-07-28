import SwiftUI

/// Shown when a `.pipeline` pane has no document open — lists
/// `~/.config/nex/pipelines/*.yaml` with New / Open / Delete.
struct PipelineLibraryView: View {
    let names: [String]
    let loadError: String?
    let onOpen: (String) -> Void
    let onCreate: () -> Void
    let onDelete: (String) -> Void

    @Environment(\.chromeTheme) private var chromeTheme
    @State private var pendingDeleteName: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pipelines")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(chromeTheme.textPrimary)
                Spacer()
                Button(action: onCreate) {
                    Label("New Pipeline", systemImage: "plus")
                }
                .font(.system(size: 12))
            }
            .padding(12)
            .background(chromeTheme.headerBackground)

            if let loadError {
                Text(loadError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if names.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundStyle(chromeTheme.textTertiary)
                    Text("No pipelines yet")
                        .font(.system(size: 13))
                        .foregroundStyle(chromeTheme.textSecondary)
                    Text("~/.config/nex/pipelines")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(chromeTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(names, id: \.self) { name in
                    HStack {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(chromeTheme.accent)
                        Text(name)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            pendingDeleteName = name
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(name) }
                }
                .listStyle(.inset)
            }
        }
        .background(chromeTheme.surfaceBackground)
        .alert(
            "Delete pipeline?",
            isPresented: Binding(
                get: { pendingDeleteName != nil },
                set: {
                    if !$0 {
                        pendingDeleteName = nil
                    }
                }
            ),
            presenting: pendingDeleteName
        ) { name in
            Button("Delete", role: .destructive) {
                onDelete(name)
                pendingDeleteName = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteName = nil }
        } message: { name in
            Text("\"\(name)\" will be permanently removed from ~/.config/nex/pipelines.")
        }
    }
}
