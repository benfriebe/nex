import ComposableArchitecture
import Foundation
import GRDB
import UserNotifications

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
    /// The most recently scheduled, not-yet-written snapshot. Kept
    /// separately from `pendingTask` so `flushNow()` can perform the
    /// write immediately (skipping the debounce sleep) instead of
    /// racing/duplicating the timer.
    private var pendingSnapshot: PersistenceSnapshot?
    private let debounceInterval: Duration = .milliseconds(500)

    /// Set once `load()` has completed without throwing (including a
    /// legitimate empty-DB first launch). `writeRecords` refuses to run
    /// its destructive clear-and-reinsert until this is true, so a
    /// transient/failed load can never be mistaken for first-launch and
    /// silently overwrite intact data (issue #267).
    private var hasLoadedSuccessfully = false

    /// Consecutive write failures since the last success. Used to fire a
    /// single desktop notification once a failing writer looks
    /// persistent rather than alerting on every transient blip, and to
    /// avoid re-notifying every debounce cycle while it stays broken.
    private var consecutiveWriteFailures = 0
    private static let writeFailureNotificationThreshold = 3

    init(db: DatabaseService) {
        self.db = db
    }

    // MARK: - Save (debounced)

    func save(snapshot: PersistenceSnapshot) {
        guard hasLoadedSuccessfully else {
            print("PersistenceService: skipping save — no successful load yet, refusing to risk overwriting real data")
            return
        }
        pendingSnapshot = snapshot
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Perform the pending write (if any) right now, bypassing the
    /// debounce sleep.
    private func flush() async {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        pendingTask = nil
        await writeRecords(
            repoRecords: snapshot.repoRecords,
            wsRecords: snapshot.wsRecords,
            pnRecords: snapshot.pnRecords,
            arRecords: snapshot.arRecords,
            groupRecords: snapshot.groupRecords,
            stateRecords: snapshot.stateRecords
        )
    }

    /// Cancels any pending debounce timer and performs the write
    /// immediately. Wired via `QuitGate.flushPersistence` so the last
    /// ~500ms of changes before quit aren't discarded when the process
    /// exits before the debounced `Task` fires (issue #267).
    func flushNow() async {
        pendingTask?.cancel()
        await flush()
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
            consecutiveWriteFailures = 0
        } catch {
            consecutiveWriteFailures += 1
            print("PersistenceService: write failed (\(consecutiveWriteFailures) in a row) — \(error)")
            notifyIfPersistentFailure(error: error)
        }
    }

    /// Fires a single desktop notification once failures cross
    /// `writeFailureNotificationThreshold`, so a disk-full/read-only-
    /// volume/corrupt-DB writer that keeps failing doesn't silently
    /// discard every state change with only an invisible `print` (issue
    /// #267). Deliberately fires only once per failure streak — it
    /// resets when a write succeeds again, so a later streak still
    /// notifies.
    private func notifyIfPersistentFailure(error _: Error) {
        guard consecutiveWriteFailures == Self.writeFailureNotificationThreshold else { return }
        let content = UNMutableNotificationContent()
        content.title = "Nex can't save your changes"
        content.body = "Repeated errors writing to disk — check available disk space and permissions. Recent changes may not survive a restart."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "nex-persistence-write-failure",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Load

    struct LoadResult: @unchecked Sendable {
        var workspaces: IdentifiedArrayOf<WorkspaceFeature.State>
        var groups: IdentifiedArrayOf<WorkspaceGroup>
        var topLevelOrder: [SidebarID]
        var activeWorkspaceID: UUID?
        var repoRegistry: IdentifiedArrayOf<Repo>
    }

    /// `load()`'s result. A failed read is kept distinct from a
    /// successful-but-empty read (genuine first launch) — conflating the
    /// two used to make a transient/recoverable load error (a locked DB,
    /// a corrupt row, an I/O hiccup) look exactly like first launch, and
    /// the app would then create a Default workspace and overwrite the
    /// still-present real data on its very next save (issue #267).
    enum LoadOutcome: @unchecked Sendable {
        case success(LoadResult)
        case failed(Error)
    }

    func load() -> LoadOutcome {
        do {
            let result = try loadResult()
            hasLoadedSuccessfully = true
            return .success(result)
        } catch {
            print("PersistenceService: load failed — \(error)")
            return .failed(error)
        }
    }

    private func loadResult() throws -> LoadResult {
        try db.writer.read { db in
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

                var layout: PaneLayout = if let data = record.layoutJSON.data(using: .utf8) {
                    (try? JSONDecoder().decode(PaneLayout.self, from: data)) ?? .empty
                } else {
                    .empty
                }

                // A corrupt/truncated layoutJSON blob decodes to
                // `.empty` while the pane rows still load fine —
                // without this, the workspace's panes become
                // invisible (PTYs keep running off-screen) and the
                // next debounced save persists the empty tree over
                // them, destroying the arrangement for good. Rebuild
                // a default layout from the panes we actually have
                // whenever the decoded tree doesn't match them
                // (issue #267).
                if Set(layout.allPaneIDs) != Set(panes.map(\.id)) {
                    layout = PredefinedLayout.tiled.buildLayout(for: panes.map(\.id))
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

            return LoadResult(
                workspaces: workspaces,
                groups: groups,
                topLevelOrder: topLevelOrder,
                activeWorkspaceID: activeID,
                repoRegistry: repoRegistry
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
                    webIsPrivate: webIsPrivate
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
    /// A stored `let`, not a computed property — `DatabaseService()` opens
    /// a real GRDB `DatabasePool` against `nex.db`, so re-running this on
    /// every access would spin up a second, independent connection with
    /// its own actor state (in particular its own debounced-save queue,
    /// breaking `QuitGate.flushPersistence`'s ability to flush the
    /// instance the reducer actually writes through). `DatabaseService`'s
    /// init already quarantines an unreadable/corrupt DB and retries once
    /// with a fresh file, so reaching `catch` here means even that
    /// recovery failed (e.g. an unwritable Application Support
    /// directory) — genuinely unrecoverable.
    static let liveValue: PersistenceService = {
        do {
            let db = try DatabaseService()
            return PersistenceService(db: db)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }()

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
