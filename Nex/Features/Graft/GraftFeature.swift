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
        case startSucceeded(GraftSession)
        /// Typed failure so the reducer can distinguish "another
        /// session already owns this parent root" (which triggers the
        /// swap prompt) from a generic error (which surfaces in the
        /// per-association tooltip / red dot).
        case startFailed(association: RepoAssociation, failure: GraftStartFailure)
        case stopSucceeded(UUID)
        case stopFailed(UUID, error: String)
        case sessionEvent(GraftSessionEvent)
        case subscribeToUpdates
        case recoverOrphan(GraftOrphan)
        case dismissOrphan(GraftOrphan)
        /// User accepted the swap prompt: stop the existing session
        /// for the contested parent root and then start the new one.
        case confirmSwap(GraftSwapPrompt)
        /// User dismissed the swap prompt: clear the placeholder for
        /// the new attempt; the existing session keeps running.
        case cancelSwap
        /// Stops every active session. Called from app teardown so
        /// breadcrumbs don't survive a clean quit. Errors are
        /// swallowed (the breadcrumb-based recovery picks up anything
        /// that didn't tear down cleanly).
        case stopAll
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
                    // A session in `.error` state never owns live
                    // resources — it's just the error tooltip from
                    // the last failed attempt. Toggle becomes "retry":
                    // drop the error session and re-run start.
                    if case .error = existing.status {
                        state.sessions.remove(id: association.id)
                        return .send(.toggleGraft(association))
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
                        lastSync: nil,
                        recentLog: []
                    ))
                    return .run { send in
                        do {
                            let session = try await graftService.start(association)
                            await send(.startSucceeded(session))
                        } catch {
                            await send(.startFailed(
                                association: association,
                                failure: GraftStartFailure(error: error)
                            ))
                        }
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
                    }
                    return .none
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
                        lastSync: nil,
                        recentLog: []
                    ))
                    return .none
                }

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
                    lastSync: nil,
                    recentLog: []
                ))
                return .run { send in
                    // Stop must complete (busyRoots released) before
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
                        let session = try await graftService.start(prompt.newAssociation)
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
                return .run { _ in
                    try? await graftService.recoverOrphan(orphan)
                }

            case .dismissOrphan(let orphan):
                state.orphans.remove(id: orphan.id)
                return .run { _ in
                    await graftService.dismissOrphan(orphan)
                }

            case .stopAll:
                let ids = state.sessions.ids
                state.sessions.removeAll()
                return .run { _ in
                    for id in ids {
                        try? await graftService.stop(id)
                    }
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
