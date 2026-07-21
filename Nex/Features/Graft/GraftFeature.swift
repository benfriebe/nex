import ComposableArchitecture
import Foundation

/// UI-visible state for the graft (worktree-mirroring) feature.
@Reducer
struct GraftFeature {
    @ObservableState
    struct State: Equatable {
        /// Active sessions keyed by `RepoAssociation.id`.
        var sessions: IdentifiedArrayOf<GraftSession> = []
        /// Orphaned breadcrumbs detected at launch. Drives the
        /// recovery banner in the inspector.
        var orphans: IdentifiedArrayOf<GraftOrphan> = []
        /// Pending "two worktrees want to graft the same parent" prompt.
        /// Set when `start()` fails with `.alreadyActive`; cleared by
        /// `confirmSwap` (stops the existing session, retries the new
        /// one) or `cancelSwap` (drops the new attempt entirely).
        var swapPrompt: GraftSwapPrompt?
    }

    enum Action: Equatable {
        case onAppLaunched(parentRepoRoots: [String])
        case orphansDetected([GraftOrphan])
        case toggleGraft(RepoAssociation)
        /// Unconditional stop for a specific association — used by
        /// removal paths (workspace delete, bulk delete, cascade
        /// group delete, repo removal, auto-unlink) where the
        /// association is being deleted entirely and `toggleGraft`
        /// would either retry-start an `.error` session or be a
        /// no-op. Drops the session from state and tells the
        /// service to tear down. Idempotent: a missing session is
        /// a no-op.
        case forceStop(UUID)
        case startSucceeded(GraftSession)
        /// Typed failure so the reducer can distinguish "another
        /// session already owns this parent root" (which triggers the
        /// swap prompt) from a generic error (which surfaces in the
        /// per-association tooltip / red dot).
        case startFailed(association: RepoAssociation, failure: GraftStartFailure)
        /// The service reported an active session for a contested
        /// parent root that reducer state had lost track of (an
        /// orphan — e.g. the owning workspace was deleted). Re-adopts
        /// the session into state and presents the swap prompt so the
        /// user has a working stop-and-swap path.
        case alreadyActiveOwnerFound(association: RepoAssociation, existing: GraftSession)
        case stopSucceeded(UUID)
        case stopFailed(UUID, error: String)
        case sessionEvent(GraftSessionEvent)
        case subscribeToUpdates
        case recoverOrphan(GraftOrphan)
        /// Recovery couldn't complete cleanly (typically a stash-pop
        /// conflict). The orphan is re-inserted so the banner shows
        /// again — without this, the breadcrumb + stash both live on
        /// disk with no UI path to retry.
        case orphanRecoveryFailed(orphan: GraftOrphan, error: String)
        case dismissOrphan(GraftOrphan)
        /// User accepted the swap prompt: stop the existing session
        /// for the contested parent root and then start the new one.
        case confirmSwap(GraftSwapPrompt)
        /// User dismissed the swap prompt: clear the placeholder for
        /// the new attempt; the existing session keeps running.
        case cancelSwap
    }

    @Dependency(\.graftService) var graftService

    private enum CancelID: Hashable {
        case subscription
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppLaunched(let parentRepoRoots):
                return .merge(
                    .send(.subscribeToUpdates),
                    .run { send in
                        let orphans = await graftService.detectOrphans(parentRepoRoots)
                        await send(.orphansDetected(orphans))
                    }
                )

            case .orphansDetected(let orphans):
                state.orphans = IdentifiedArray(uniqueElements: orphans)
                return .none

            case .toggleGraft(let association):
                if let existing = state.sessions[id: association.id] {
                    // An `.error` session is either a start-failure
                    // placeholder (owns nothing) or a LIVE session
                    // that failed a sync — the latter still owns the
                    // watcher, the parent-root claim, and the
                    // breadcrumb (issue #231). Toggle becomes "retry":
                    // unwind whatever the service still holds first
                    // (a no-op for placeholders), then re-run start.
                    // If the unwind fails, do NOT retry-start — a
                    // fresh start would overwrite the recovery
                    // breadcrumb and orphan the user's stash.
                    if case .error = existing.status {
                        state.sessions.remove(id: association.id)
                        return .run { send in
                            do {
                                try await graftService.stop(association.id)
                            } catch {
                                await send(.startFailed(
                                    association: association,
                                    failure: .other(message:
                                        "Couldn't unwind the previous graft: \(error). " +
                                            "Resolve the repo state, then toggle to retry.")
                                ))
                                return
                            }
                            await send(.toggleGraft(association))
                        }
                    }
                    return .run { send in
                        do {
                            try await graftService.stop(association.id)
                            await send(.stopSucceeded(association.id))
                        } catch {
                            await send(.stopFailed(
                                association.id,
                                error: String(describing: error)
                            ))
                        }
                    }
                } else {
                    // Optimistically place a `.starting` placeholder so
                    // the icon flips immediately. Replaced by the real
                    // session on `startSucceeded`, or flipped to
                    // `.error` on `startFailed` (which keeps the user-
                    // visible tooltip / red dot for retry).
                    state.sessions.append(GraftSession(
                        id: association.id,
                        worktreePath: association.worktreePath,
                        parentRepoRoot: "",
                        branch: association.branchName ?? "",
                        status: .starting,
                        stashRef: nil,
                        lastSync: nil
                    ))
                    return .run { send in
                        do {
                            let session = try await graftService.start(association, nil)
                            await send(.startSucceeded(session))
                        } catch {
                            await send(.startFailed(
                                association: association,
                                failure: GraftStartFailure(error: error)
                            ))
                        }
                    }
                }

            case .forceStop(let assocID):
                // Always tear down via the service — even when reducer
                // state has no session (or only an `.error` one) for
                // this id. A session that started fine and later hit a
                // sync error still owns live resources (watcher,
                // parent-root claim, breadcrumb); skipping the service
                // stop for it leaked all of that when the owning
                // workspace was deleted (issue #231). For ids the
                // service doesn't know, stop() is a cheap no-op.
                // Unlike `toggleGraft`, we never retry-start (the
                // caller is a removal path; the association no longer
                // exists).
                return .run { send in
                    do {
                        try await graftService.stop(assocID)
                        await send(.stopSucceeded(assocID))
                    } catch {
                        await send(.stopFailed(
                            assocID,
                            error: String(describing: error)
                        ))
                    }
                }

            case .startSucceeded(let session):
                state.sessions[id: session.id] = session
                return .none

            case .startFailed(let association, let failure):
                // Drop the optimistic placeholder regardless of outcome.
                state.sessions.remove(id: association.id)
                switch failure {
                case .alreadyActive(let parentRepoRoot):
                    // Find the live session for that parent root —
                    // that's the existing graft the user has to choose
                    // about. Set up the swap prompt; UI presents the
                    // confirmation dialog.
                    if let existing = state.sessions.first(where: { $0.parentRepoRoot == parentRepoRoot }) {
                        state.swapPrompt = GraftSwapPrompt(
                            id: association.id,
                            newAssociation: association,
                            existingSessionID: existing.id,
                            existingBranch: existing.branch,
                            existingWorktreePath: existing.worktreePath,
                            parentRepoRoot: parentRepoRoot
                        )
                        return .none
                    }
                    // No reducer-visible owner. The service is the
                    // source of truth — it may still hold a session
                    // reducer state lost track of. Query it so the
                    // user gets the swap prompt (a real recovery
                    // lever) instead of a silently dead button
                    // (issue #231).
                    return .run { send in
                        let sessions = await graftService.activeSessions()
                        if let owner = sessions.first(where: { $0.parentRepoRoot == parentRepoRoot }) {
                            await send(.alreadyActiveOwnerFound(
                                association: association,
                                existing: owner
                            ))
                        } else {
                            // Nobody visibly owns the claim (e.g. a
                            // start on the same root is mid-flight).
                            // Surface a visible error instead of
                            // nothing.
                            await send(.startFailed(
                                association: association,
                                failure: .other(message:
                                    "Another graft is already active for \(parentRepoRoot). " +
                                        "Stop it first, then retry.")
                            ))
                        }
                    }
                case .other(let message):
                    // Re-insert the session in `.error` state so the
                    // tooltip / red dot persists until the user
                    // retries.
                    state.sessions.append(GraftSession(
                        id: association.id,
                        worktreePath: association.worktreePath,
                        parentRepoRoot: "",
                        branch: association.branchName ?? "",
                        status: .error(message),
                        stashRef: nil,
                        lastSync: nil
                    ))
                    return .none
                }

            case .alreadyActiveOwnerFound(let association, let existing):
                // The service session IS this association — reducer
                // state simply lost track of it. Re-adopt it and show
                // it as active; a swap prompt would offer to swap the
                // worktree with itself.
                if existing.id == association.id {
                    state.sessions[id: existing.id] = existing
                    return .none
                }
                // Re-adopt the service-side session so the prompt's
                // "existing" side is visible in the inspector and
                // `status`, and remains stoppable if the user cancels.
                state.sessions[id: existing.id] = existing
                state.swapPrompt = GraftSwapPrompt(
                    id: association.id,
                    newAssociation: association,
                    existingSessionID: existing.id,
                    existingBranch: existing.branch,
                    existingWorktreePath: existing.worktreePath,
                    parentRepoRoot: existing.parentRepoRoot
                )
                return .none

            case .confirmSwap(let prompt):
                state.swapPrompt = nil
                // Optimistically show the new session as .starting so
                // the inspector flips immediately while stop+start run.
                state.sessions.append(GraftSession(
                    id: prompt.newAssociation.id,
                    worktreePath: prompt.newAssociation.worktreePath,
                    parentRepoRoot: "",
                    branch: prompt.newAssociation.branchName ?? "",
                    status: .starting,
                    stashRef: nil,
                    lastSync: nil
                ))
                return .run { send in
                    // Stop must complete (root claim released) before
                    // start can succeed — sequentially.
                    do {
                        try await graftService.stop(prompt.existingSessionID)
                    } catch {
                        // Stop FAILED — the existing session is still
                        // running. Tell the user the existing graft
                        // survives so they know they don't have to
                        // panic about the lost-everything case.
                        await send(.startFailed(
                            association: prompt.newAssociation,
                            failure: .other(message:
                                "Couldn't stop the existing graft: \(error). " +
                                    "The existing graft is still active; the new one was not started.")
                        ))
                        return
                    }
                    do {
                        let session = try await graftService.start(prompt.newAssociation, nil)
                        await send(.startSucceeded(session))
                    } catch {
                        // Stop succeeded; start failed. BOTH sides
                        // are gone — the user has no working graft.
                        // Surface that clearly so they know to retry
                        // (or that they need to re-toggle the
                        // ORIGINAL worktree if they wanted to keep
                        // mirroring it).
                        let underlying = String(describing: error)
                        await send(.startFailed(
                            association: prompt.newAssociation,
                            failure: .other(message:
                                "Existing graft was stopped, but the new graft failed " +
                                    "to start: \(underlying). Toggle the icon again to retry.")
                        ))
                    }
                }

            case .cancelSwap:
                state.swapPrompt = nil
                return .none

            case .stopSucceeded(let assocID):
                state.sessions.remove(id: assocID)
                return .none

            case .stopFailed(let assocID, let error):
                if var session = state.sessions[id: assocID] {
                    session.status = .error(error)
                    state.sessions[id: assocID] = session
                }
                return .none

            case .sessionEvent(let event):
                switch event {
                case .started(let session):
                    state.sessions[id: session.id] = session
                case .updated(let session):
                    state.sessions[id: session.id] = session
                case .stopped(let id):
                    state.sessions.remove(id: id)
                }
                return .none

            case .subscribeToUpdates:
                return .run { send in
                    for await event in graftService.updates() {
                        await send(.sessionEvent(event))
                    }
                }
                .cancellable(id: CancelID.subscription, cancelInFlight: true)

            case .recoverOrphan(let orphan):
                state.orphans.remove(id: orphan.id)
                return .run { send in
                    do {
                        try await graftService.recoverOrphan(orphan)
                    } catch {
                        // Recovery hit a snag (typically a stash-pop
                        // conflict). The breadcrumb and stash both
                        // still live on disk; if we leave the banner
                        // off-screen the user has no UI affordance to
                        // retry. Re-emit the orphan so the banner
                        // re-appears.
                        await send(.orphanRecoveryFailed(
                            orphan: orphan,
                            error: String(describing: error)
                        ))
                    }
                }

            case .orphanRecoveryFailed(let orphan, _):
                // Re-insert the orphan so the recovery banner shows
                // again. The error string is currently surfaced via
                // log; the recovery banner copy stays generic.
                state.orphans[id: orphan.id] = orphan
                return .none

            case .dismissOrphan(let orphan):
                state.orphans.remove(id: orphan.id)
                return .run { _ in
                    await graftService.dismissOrphan(orphan)
                }
            }
        }
    }
}

/// Typed result of a graft start attempt. `alreadyActive` is the path
/// the swap-prompt UI keys on; everything else falls into `other`.
enum GraftStartFailure: Equatable {
    case alreadyActive(parentRepoRoot: String)
    case other(message: String)

    init(error: Error) {
        if let graft = error as? GraftError, case .alreadyActive(let root) = graft {
            self = .alreadyActive(parentRepoRoot: root)
        } else {
            self = .other(message: String(describing: error))
        }
    }
}

/// "You're already grafting <other-worktree> into the same parent
/// repo — what now?" UI prompt state.
struct GraftSwapPrompt: Equatable, Identifiable {
    /// Identity == the new association's id so a second start of the
    /// same association doesn't queue duplicate prompts.
    let id: UUID
    let newAssociation: RepoAssociation
    let existingSessionID: UUID
    let existingBranch: String
    let existingWorktreePath: String
    let parentRepoRoot: String
}
