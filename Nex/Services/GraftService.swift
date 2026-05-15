import ComposableArchitecture
import Foundation

/// Status of an in-flight graft session.
enum GraftSessionStatus: Equatable {
    case starting
    case watching
    case syncing
    case error(String)
}

struct GraftLogEntry: Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let message: String

    enum Kind: Equatable {
        case info
        case sync(filesChanged: Int)
        case error
    }

    init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
    }
}

struct GraftSession: Equatable, Identifiable {
    var id: UUID
    var worktreePath: String
    var parentRepoRoot: String
    var branch: String
    var status: GraftSessionStatus
    var stashRef: String?
    var lastSync: Date?
    var recentLog: [GraftLogEntry]
}

enum GraftSessionEvent: Equatable {
    case started(GraftSession)
    case updated(GraftSession)
    case stopped(UUID)
}

struct GraftOrphan: Equatable, Identifiable {
    var id: UUID
    var parentRepoRoot: String
    var worktreePath: String
    var stashRef: String?
}

enum GraftError: Error, Equatable {
    case alreadyActive(parentRepoRoot: String)
    case repoBusy(state: String)
    case missingWorktree(worktreePath: String)
    case branchResolutionFailed(worktreePath: String)
    case stashPopConflict(stashRef: String, underlying: String)
    case unknown(String)
}

struct GraftService {
    var start: @Sendable (_ association: RepoAssociation) async throws -> GraftSession
    var stop: @Sendable (_ associationID: UUID) async throws -> Void
    var activeSessions: @Sendable () async -> [GraftSession]
    var updates: @Sendable () -> AsyncStream<GraftSessionEvent>
    var detectOrphans: @Sendable (_ parentRepoRoots: [String]) async -> [GraftOrphan]
    var recoverOrphan: @Sendable (_ orphan: GraftOrphan) async throws -> Void
    var dismissOrphan: @Sendable (_ orphan: GraftOrphan) async -> Void
}

// MARK: - Live impl

/// Owns the active graft sessions and serialises start/stop/sync work.
/// State is held in plain dictionaries gated by `NSLock` to match the
/// existing pattern (`GitHeadWatcher`, `RecursiveFSWatcher`).
final class GraftServiceImpl: Sendable {
    static let breadcrumbName = "nex-graft-active"

    private let gitService: GitService
    private let watcher: RecursiveFSWatcher
    private let debounce: DispatchTimeInterval
    private let logCap: Int = 100

    private let lock = NSLock()
    private nonisolated(unsafe) var sessions: [UUID: GraftSession] = [:]
    private nonisolated(unsafe) var watcherTasks: [UUID: Task<Void, Never>] = [:]
    /// Canonicalised `parentRepoRoot` paths that currently hold a graft
    /// session. A second association targeting the same root is rejected
    /// with `GraftError.alreadyActive`.
    private nonisolated(unsafe) var busyRoots: Set<String> = []
    private nonisolated(unsafe) var subscribers: [UUID: AsyncStream<GraftSessionEvent>.Continuation] = [:]

    init(
        gitService: GitService = .live,
        watcher: RecursiveFSWatcher = RecursiveFSWatcher(),
        debounce: DispatchTimeInterval = .milliseconds(500)
    ) {
        self.gitService = gitService
        self.watcher = watcher
        self.debounce = debounce
    }

    // MARK: - Start

    func start(_ association: RepoAssociation) async throws -> GraftSession {
        let worktreePath = association.worktreePath
        guard let info = await gitService.resolveRepoRoot(worktreePath) else {
            throw GraftError.missingWorktree(worktreePath: worktreePath)
        }
        let parentRepoRoot = canonicalize(info.parentRepoRoot)

        // Reject if the parent root is already being grafted into.
        try lock.withLock {
            if busyRoots.contains(parentRepoRoot) {
                throw GraftError.alreadyActive(parentRepoRoot: parentRepoRoot)
            }
            busyRoots.insert(parentRepoRoot)
        }

        let state: RepoState
        do {
            state = try await gitService.repoState(parentRepoRoot)
        } catch {
            releaseBusy(parentRepoRoot)
            throw error
        }
        guard state == .clean else {
            releaseBusy(parentRepoRoot)
            throw GraftError.repoBusy(state: describe(state))
        }

        // Stash any uncommitted changes in the parent root. The
        // breadcrumb records the resulting SHA so `stop` pops the
        // exact stash even if other stashes are pushed in the
        // meantime.
        var stashRef: String?
        do {
            let parentStatus = try await gitService.getStatus(parentRepoRoot)
            if case .dirty = parentStatus {
                stashRef = try await gitService.stashPushIncludeUntracked(
                    parentRepoRoot,
                    "nex-graft:\(association.id.uuidString)"
                )
            }
        } catch {
            releaseBusy(parentRepoRoot)
            throw error
        }

        /// Helper that undoes the stash + busyRoots side-effects when
        /// a later step in `start` throws. Without it, a failed
        /// initial sync would leave the user's stash on disk with no
        /// recovery breadcrumb and no in-memory session — and a
        /// follow-up `start` could overwrite the breadcrumb, orphaning
        /// the original stash. Best-effort: if pop fails, leave the
        /// stash and surface the original error rather than masking it.
        func rollbackAfterStash(_ originalError: Error) async -> Error {
            if let stashRef {
                do {
                    try await gitService.stashPopRef(parentRepoRoot, stashRef)
                } catch {
                    // Pop failed too. Preserve the stash + write a
                    // breadcrumb so the user has a recovery path on
                    // next launch. The original error is what we
                    // surface to the caller.
                    try? writeBreadcrumb(
                        at: parentRepoRoot,
                        breadcrumb: Breadcrumb(
                            version: 1,
                            stashed: true,
                            assocId: association.id.uuidString,
                            stashRef: stashRef,
                            worktreePath: worktreePath,
                            branch: association.branchName ?? "HEAD"
                        )
                    )
                }
            }
            releaseBusy(parentRepoRoot)
            return originalError
        }

        // Resolve the worktree's current branch. `git rev-parse
        // --abbrev-ref HEAD` prints the literal "HEAD" for detached
        // worktrees — treat it as a sentinel that forces SHA-based
        // checkout in `runSyncPass`, otherwise the parent would
        // checkout its own HEAD and never reflect the worktree.
        let branch: String
        do {
            branch = try await gitService.getCurrentBranch(worktreePath)
                ?? association.branchName
                ?? "HEAD"
        } catch {
            throw await rollbackAfterStash(error)
        }

        // Persist the recovery breadcrumb before doing any further
        // work — if the next step crashes we still have what we
        // need to clean up on relaunch.
        do {
            try writeBreadcrumb(
                at: parentRepoRoot,
                breadcrumb: Breadcrumb(
                    version: 1,
                    stashed: stashRef != nil,
                    assocId: association.id.uuidString,
                    stashRef: stashRef,
                    worktreePath: worktreePath,
                    branch: branch
                )
            )
        } catch {
            throw await rollbackAfterStash(error)
        }

        // Initial sync brings the parent root up to the worktree's
        // current tip. Subsequent batches reuse the same code path.
        do {
            try await runSyncPass(
                worktreePath: worktreePath,
                parentRepoRoot: parentRepoRoot,
                branch: branch
            )
        } catch {
            // Roll back stash + breadcrumb on initial-sync failure.
            // The user gets the original sync error; nothing on disk
            // is left in a half-grafted state.
            removeBreadcrumb(at: parentRepoRoot)
            throw await rollbackAfterStash(error)
        }

        let initialSession = GraftSession(
            id: association.id,
            worktreePath: worktreePath,
            parentRepoRoot: parentRepoRoot,
            branch: branch,
            status: .watching,
            stashRef: stashRef,
            lastSync: Date(),
            recentLog: [GraftLogEntry(kind: .info, message: "Graft started")]
        )

        lock.withLock { sessions[association.id] = initialSession }
        publish(.started(initialSession))

        // Spawn the watcher loop. Cancelling the task tears the
        // FSEvents stream down via the AsyncStream termination
        // handler.
        let watchStream = watcher.start(
            rootPath: worktreePath,
            debounce: debounce
        )
        let task = Task { [weak self] in
            for await batch in watchStream {
                guard let self else { return }
                await handleBatch(
                    associationID: association.id,
                    batch: batch
                )
            }
        }
        lock.withLock { watcherTasks[association.id] = task }

        return initialSession
    }

    // MARK: - Stop

    func stop(_ associationID: UUID) async throws {
        let session: GraftSession? = lock.withLock {
            sessions[associationID]
        }
        guard let session else { return }

        // Cancel the watcher first so a sync pass can't fire mid-stop.
        if let task = lock.withLock({ watcherTasks.removeValue(forKey: associationID) }) {
            task.cancel()
        }

        do {
            try await gitService.checkoutHeadForce(session.parentRepoRoot)
        } catch {
            // Checkout failed (permissions, concurrent edit, etc).
            // LEAVE the breadcrumb in place so the orphan-recovery
            // banner can pick this up on next launch — the user's
            // stash is still on disk and they need a UI path to it.
            // We still release `busyRoots` and drop the in-memory
            // session so the user can retry start() on a different
            // worktree without colliding.
            releaseBusy(session.parentRepoRoot)
            lock.withLock { _ = sessions.removeValue(forKey: associationID) }
            publish(.stopped(associationID))
            throw error
        }

        if let stashRef = session.stashRef {
            do {
                try await gitService.stashPopRef(session.parentRepoRoot, stashRef)
            } catch {
                // Conflict on pop. Leave the stash AND the breadcrumb
                // in place so the user can use the recovery banner to
                // try again later (or inspect `git stash list`). Drop
                // the in-memory session so the toggle reflects the
                // detached state and the user can re-attempt later.
                releaseBusy(session.parentRepoRoot)
                lock.withLock { _ = sessions.removeValue(forKey: associationID) }
                publish(.stopped(associationID))
                throw GraftError.stashPopConflict(
                    stashRef: stashRef,
                    underlying: String(describing: error)
                )
            }
        }

        removeBreadcrumb(at: session.parentRepoRoot)
        releaseBusy(session.parentRepoRoot)
        lock.withLock { _ = sessions.removeValue(forKey: associationID) }
        publish(.stopped(associationID))
    }

    // MARK: - Inspection

    func activeSessions() async -> [GraftSession] {
        lock.withLock { Array(sessions.values) }
    }

    func updates() -> AsyncStream<GraftSessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - Orphans

    func detectOrphans(_ parentRepoRoots: [String]) async -> [GraftOrphan] {
        var found: [GraftOrphan] = []
        for raw in parentRepoRoots {
            let parent = canonicalize(raw)
            guard let bread = readBreadcrumb(at: parent) else { continue }
            let id = UUID(uuidString: bread.assocId) ?? UUID()
            found.append(GraftOrphan(
                id: id,
                parentRepoRoot: parent,
                worktreePath: bread.worktreePath,
                stashRef: bread.stashRef
            ))
        }
        return found
    }

    func recoverOrphan(_ orphan: GraftOrphan) async throws {
        // Perform the checkout + stash pop using the breadcrumb's
        // recorded state. Mirrors `stop()`: any failure leaves the
        // breadcrumb on disk so the user can retry recovery later.
        try await gitService.checkoutHeadForce(orphan.parentRepoRoot)
        if let stashRef = orphan.stashRef {
            do {
                try await gitService.stashPopRef(orphan.parentRepoRoot, stashRef)
            } catch {
                throw GraftError.stashPopConflict(
                    stashRef: stashRef,
                    underlying: String(describing: error)
                )
            }
        }
        removeBreadcrumb(at: orphan.parentRepoRoot)
    }

    func dismissOrphan(_ orphan: GraftOrphan) async {
        removeBreadcrumb(at: orphan.parentRepoRoot)
    }

    // MARK: - Sync

    private func handleBatch(associationID: UUID, batch: [String]) async {
        let session: GraftSession? = lock.withLock { sessions[associationID] }
        guard let session else { return }

        // Flip status to .syncing and emit an update.
        mutateAndPublish(associationID: associationID) { current in
            current.status = .syncing
        }

        do {
            let changed = try await runSyncPass(
                worktreePath: session.worktreePath,
                parentRepoRoot: session.parentRepoRoot,
                branch: session.branch
            )
            mutateAndPublish(associationID: associationID) { current in
                current.status = .watching
                current.lastSync = Date()
                let msg = changed.isEmpty
                    ? "Sync: no staged changes"
                    : "Sync: \(changed.count) file\(changed.count == 1 ? "" : "s")"
                appendLog(
                    &current,
                    entry: GraftLogEntry(
                        kind: .sync(filesChanged: changed.count),
                        message: msg
                    )
                )
                _ = batch // referenced only to silence unused-capture warnings
            }
        } catch {
            let msg = "Sync failed: \(String(describing: error))"
            mutateAndPublish(associationID: associationID) { current in
                current.status = .error(msg)
                appendLog(
                    &current,
                    entry: GraftLogEntry(kind: .error, message: msg)
                )
            }
        }
    }

    @discardableResult
    private func runSyncPass(
        worktreePath: String,
        parentRepoRoot: String,
        branch: String
    ) async throws -> [String] {
        // Re-check the parent's state on every sync. A user who runs
        // `git merge` / `git rebase` in the parent root between syncs
        // would otherwise have their in-progress operation wiped out
        // by the next checkout. Abort the sync if non-clean — the
        // session stays alive and the next batch retries.
        let parentState = try await gitService.repoState(parentRepoRoot)
        guard parentState == .clean else {
            throw GraftError.repoBusy(state: describe(parentState))
        }

        // Make sure the worktree directory still exists. A user `rm
        // -rf`-ing it would otherwise spin failing sync passes forever.
        if !FileManager.default.fileExists(atPath: worktreePath) {
            throw GraftError.missingWorktree(worktreePath: worktreePath)
        }

        let staged = try await gitService.addAllAndCommit(
            worktreePath,
            "nex-graft: checkpoint",
            true
        )

        // Detached HEAD: `git rev-parse --abbrev-ref HEAD` prints the
        // literal "HEAD" rather than nil. If we tried to `checkout -f
        // HEAD` in the parent, it would succeed but reflect the
        // PARENT'S HEAD, not the worktree's tip — completely silent
        // miss. Force SHA-based checkout in that case.
        //
        // Also re-resolve the branch on every sync so a user switching
        // worktree branches mid-session doesn't keep grafting the
        // stale name (which would either fail or — worse — succeed
        // against the parent's stale ref).
        let currentBranch = await (try? gitService.getCurrentBranch(worktreePath))
            ?? branch
        if currentBranch == "HEAD" || currentBranch.isEmpty {
            let sha = try await gitService.getHeadSha(worktreePath)
            try await gitService.checkoutBranchForce(parentRepoRoot, sha)
            return staged
        }

        do {
            try await gitService.checkoutBranchForce(parentRepoRoot, currentBranch)
        } catch {
            // Parent doesn't know this branch name (rare — only when
            // the worktree was created on a branch the parent doesn't
            // have locally). Fall back to the worktree's HEAD SHA.
            let sha = try await gitService.getHeadSha(worktreePath)
            try await gitService.checkoutBranchForce(parentRepoRoot, sha)
        }
        return staged
    }

    // MARK: - State helpers

    private func releaseBusy(_ parentRepoRoot: String) {
        lock.withLock { _ = busyRoots.remove(parentRepoRoot) }
    }

    private func mutateAndPublish(
        associationID: UUID,
        body: (inout GraftSession) -> Void
    ) {
        let updated: GraftSession? = lock.withLock {
            guard var current = sessions[associationID] else { return nil }
            body(&current)
            sessions[associationID] = current
            return current
        }
        guard let updated else { return }
        publish(.updated(updated))
    }

    private func publish(_ event: GraftSessionEvent) {
        let conts: [AsyncStream<GraftSessionEvent>.Continuation] = lock.withLock {
            Array(subscribers.values)
        }
        for c in conts {
            c.yield(event)
        }
    }

    private func appendLog(_ session: inout GraftSession, entry: GraftLogEntry) {
        session.recentLog.append(entry)
        if session.recentLog.count > logCap {
            session.recentLog.removeFirst(session.recentLog.count - logCap)
        }
    }

    // MARK: - Breadcrumb

    private struct Breadcrumb: Codable, Equatable {
        let version: Int
        let stashed: Bool
        let assocId: String
        let stashRef: String?
        let worktreePath: String
        let branch: String
    }

    private func breadcrumbPath(at parentRepoRoot: String) -> String {
        let gitDir = (parentRepoRoot as NSString)
            .appendingPathComponent(".git")
        return (gitDir as NSString).appendingPathComponent(Self.breadcrumbName)
    }

    private func writeBreadcrumb(at parentRepoRoot: String, breadcrumb: Breadcrumb) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(breadcrumb)
        try data.write(to: URL(fileURLWithPath: breadcrumbPath(at: parentRepoRoot)))
    }

    private func readBreadcrumb(at parentRepoRoot: String) -> Breadcrumb? {
        let path = breadcrumbPath(at: parentRepoRoot)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        guard let bread = try? JSONDecoder().decode(Breadcrumb.self, from: data) else {
            // Reject unknown versions / malformed JSON — better to
            // leave the file alone than silently misinterpret it.
            return nil
        }
        return bread.version == 1 ? bread : nil
    }

    private func removeBreadcrumb(at parentRepoRoot: String) {
        try? FileManager.default.removeItem(atPath: breadcrumbPath(at: parentRepoRoot))
    }

    private func canonicalize(_ path: String) -> String {
        ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
    }

    private func describe(_ state: RepoState) -> String {
        switch state {
        case .clean: "clean"
        case .merge: "merge in progress"
        case .rebase: "rebase in progress"
        case .cherryPick: "cherry-pick in progress"
        case .revert: "revert in progress"
        case .bisect: "bisect in progress"
        case .unknown(let s): s
        }
    }
}

// MARK: - TCA Dependency

extension GraftService: DependencyKey {
    static let liveValue: GraftService = makeLive(
        gitService: .live,
        watcher: RecursiveFSWatcher.liveValue
    )

    static func makeLive(
        gitService: GitService,
        watcher: RecursiveFSWatcher
    ) -> GraftService {
        let impl = GraftServiceImpl(gitService: gitService, watcher: watcher)
        return GraftService(
            start: { try await impl.start($0) },
            stop: { try await impl.stop($0) },
            activeSessions: { await impl.activeSessions() },
            updates: { impl.updates() },
            detectOrphans: { await impl.detectOrphans($0) },
            recoverOrphan: { try await impl.recoverOrphan($0) },
            dismissOrphan: { await impl.dismissOrphan($0) }
        )
    }

    static var testValue: GraftService {
        GraftService(
            start: unimplemented(
                "GraftService.start",
                placeholder: GraftSession(
                    id: UUID(),
                    worktreePath: "",
                    parentRepoRoot: "",
                    branch: "",
                    status: .starting,
                    stashRef: nil,
                    lastSync: nil,
                    recentLog: []
                )
            ),
            stop: unimplemented("GraftService.stop"),
            activeSessions: { [] },
            updates: { AsyncStream { _ in } },
            detectOrphans: { _ in [] },
            recoverOrphan: unimplemented("GraftService.recoverOrphan"),
            dismissOrphan: { _ in }
        )
    }
}

extension DependencyValues {
    var graftService: GraftService {
        get { self[GraftService.self] }
        set { self[GraftService.self] = newValue }
    }
}
