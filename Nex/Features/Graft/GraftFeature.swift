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
    }

    enum Action: Equatable {
        case onAppLaunched(parentRepoRoots: [String])
        case orphansDetected([GraftOrphan])
        case toggleGraft(RepoAssociation)
        case startSucceeded(GraftSession)
        case startFailed(associationID: UUID, error: String)
        case stopSucceeded(UUID)
        case stopFailed(UUID, error: String)
        case sessionEvent(GraftSessionEvent)
        case subscribeToUpdates
        case recoverOrphan(GraftOrphan)
        case dismissOrphan(GraftOrphan)
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
                                associationID: association.id,
                                error: String(describing: error)
                            ))
                        }
                    }
                }

            case .startSucceeded(let session):
                state.sessions[id: session.id] = session
                return .none

            case .startFailed(let assocID, let error):
                // Preserve the failed session in `.error` state so the
                // user can see what went wrong (the inspector button's
                // tooltip + red dot reflect this). The next toggle
                // clears it and retries.
                if var session = state.sessions[id: assocID] {
                    session.status = .error(error)
                    state.sessions[id: assocID] = session
                }
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
