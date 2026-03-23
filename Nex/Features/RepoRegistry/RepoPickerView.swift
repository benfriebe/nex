import ComposableArchitecture
import SwiftUI

/// Fuzzy search picker for selecting a repo from the global registry.
struct RepoPickerView: View {
    let repos: IdentifiedArrayOf<Repo>
    let alreadyAssociatedRepoIDs: Set<UUID>
    let onSelect: (Repo) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Add Repository")
                .font(.headline)

            TextField("Search repos...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredRepos.isEmpty {
                VStack(spacing: 4) {
                    Text("No matching repositories")
                        .foregroundStyle(.secondary)
                    Text("Register repos in Settings > Repositories first.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(filteredRepos) { repo in
                    let isAlready = alreadyAssociatedRepoIDs.contains(repo.id)
                    Button(action: { if !isAlready { onSelect(repo) } }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(repo.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if isAlready {
                                Text("Added")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(isAlready ? 0.5 : 1.0)
                }
                .listStyle(.inset)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 360, height: 300)
    }

    private var filteredRepos: IdentifiedArrayOf<Repo> {
        if searchText.isEmpty {
            return repos
        }
        let query = searchText.lowercased()
        return repos.filter {
            $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }
}
