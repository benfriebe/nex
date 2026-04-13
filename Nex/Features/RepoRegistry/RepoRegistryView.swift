import ComposableArchitecture
import SwiftUI

/// Global repo registry management view, shown in Settings > Repositories.
struct RepoRegistryView: View {
    let store: StoreOf<AppReducer>
    @State private var searchText = ""

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    TextField("Filter repos...", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Button(action: scanDirectory) {
                        Label("Scan Directory", systemImage: "folder.badge.gearshape")
                    }

                    Button(action: addSingleRepo) {
                        Label("Add Repo", systemImage: "plus")
                    }
                }
                .padding(12)

                Divider()

                // Repo list
                if filteredRepos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 36))
                            .foregroundStyle(.quaternary)
                        Text(store.repoRegistry.isEmpty
                            ? "No repositories registered"
                            : "No matching repositories")
                            .foregroundStyle(.secondary)
                        if store.repoRegistry.isEmpty {
                            Text("Use \"Scan Directory\" to find repos or \"Add Repo\" to add one.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredRepos) { repo in
                            repoRow(repo)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private var filteredRepos: IdentifiedArrayOf<Repo> {
        // Hide transient, auto-discovered repos from the manual registry UI.
        // They are managed by the auto-detect flow and GC'd when no pane is
        // still inside them.
        let manualOnly = store.repoRegistry.filter { !$0.isAutoDiscovered }
        if searchText.isEmpty {
            return manualOnly
        }
        let query = searchText.lowercased()
        return manualOnly.filter {
            $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    private func repoRow(_ repo: Repo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.system(size: 13, weight: .medium))
                Text(repo.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let remote = repo.remoteURL {
                    Text(remote)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
        }
        .contextMenu {
            Button("Remove") {
                store.send(.removeRepo(repo.id))
            }
        }
    }

    private func scanDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory to scan for git repositories"

        if panel.runModal() == .OK, let url = panel.url {
            store.send(.scanForRepos(rootPath: url.path))
        }
    }

    private func addSingleRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository directory"

        if panel.runModal() == .OK, let url = panel.url {
            store.send(.addRepo(path: url.path, name: nil))
        }
    }
}
