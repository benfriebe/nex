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
    @State private var newLabelText = ""
    @FocusState private var isLabelFieldFocused: Bool

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

                            // Labels
                            labelsSection(workspace, activeID: activeID)

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
                        worktreeBasePath: store.settings.resolvedWorktreeBasePath(
                            forRepoPath: store.repoRegistry[id: repoID]?.path
                        ),
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
                        },
                        onChangeRepo: store.repoRegistry.count > 1 ? {
                            worktreeRepoID = nil
                            DispatchQueue.main.async {
                                isWorktreePickerPresented = true
                            }
                        } : nil
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

    private func labelsSection(_ workspace: WorkspaceFeature.State, activeID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Labels", systemImage: "tag")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("inspector.labels.heading")

            if !workspace.labels.isEmpty {
                LabelFlowLayout(spacing: 4) {
                    ForEach(workspace.labels, id: \.self) { label in
                        LabelChip(text: label) {
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .removeLabel(label)
                            )))
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add label", text: $newLabelText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($isLabelFieldFocused)
                    .accessibilityIdentifier("inspector.labels.field")
                    .onSubmit { commitNewLabel(activeID: activeID) }

                let isEmpty = newLabelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    commitNewLabel(activeID: activeID)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspector.labels.add")
                .disabled(isEmpty)
            }
        }
    }

    private func commitNewLabel(activeID: UUID) {
        // Split on commas/newlines so users can paste comma-separated
        // tags ("backend, priority, blocked") in one shot. Single
        // entries (no separator) still flow through unchanged.
        let parts = newLabelText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0) }
        var sentAny = false
        for part in parts {
            let normalized = WorkspaceFeature.normalizeLabel(part)
            guard !normalized.isEmpty else { continue }
            store.send(.workspaces(.element(id: activeID, action: .addLabel(normalized))))
            sentAny = true
        }
        guard sentAny else { return }
        newLabelText = ""
        isLabelFieldFocused = true
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

                Button(action: {
                    let workspaceRepoIDs = Set(workspace.repoAssociations.map(\.repoID))
                    let candidateID: UUID? = if workspaceRepoIDs.count == 1 {
                        workspaceRepoIDs.first
                    } else if store.repoRegistry.count == 1 {
                        store.repoRegistry.first?.id
                    } else {
                        nil
                    }
                    if let candidateID, store.repoRegistry[id: candidateID] != nil {
                        worktreeRepoID = candidateID
                        worktreeName = ""
                        worktreeBranchName = ""
                    } else {
                        isWorktreePickerPresented = true
                    }
                }) {
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
                HStack(spacing: 6) {
                    if let branch = assoc.branchName {
                        Text(branch)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    diffStatsLabel(for: assoc.id)
                }
            }

            Spacer()

            InspectorIconButton(icon: "plusminus", tooltip: "Show diff for this repo") {
                store.send(.openDiffPath(
                    repoPath: assoc.worktreePath,
                    targetPath: nil,
                    fromPaneID: nil
                ))
            }

            InspectorIconButton(
                icon: "terminal",
                tooltip: "Open terminal at this path (Shift: split vertical)"
            ) {
                let direction: PaneLayout.SplitDirection =
                    NSEvent.modifierFlags.contains(.shift) ? .vertical : .horizontal
                store.send(.workspaces(.element(
                    id: activeID,
                    action: .splitPaneAtPath(assoc.worktreePath, direction: direction)
                )))
            }
        }
        .contentShape(Rectangle())
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

    @ViewBuilder
    private func diffStatsLabel(for associationID: UUID) -> some View {
        if case .dirty(let files, let adds, let dels) = store.gitStatuses[associationID] ?? .unknown {
            HStack(spacing: 4) {
                Text("\(files) file\(files == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if adds > 0 {
                    Text("+\(adds)").foregroundStyle(.green)
                }
                if dels > 0 {
                    Text("-\(dels)").foregroundStyle(.red)
                }
            }
            .font(.system(size: 10, design: .monospaced))
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
    let worktreeBasePath: String
    @Binding var worktreeName: String
    @Binding var branchName: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    var onChangeRepo: (() -> Void)?

    @State private var branchEdited = false

    private var isValid: Bool {
        !worktreeName.trimmingCharacters(in: .whitespaces).isEmpty
            && !branchName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Worktree")
                .font(.headline)

            HStack(spacing: 6) {
                Text("Create a worktree for **\(repoName)**")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let onChangeRepo {
                    Button("Change", action: onChangeRepo)
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Worktree name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $worktreeName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: worktreeName) { _, new in
                        if !branchEdited { branchName = new }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Branch name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: branchName) { _, new in
                        branchEdited = (new != worktreeName)
                    }
                    .onSubmit { if isValid { onCreate() } }
            }

            Text("\(worktreeBasePath)/\(worktreeName.isEmpty ? "<name>" : worktreeName)")
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

/// Compact icon button used in the inspector for per-repo actions. Adds a
/// hover background, brightened foreground, and pointing-hand cursor since
/// `.buttonStyle(.plain)` provides none of these by default.
private struct InspectorIconButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background {
                    if isHovered {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
