import ComposableArchitecture
import SwiftUI

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// Trailing inspector panel showing workspace metadata, repo associations, and pane list.
struct WorkspaceInspectorView: View {
    let store: StoreOf<AppReducer>
    @State private var isRepoPickerPresented = false
    @State private var isWorktreePickerPresented = false
    @State private var worktreeRepoID: UUID?
    @State private var worktreeName = ""
    @State private var worktreeBranchName = ""

    var body: some View {
        WithPerceptionTracking {
            if let activeID = store.activeWorkspaceID,
               let workspace = store.workspaces[id: activeID] {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack {
                        Text("Inspector")
                            .font(.headline)
                        Spacer()
                        Button(action: { store.send(.toggleInspector) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Workspace metadata
                            workspaceSection(workspace)

                            Divider()

                            // Repo associations
                            repoSection(workspace, activeID: activeID)

                            Divider()

                            // Pane list
                            paneSection(workspace, activeID: activeID)
                        }
                        .padding(12)
                    }
                }
                .frame(width: 280)
                .background(Color(nsColor: .controlBackgroundColor))
                .sheet(isPresented: $isRepoPickerPresented) {
                    RepoPickerView(
                        repos: store.repoRegistry,
                        alreadyAssociatedRepoIDs: Set(workspace.repoAssociations.map(\.repoID)),
                        onSelect: { repo in
                            let assoc = RepoAssociation(
                                repoID: repo.id,
                                worktreePath: repo.path
                            )
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .addRepoAssociation(assoc)
                            )))
                            isRepoPickerPresented = false
                        },
                        onCancel: {
                            isRepoPickerPresented = false
                        }
                    )
                }
                .sheet(isPresented: $isWorktreePickerPresented) {
                    RepoPickerView(
                        repos: store.repoRegistry,
                        alreadyAssociatedRepoIDs: [],
                        onSelect: { repo in
                            isWorktreePickerPresented = false
                            worktreeRepoID = repo.id
                            worktreeName = ""
                            worktreeBranchName = ""
                        },
                        onCancel: {
                            isWorktreePickerPresented = false
                        }
                    )
                }
                .sheet(item: $worktreeRepoID) { repoID in
                    CreateWorktreeSheet(
                        repoName: store.repoRegistry[id: repoID]?.name ?? "repo",
                        workspaceSlug: workspace.slug,
                        worktreeBasePath: store.settings.worktreeBasePath,
                        worktreeName: $worktreeName,
                        branchName: $worktreeBranchName,
                        onCreate: {
                            store.send(.createWorktree(
                                workspaceID: activeID,
                                repoID: repoID,
                                worktreeName: worktreeName,
                                branchName: worktreeBranchName
                            ))
                            worktreeRepoID = nil
                        },
                        onCancel: {
                            worktreeRepoID = nil
                        }
                    )
                }
            }
        }
    }

    private func workspaceSection(_ workspace: WorkspaceFeature.State) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Workspace", systemImage: "rectangle.stack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(workspace.color.color)
                    .frame(width: 4, height: 16)
                Text(workspace.name)
                    .font(.system(size: 13))
            }

            Text("\(workspace.panes.count) pane\(workspace.panes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func repoSection(_ workspace: WorkspaceFeature.State, activeID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Repositories", systemImage: "externaldrive")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if workspace.repoAssociations.isEmpty {
                Text("No repositories associated")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(workspace.repoAssociations) { assoc in
                    repoAssociationRow(assoc, activeID: activeID)
                }
            }

            Menu {
                Button(action: { isRepoPickerPresented = true }) {
                    Label("Add Repository", systemImage: "folder.badge.plus")
                }

                Button(action: { isWorktreePickerPresented = true }) {
                    Label("New Worktree", systemImage: "arrow.triangle.branch")
                }
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .disabled(store.repoRegistry.isEmpty)
        }
    }

    private func repoAssociationRow(_ assoc: RepoAssociation, activeID: UUID) -> some View {
        HStack(spacing: 6) {
            statusDot(for: assoc.id)

            VStack(alignment: .leading, spacing: 1) {
                if let repo = store.repoRegistry[id: assoc.repoID] {
                    Text(repo.name)
                        .font(.system(size: 12, weight: .medium))
                }
                if let branch = assoc.branchName {
                    Text(branch)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: {
                store.send(.workspaces(.element(
                    id: activeID,
                    action: .splitPaneAtPath(assoc.worktreePath)
                )))
            }) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open terminal at this path")
        }
        .contextMenu {
            Button("Remove", role: .destructive) {
                store.send(.removeWorktreeAssociation(
                    workspaceID: activeID,
                    associationID: assoc.id,
                    deleteWorktree: false
                ))
            }
            Button("Remove & Delete Worktree", role: .destructive) {
                store.send(.removeWorktreeAssociation(
                    workspaceID: activeID,
                    associationID: assoc.id,
                    deleteWorktree: true
                ))
            }
        }
    }

    private func statusDot(for associationID: UUID) -> some View {
        let status = store.gitStatuses[associationID] ?? .unknown
        let color: Color = switch status {
        case .unknown: .gray
        case .clean: .green
        case .dirty: .red
        }
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func paneSection(_ workspace: WorkspaceFeature.State, activeID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Panes", systemImage: "rectangle.split.2x1")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(workspace.panes) { pane in
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(pane.title ?? pane.label ?? "Shell")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    if pane.id == workspace.focusedPaneID {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                    }
                    if workspace.panes.count > 1 {
                        Button(action: {
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .closePane(pane.id)
                            )))
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Sheet for entering a branch name when creating a new worktree.
struct CreateWorktreeSheet: View {
    let repoName: String
    let workspaceSlug: String
    let worktreeBasePath: String
    @Binding var worktreeName: String
    @Binding var branchName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    private var isValid: Bool {
        !worktreeName.trimmingCharacters(in: .whitespaces).isEmpty
            && !branchName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Worktree")
                .font(.headline)

            Text("Create a worktree for **\(repoName)**")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Worktree name", text: $worktreeName)
                .textFieldStyle(.roundedBorder)

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if isValid { onCreate() } }

            Text("\(worktreeBasePath)/\(workspaceSlug)/\(worktreeName.isEmpty ? "<name>" : worktreeName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
