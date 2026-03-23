import ComposableArchitecture
import SwiftUI

/// Sheet for creating a new workspace with name, color, and optional repo associations.
struct NewWorkspaceSheet: View {
    let store: StoreOf<AppReducer>

    @State private var name = ""
    @State private var color: WorkspaceColor = .blue
    @State private var selectedRepos: [Repo] = []
    @State private var isRepoPickerPresented = false

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 16) {
                Text("New Workspace")
                    .font(.headline)

                TextField("Workspace name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)

                HStack(spacing: 8) {
                    ForEach(WorkspaceColor.allCases) { c in
                        Circle()
                            .fill(c.color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary, lineWidth: c == color ? 2 : 0)
                            )
                            .onTapGesture { color = c }
                    }
                }

                // Repositories section
                if !store.repoRegistry.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repositories")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !selectedRepos.isEmpty {
                            ForEach(selectedRepos) { repo in
                                HStack {
                                    Image(systemName: "externaldrive")
                                        .foregroundStyle(.secondary)
                                    Text(repo.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Button(action: {
                                        selectedRepos.removeAll(where: { $0.id == repo.id })
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Button(action: { isRepoPickerPresented = true }) {
                            Label("Add Repository", systemImage: "plus")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Cancel") {
                        store.send(.dismissNewWorkspaceSheet)
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
            .sheet(isPresented: $isRepoPickerPresented) {
                RepoPickerView(
                    repos: store.repoRegistry,
                    alreadyAssociatedRepoIDs: Set(selectedRepos.map(\.id)),
                    onSelect: { repo in
                        selectedRepos.append(repo)
                        isRepoPickerPresented = false
                    },
                    onCancel: {
                        isRepoPickerPresented = false
                    }
                )
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        store.send(.createWorkspace(name: trimmed, color: color, repos: selectedRepos))
    }
}
