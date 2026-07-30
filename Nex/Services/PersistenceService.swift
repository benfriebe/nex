import ComposableArchitecture
import Foundation
import GRDB

/// Shared coders for the web-tabs JSON column. JSONEncoder/Decoder are
/// stateless and reusable; instantiating fresh per pane on every
/// debounced save adds noticeable churn when many web panes are open.
private let webTabsEncoder = JSONEncoder()
private let webTabsDecoder = JSONDecoder()

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
                stateRecords: snapshot.stateRecords,
                pipelineRunRecords: snapshot.pipelineRunRecords,
                pipelineNodeRunRecords: snapshot.pipelineNodeRunRecords
            )
        }
    }

    private func writeRecords(
        repoRecords: [RepoRecord],
        wsRecords: [WorkspaceRecord],
        pnRecords: [PaneRecord],
        arRecords: [RepoAssociationRecord],
        groupRecords: [WorkspaceGroupRecord],
        stateRecords: [AppStateRecord],
        pipelineRunRecords: [PipelineRunRecord],
        pipelineNodeRunRecords: [PipelineNodeRunRecord]
    ) async {
        do {
            try await db.writer.write { db in
                try RepoAssociationRecord.deleteAll(db)
                try PaneRecord.deleteAll(db)
                try WorkspaceRecord.deleteAll(db)
                try RepoRecord.deleteAll(db)
                try WorkspaceGroupRecord.deleteAll(db)
                try PipelineNodeRunRecord.deleteAll(db)
                try PipelineRunRecord.deleteAll(db)

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
                for record in pipelineRunRecords {
                    try record.insert(db)
                }
                for record in pipelineNodeRunRecords {
                    try record.insert(db)
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
        var pipelineRuns: [PipelineRun]
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
                    var webPanes: [UUID: WebPaneState] = [:]
                    var pipelinePanes: [UUID: PipelinePaneState] = [:]
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
                            agentSessionID: pr.agentSessionID,
                            agentKind: pr.agentKind.flatMap(AgentKind.init(rawValue:)),
                            createdAt: Date(timeIntervalSince1970: pr.createdAt),
                            lastActivityAt: Date(timeIntervalSince1970: pr.lastActivityAt)
                        )
                        panes.append(pane)
                        if paneType == .web {
                            // Prefer the full tabs JSON; fall back to
                            // the legacy single-tab `webURL` for rows
                            // written before the v13 migration.
                            // Empty/nil = blank pane (private pane on
                            // restore).
                            var tabs: [WebTab] = []
                            if let json = pr.webTabsJSON,
                               !json.isEmpty,
                               let data = json.data(using: .utf8),
                               let decoded = try? webTabsDecoder.decode([WebTab].self, from: data) {
                                tabs = decoded
                            } else if let url = pr.webURL, !url.isEmpty {
                                tabs = [WebTab(url: url)]
                            }
                            let activeID = pr.webActiveTabID
                                .flatMap { UUID(uuidString: $0) }
                                ?? tabs.first?.id
                            webPanes[paneID] = WebPaneState(
                                tabs: tabs,
                                activeTabID: activeID,
                                isPrivate: pr.webIsPrivate ?? false
                            )
                        }
                        if paneType == .pipeline {
                            // The document itself is not persisted —
                            // just the name. `AppReducer`'s `.stateLoaded`
                            // handler re-loads it from YAML so the pane
                            // doesn't come back empty after a restart.
                            pipelinePanes[paneID] = PipelinePaneState(pipelineName: pr.pipelineName)
                        }
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

                    let icon = record.icon.flatMap { GroupIcon(storageString: $0) }

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
                        labels: labels,
                        icon: icon,
                        webPanes: webPanes,
                        pipelinePanes: pipelinePanes,
                        profileName: record.profileName
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

                // Load pipeline runs. A node run left non-terminal by an
                // unclean shutdown comes back `.interrupted`, and its run
                // is forced to `.paused` — `nex pipeline resume` (a
                // follow-up phase) is the only way an interrupted run
                // re-engages (issue section 5).
                let pipelineRunRecords = try PipelineRunRecord.fetchAll(db)
                let pipelineNodeRunRecords = try PipelineNodeRunRecord.fetchAll(db)
                var nodeRunsByRunID: [String: [PipelineNodeRun]] = [:]
                for nr in pipelineNodeRunRecords {
                    guard let nrID = UUID(uuidString: nr.id) else { continue }
                    let warnings: [String] = (nr.warningsJSON.data(using: .utf8))
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                    let nodeRun = PipelineNodeRun(
                        id: nrID,
                        nodeID: nr.nodeID,
                        attempt: nr.attempt,
                        paneID: nr.paneID.flatMap { UUID(uuidString: $0) },
                        agentSessionID: nr.agentSessionID,
                        status: PipelineNodeRunStatus(rawValue: nr.status) ?? .interrupted,
                        summary: nr.summary,
                        outputPath: nr.outputPath,
                        warnings: warnings,
                        startedAt: Date(timeIntervalSince1970: nr.startedAt),
                        updatedAt: Date(timeIntervalSince1970: nr.updatedAt),
                        completedAt: nr.completedAt.map { Date(timeIntervalSince1970: $0) }
                    )
                    nodeRunsByRunID[nr.runID, default: []].append(nodeRun)
                }

                var pipelineRuns: [PipelineRun] = []
                for rr in pipelineRunRecords {
                    guard let runID = UUID(uuidString: rr.id),
                          let definition = try? PipelineDefinition.fromYAML(rr.definitionYAML, id: rr.definitionID)
                    else { continue }
                    let inputs: [String: String] = (rr.inputsJSON.data(using: .utf8))
                        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                    let edgeTraversals: [String: Int] = (rr.edgeTraversalsJSON.data(using: .utf8))
                        .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]

                    var restoredNodeRuns = IdentifiedArrayOf<PipelineNodeRun>()
                    var wasInterrupted = false
                    for var nodeRun in nodeRunsByRunID[rr.id] ?? [] {
                        if !nodeRun.status.isTerminal {
                            wasInterrupted = true
                            nodeRun.status = .interrupted
                        }
                        restoredNodeRuns.append(nodeRun)
                    }

                    var status = PipelineRunStatus(rawValue: rr.status) ?? .paused
                    var statusDetail = rr.statusDetail
                    if wasInterrupted, !status.isTerminal {
                        status = .paused
                        // Must carry the `PipelineRunPauseReason` prefix
                        // convention — `nex pipeline resume` parses it to
                        // pick the right re-engagement message (issue
                        // #282 phase 7).
                        statusDetail = PipelineRunPauseReason.detail(
                            .appRestart, "interrupted by app restart — run `nex pipeline resume` to re-engage"
                        )
                    }

                    pipelineRuns.append(PipelineRun(
                        id: runID,
                        definitionID: rr.definitionID,
                        definitionSnapshot: definition,
                        status: status,
                        statusDetail: statusDetail,
                        location: PipelineLocation(rawValue: rr.location) ?? .current,
                        workspaceID: rr.workspaceID.flatMap { UUID(uuidString: $0) },
                        worktreePath: rr.worktreePath,
                        runDir: rr.runDir,
                        inputs: inputs,
                        nodeRuns: restoredNodeRuns,
                        currentNodeRunID: rr.currentNodeRunID.flatMap { UUID(uuidString: $0) },
                        edgeTraversals: edgeTraversals,
                        createdAt: Date(timeIntervalSince1970: rr.createdAt),
                        updatedAt: Date(timeIntervalSince1970: rr.updatedAt),
                        completedAt: rr.completedAt.map { Date(timeIntervalSince1970: $0) }
                    ))
                }

                return LoadResult(
                    workspaces: workspaces,
                    groups: groups,
                    topLevelOrder: topLevelOrder,
                    activeWorkspaceID: activeID,
                    repoRegistry: repoRegistry,
                    pipelineRuns: pipelineRuns
                )
            }
        } catch {
            print("PersistenceService: load failed — \(error)")
            return LoadResult(
                workspaces: [],
                groups: [],
                topLevelOrder: [],
                activeWorkspaceID: nil,
                repoRegistry: [],
                pipelineRuns: []
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
    let pipelineRunRecords: [PipelineRunRecord]
    let pipelineNodeRunRecords: [PipelineNodeRunRecord]

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
                labelsJSON: labelsJSON,
                icon: workspace.icon?.storageString,
                profileName: workspace.profileName
            )
        }

        pnRecords = state.workspaces.flatMap { workspace in
            workspace.panes.map { pane in
                // Write the full tab list as JSON and the active tab
                // id. `webURL` is also written as a legacy fallback
                // for any loader that pre-dates the v13 migration.
                // Private panes intentionally drop tab contents so
                // restart restores them blank, but the
                // `webIsPrivate` flag itself is always persisted so
                // the coordinator rebuilds with a nonPersistent
                // store on the next load.
                var webURL: String?
                var webTabsJSON: String?
                var webActiveTabID: String?
                var webIsPrivate: Bool?
                if pane.type == .web,
                   let webState = workspace.webPanes[pane.id] {
                    webIsPrivate = webState.isPrivate
                    if !webState.isPrivate {
                        webURL = webState.activeTab?.url
                        if !webState.tabs.isEmpty,
                           let data = try? webTabsEncoder.encode(webState.tabs),
                           let json = String(data: data, encoding: .utf8) {
                            webTabsJSON = json
                        }
                        webActiveTabID = webState.activeTabID?.uuidString
                    }
                }
                let pipelineName: String? = pane.type == .pipeline
                    ? workspace.pipelinePanes[pane.id]?.pipelineName
                    : nil
                return PaneRecord(
                    id: pane.id.uuidString,
                    workspaceID: workspace.id.uuidString,
                    label: pane.label,
                    type: pane.type.rawValue,
                    workingDirectory: pane.workingDirectory,
                    filePath: pane.filePath,
                    content: pane.scratchpadContent,
                    agentSessionID: pane.agentSessionID,
                    agentKind: pane.agentKind?.rawValue,
                    status: pane.status.rawValue,
                    createdAt: pane.createdAt.timeIntervalSince1970,
                    lastActivityAt: pane.lastActivityAt.timeIntervalSince1970,
                    webURL: webURL,
                    webTabsJSON: webTabsJSON,
                    webActiveTabID: webActiveTabID,
                    webIsPrivate: webIsPrivate,
                    pipelineName: pipelineName
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

        let prunedRuns = PipelineRun.pruned(state.pipelines.runs)
        pipelineRunRecords = prunedRuns.map { run in
            let yaml = (try? run.definitionSnapshot.toYAML()) ?? ""
            let inputsData = (try? JSONEncoder().encode(run.inputs)) ?? Data()
            let edgeData = (try? JSONEncoder().encode(run.edgeTraversals)) ?? Data()
            return PipelineRunRecord(
                id: run.id.uuidString,
                definitionID: run.definitionID,
                definitionYAML: yaml,
                status: run.status.rawValue,
                statusDetail: run.statusDetail,
                location: run.location.rawValue,
                workspaceID: run.workspaceID?.uuidString,
                worktreePath: run.worktreePath,
                runDir: run.runDir,
                inputsJSON: String(data: inputsData, encoding: .utf8) ?? "{}",
                edgeTraversalsJSON: String(data: edgeData, encoding: .utf8) ?? "{}",
                currentNodeRunID: run.currentNodeRunID?.uuidString,
                createdAt: run.createdAt.timeIntervalSince1970,
                updatedAt: run.updatedAt.timeIntervalSince1970,
                completedAt: run.completedAt?.timeIntervalSince1970
            )
        }
        pipelineNodeRunRecords = prunedRuns.flatMap { run in
            run.nodeRuns.map { nodeRun in
                let warningsData = (try? JSONEncoder().encode(nodeRun.warnings)) ?? Data()
                return PipelineNodeRunRecord(
                    id: nodeRun.id.uuidString,
                    runID: run.id.uuidString,
                    nodeID: nodeRun.nodeID,
                    attempt: nodeRun.attempt,
                    paneID: nodeRun.paneID?.uuidString,
                    agentSessionID: nodeRun.agentSessionID,
                    status: nodeRun.status.rawValue,
                    summary: nodeRun.summary,
                    outputPath: nodeRun.outputPath,
                    warningsJSON: String(data: warningsData, encoding: .utf8) ?? "[]",
                    startedAt: nodeRun.startedAt.timeIntervalSince1970,
                    updatedAt: nodeRun.updatedAt.timeIntervalSince1970,
                    completedAt: nodeRun.completedAt?.timeIntervalSince1970
                )
            }
        }
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
