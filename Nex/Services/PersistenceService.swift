import ComposableArchitecture
import Foundation
import GRDB

/// Debounced state persistence to SQLite via GRDB.
/// Coalesces rapid state changes into a single write.
actor PersistenceService {
    private let db: DatabaseService
    private var pendingTask: Task<Void, Never>?
    private let debounceInterval: Duration = .milliseconds(500)

    init(db: DatabaseService) {
        self.db = db
    }

    // MARK: - Save (debounced)

    func save(snapshot: PersistenceSnapshot) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.writeRecords(
                repoRecords: snapshot.repoRecords,
                wsRecords: snapshot.wsRecords,
                pnRecords: snapshot.pnRecords,
                arRecords: snapshot.arRecords,
                groupRecords: snapshot.groupRecords,
                stateRecords: snapshot.stateRecords
            )
        }
    }

    private func writeRecords(
        repoRecords: [RepoRecord],
        wsRecords: [WorkspaceRecord],
        pnRecords: [PaneRecord],
        arRecords: [RepoAssociationRecord],
        groupRecords: [WorkspaceGroupRecord],
        stateRecords: [AppStateRecord]
    ) async {
        do {
            try await db.writer.write { db in
                try RepoAssociationRecord.deleteAll(db)
                try PaneRecord.deleteAll(db)
                try WorkspaceRecord.deleteAll(db)
                try RepoRecord.deleteAll(db)
                try WorkspaceGroupRecord.deleteAll(db)

                for record in repoRecords {
                    try record.insert(db)
                }
                for record in wsRecords {
                    try record.insert(db)
                }
                for record in pnRecords {
                    try record.insert(db)
                }
                for record in arRecords {
                    try record.insert(db)
                }
                for record in groupRecords {
                    try record.insert(db)
                }
                for record in stateRecords {
                    try record.save(db)
                }
            }
        } catch {
            print("PersistenceService: write failed — \(error)")
        }
    }

    // MARK: - Load

    struct LoadResult: @unchecked Sendable {
        var workspaces: IdentifiedArrayOf<WorkspaceFeature.State>
        var groups: IdentifiedArrayOf<WorkspaceGroup>
        var topLevelOrder: [SidebarID]
        var activeWorkspaceID: UUID?
        var repoRegistry: IdentifiedArrayOf<Repo>
    }

    func load() -> LoadResult {
        do {
            return try db.writer.read { db in
                // Load repos
                let repoRecords = try RepoRecord.fetchAll(db)
                var repoRegistry = IdentifiedArrayOf<Repo>()
                for rr in repoRecords {
                    guard let repoID = UUID(uuidString: rr.id) else { continue }
                    let repo = Repo(
                        id: repoID,
                        path: rr.path,
                        name: rr.name,
                        remoteURL: rr.remoteURL,
                        lastAccessedAt: Date(timeIntervalSince1970: rr.lastAccessedAt),
                        isAutoDiscovered: rr.isAutoDiscovered
                    )
                    repoRegistry.append(repo)
                }

                // Load workspaces
                let workspaceRecords = try WorkspaceRecord
                    .order(Column("sortOrder"))
                    .fetchAll(db)

                var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()

                for record in workspaceRecords {
                    guard let wsID = UUID(uuidString: record.id) else { continue }

                    let paneRecords = try PaneRecord
                        .filter(Column("workspaceID") == record.id)
                        .fetchAll(db)

                    var panes = IdentifiedArrayOf<Pane>()
                    for pr in paneRecords {
                        guard let paneID = UUID(uuidString: pr.id) else { continue }
                        let paneType = PaneType(rawValue: pr.type) ?? .shell
                        let pane = Pane(
                            id: paneID,
                            label: pr.label,
                            type: paneType,
                            workingDirectory: pr.workingDirectory,
                            filePath: pr.filePath,
                            isEditing: paneType == .scratchpad,
                            scratchpadContent: pr.content,
                            status: PaneStatus(rawValue: pr.status) ?? .idle,
                            claudeSessionID: pr.claudeSessionID,
                            createdAt: Date(timeIntervalSince1970: pr.createdAt),
                            lastActivityAt: Date(timeIntervalSince1970: pr.lastActivityAt)
                        )
                        panes.append(pane)
                    }

                    // Load repo associations for this workspace
                    let assocRecords = try RepoAssociationRecord
                        .filter(Column("workspaceID") == record.id)
                        .fetchAll(db)

                    var repoAssociations = IdentifiedArrayOf<RepoAssociation>()
                    for ar in assocRecords {
                        guard let assocID = UUID(uuidString: ar.id),
                              let repoID = UUID(uuidString: ar.repoID) else { continue }
                        let assoc = RepoAssociation(
                            id: assocID,
                            repoID: repoID,
                            worktreePath: ar.worktreePath,
                            branchName: ar.branchName,
                            isAutoDetected: ar.isAutoDetected
                        )
                        repoAssociations.append(assoc)
                    }

                    let layout: PaneLayout = if let data = record.layoutJSON.data(using: .utf8) {
                        (try? JSONDecoder().decode(PaneLayout.self, from: data)) ?? .empty
                    } else {
                        .empty
                    }

                    let color = WorkspaceColor(rawValue: record.color) ?? .blue
                    let focusedID = record.focusedPaneID.flatMap(UUID.init)

                    // Generate slug for legacy workspaces that don't have one
                    let slug = record.slug.isEmpty
                        ? WorkspaceFeature.State.makeSlug(from: record.name, id: wsID)
                        : record.slug

                    let labels: [String] = (record.labelsJSON.data(using: .utf8))
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                        ?? []

                    let workspace = WorkspaceFeature.State(
                        id: wsID,
                        name: record.name,
                        slug: slug,
                        color: color,
                        panes: panes,
                        layout: layout,
                        focusedPaneID: focusedID,
                        repoAssociations: repoAssociations,
                        createdAt: Date(timeIntervalSince1970: record.createdAt),
                        lastAccessedAt: Date(timeIntervalSince1970: record.lastAccessedAt),
                        labels: labels
                    )
                    workspaces.append(workspace)
                }

                let activeIDStr = try AppStateRecord
                    .filter(Column("key") == "activeWorkspaceID")
                    .fetchOne(db)?
                    .value
                let activeID = activeIDStr.flatMap(UUID.init)

                // Load workspace groups
                let groupRecords = try WorkspaceGroupRecord
                    .order(Column("sortOrder"))
                    .fetchAll(db)
                var groups = IdentifiedArrayOf<WorkspaceGroup>()
                for gr in groupRecords {
                    guard let groupID = UUID(uuidString: gr.id) else { continue }
                    let childOrder: [UUID] = (gr.childOrderJSON.data(using: .utf8))
                        .flatMap { try? JSONDecoder().decode([UUID].self, from: $0) }
                        ?? []
                    let color = gr.color.flatMap { WorkspaceColor(rawValue: $0) }
                    let icon = gr.icon.flatMap { GroupIcon(storageString: $0) }
                    let group = WorkspaceGroup(
                        id: groupID,
                        name: gr.name,
                        color: color,
                        isCollapsed: gr.isCollapsed,
                        childOrder: childOrder,
                        createdAt: Date(timeIntervalSince1970: gr.createdAt),
                        icon: icon
                    )
                    groups.append(group)
                }

                // Load topLevelOrder; empty array signals legacy DB (caller backfills)
                let topLevelOrderJSON = try AppStateRecord
                    .filter(Column("key") == "topLevelOrder")
                    .fetchOne(db)?
                    .value
                let topLevelOrder: [SidebarID] = topLevelOrderJSON
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([SidebarID].self, from: $0) }
                    ?? []

                return LoadResult(
                    workspaces: workspaces,
                    groups: groups,
                    topLevelOrder: topLevelOrder,
                    activeWorkspaceID: activeID,
                    repoRegistry: repoRegistry
                )
            }
        } catch {
            print("PersistenceService: load failed — \(error)")
            return LoadResult(
                workspaces: [],
                groups: [],
                topLevelOrder: [],
                activeWorkspaceID: nil,
                repoRegistry: []
            )
        }
    }
}

// MARK: - Sendable snapshot for crossing isolation boundaries

/// Pre-built database records that can safely cross actor/Sendable boundaries.
/// Created from non-Sendable TCA state in the reducer, then passed to the actor.
struct PersistenceSnapshot {
    let repoRecords: [RepoRecord]
    let wsRecords: [WorkspaceRecord]
    let pnRecords: [PaneRecord]
    let arRecords: [RepoAssociationRecord]
    let groupRecords: [WorkspaceGroupRecord]
    let stateRecords: [AppStateRecord]

    init(state: AppReducer.State) {
        repoRecords = state.repoRegistry.map { repo in
            RepoRecord(
                id: repo.id.uuidString,
                path: repo.path,
                name: repo.name,
                remoteURL: repo.remoteURL,
                lastAccessedAt: repo.lastAccessedAt.timeIntervalSince1970,
                isAutoDiscovered: repo.isAutoDiscovered
            )
        }

        wsRecords = state.workspaces.enumerated().map { index, workspace in
            let layoutToSave = workspace.savedLayout ?? workspace.layout
            let layoutData = (try? JSONEncoder().encode(layoutToSave)) ?? Data()
            let layoutJSON = String(data: layoutData, encoding: .utf8) ?? "null"
            let labelsData = (try? JSONEncoder().encode(workspace.labels)) ?? Data()
            let labelsJSON = String(data: labelsData, encoding: .utf8) ?? "[]"
            return WorkspaceRecord(
                id: workspace.id.uuidString,
                name: workspace.name,
                slug: workspace.slug,
                color: workspace.color.rawValue,
                layoutJSON: layoutJSON,
                focusedPaneID: workspace.focusedPaneID?.uuidString,
                createdAt: workspace.createdAt.timeIntervalSince1970,
                lastAccessedAt: workspace.lastAccessedAt.timeIntervalSince1970,
                sortOrder: index,
                labelsJSON: labelsJSON
            )
        }

        pnRecords = state.workspaces.flatMap { workspace in
            workspace.panes.map { pane in
                PaneRecord(
                    id: pane.id.uuidString,
                    workspaceID: workspace.id.uuidString,
                    label: pane.label,
                    type: pane.type.rawValue,
                    workingDirectory: pane.workingDirectory,
                    filePath: pane.filePath,
                    content: pane.scratchpadContent,
                    claudeSessionID: pane.claudeSessionID,
                    status: pane.status.rawValue,
                    createdAt: pane.createdAt.timeIntervalSince1970,
                    lastActivityAt: pane.lastActivityAt.timeIntervalSince1970
                )
            }
        }

        arRecords = state.workspaces.flatMap { workspace in
            workspace.repoAssociations.map { assoc in
                RepoAssociationRecord(
                    id: assoc.id.uuidString,
                    workspaceID: workspace.id.uuidString,
                    repoID: assoc.repoID.uuidString,
                    worktreePath: assoc.worktreePath,
                    branchName: assoc.branchName,
                    isAutoDetected: assoc.isAutoDetected
                )
            }
        }

        groupRecords = state.groups.enumerated().map { index, group in
            let childData = (try? JSONEncoder().encode(group.childOrder)) ?? Data()
            let childJSON = String(data: childData, encoding: .utf8) ?? "[]"
            return WorkspaceGroupRecord(
                id: group.id.uuidString,
                name: group.name,
                color: group.color?.rawValue,
                isCollapsed: group.isCollapsed,
                childOrderJSON: childJSON,
                createdAt: group.createdAt.timeIntervalSince1970,
                sortOrder: index,
                icon: group.icon?.storageString
            )
        }

        let topLevelData = (try? JSONEncoder().encode(state.topLevelOrder)) ?? Data()
        let topLevelJSON = String(data: topLevelData, encoding: .utf8) ?? "[]"
        stateRecords = [
            AppStateRecord(
                key: "activeWorkspaceID",
                value: state.activeWorkspaceID?.uuidString
            ),
            AppStateRecord(
                key: "topLevelOrder",
                value: topLevelJSON
            )
        ]
    }
}

// MARK: - TCA Dependency

extension PersistenceService: DependencyKey {
    static var liveValue: PersistenceService {
        do {
            let db = try DatabaseService()
            return PersistenceService(db: db)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    static var testValue: PersistenceService {
        do {
            let db = try DatabaseService(inMemory: true)
            return PersistenceService(db: db)
        } catch {
            fatalError("Failed to initialize test database: \(error)")
        }
    }
}

extension DependencyValues {
    var persistenceService: PersistenceService {
        get { self[PersistenceService.self] }
        set { self[PersistenceService.self] = newValue }
    }
}
