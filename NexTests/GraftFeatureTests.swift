import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

@MainActor
struct GraftFeatureTests {
    nonisolated static let assocID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!

    private func makeAssociation() -> RepoAssociation {
        RepoAssociation(
            id: Self.assocID,
            repoID: UUID(),
            worktreePath: "/tmp/wt",
            branchName: "feature/x"
        )
    }

    private func makeSession() -> GraftSession {
        GraftSession(
            id: Self.assocID,
            worktreePath: "/tmp/wt",
            parentRepoRoot: "/tmp/repo",
            branch: "feature/x",
            status: .watching,
            stashRef: nil,
            lastSync: nil
        )
    }

    @Test func toggleOnAddsSession() async {
        let session = makeSession()
        let store = TestStore(initialState: GraftFeature.State()) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in session },
                stop: { _ in },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let placeholderSession = GraftSession(
            id: Self.assocID,
            worktreePath: "/tmp/wt",
            parentRepoRoot: "",
            branch: "feature/x",
            status: .starting,
            stashRef: nil,
            lastSync: nil
        )

        await store.send(.toggleGraft(makeAssociation())) { state in
            state.sessions[id: Self.assocID] = placeholderSession
        }
        await store.receive(.startSucceeded(session)) { state in
            state.sessions[id: Self.assocID] = session
        }
    }

    @Test func toggleOffRemovesSession() async {
        var initial = GraftFeature.State()
        initial.sessions.append(makeSession())

        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in .init(id: Self.assocID, worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil) },
                stop: { _ in },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleGraft(makeAssociation()))
        await store.receive(.stopSucceeded(Self.assocID)) { state in
            state.sessions.remove(id: Self.assocID)
        }
    }

    @Test func recoverOrphanDelegatesAndClearsBanner() async {
        let orphan = GraftOrphan(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!,
            parentRepoRoot: "/tmp/repo",
            worktreePath: "/tmp/wt",
            stashRef: "deadbeef"
        )
        var initial = GraftFeature.State()
        initial.orphans.append(orphan)

        let recoverCount = ConcurrentCounter()
        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil) },
                stop: { _ in },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in recoverCount.increment() },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.recoverOrphan(orphan)) { state in
            state.orphans.remove(id: orphan.id)
        }
        await store.finish()
        #expect(recoverCount.value == 1)
    }

    @Test func startFailingWithAlreadyActiveTriggersSwapPrompt() async {
        // An existing session for the parent root + a fresh
        // toggleGraft for a SECOND association whose worktree maps
        // to the same parent should clear the optimistic placeholder
        // and surface the swap prompt.
        let existingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
        let existingSession = GraftSession(
            id: existingID,
            worktreePath: "/tmp/wt-existing",
            parentRepoRoot: "/tmp/repo",
            branch: "existing-branch",
            status: .watching,
            stashRef: nil,
            lastSync: nil
        )
        var initial = GraftFeature.State()
        initial.sessions.append(existingSession)

        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in
                    throw GraftError.alreadyActive(parentRepoRoot: "/tmp/repo")
                },
                stop: { _ in },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let newAssoc = makeAssociation()
        await store.send(.toggleGraft(newAssoc))
        await store.receive(.startFailed(
            association: newAssoc,
            failure: .alreadyActive(parentRepoRoot: "/tmp/repo")
        )) { state in
            // Optimistic placeholder for the new attempt is removed.
            state.sessions.remove(id: newAssoc.id)
            // Swap prompt set with both sides.
            state.swapPrompt = GraftSwapPrompt(
                id: newAssoc.id,
                newAssociation: newAssoc,
                existingSessionID: existingID,
                existingBranch: "existing-branch",
                existingWorktreePath: "/tmp/wt-existing",
                parentRepoRoot: "/tmp/repo"
            )
        }
    }

    @Test func confirmSwapStopsExistingThenStartsNew() async {
        // Happy path: prompt was set, user clicks Stop existing &
        // swap. Reducer must call graftService.stop on the existing
        // session ID, then call graftService.start on the new
        // association, in that order, and surface .startSucceeded
        // for the new session.
        let newAssoc = makeAssociation()
        let existingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
        let prompt = GraftSwapPrompt(
            id: newAssoc.id,
            newAssociation: newAssoc,
            existingSessionID: existingID,
            existingBranch: "existing",
            existingWorktreePath: "/tmp/wt-existing",
            parentRepoRoot: "/tmp/repo"
        )

        var initial = GraftFeature.State()
        initial.swapPrompt = prompt

        let stopCalls = ConcurrentCounter()
        let startCalls = ConcurrentCounter()
        let ordering = LockedArray()
        let newSession = GraftSession(
            id: newAssoc.id,
            worktreePath: newAssoc.worktreePath,
            parentRepoRoot: "/tmp/repo",
            branch: newAssoc.branchName ?? "",
            status: .watching,
            stashRef: nil,
            lastSync: nil
        )

        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { assoc in
                    startCalls.increment()
                    ordering.append("start:\(assoc.id.uuidString)")
                    return newSession
                },
                stop: { id in
                    stopCalls.increment()
                    ordering.append("stop:\(id.uuidString)")
                },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.confirmSwap(prompt)) { state in
            state.swapPrompt = nil
            // Optimistic placeholder for the new session.
            state.sessions[id: newAssoc.id] = GraftSession(
                id: newAssoc.id,
                worktreePath: newAssoc.worktreePath,
                parentRepoRoot: "",
                branch: newAssoc.branchName ?? "",
                status: .starting,
                stashRef: nil,
                lastSync: nil
            )
        }
        await store.receive(.startSucceeded(newSession)) { state in
            state.sessions[id: newAssoc.id] = newSession
        }
        await store.finish()

        #expect(stopCalls.value == 1)
        #expect(startCalls.value == 1)
        // Stop must come before start.
        #expect(ordering.snapshot.first?.hasPrefix("stop:") == true)
        #expect(ordering.snapshot.last?.hasPrefix("start:") == true)
    }

    @Test func cancelSwapClearsPrompt() async {
        let newAssoc = makeAssociation()
        var initial = GraftFeature.State()
        initial.swapPrompt = GraftSwapPrompt(
            id: newAssoc.id,
            newAssociation: newAssoc,
            existingSessionID: UUID(),
            existingBranch: "existing",
            existingWorktreePath: "/tmp/wt-existing",
            parentRepoRoot: "/tmp/repo"
        )
        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil) },
                stop: { _ in },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.cancelSwap) { state in
            state.swapPrompt = nil
        }
    }

    @Test func orphansDetectedReplacesBanner() async {
        let orphan = GraftOrphan(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!,
            parentRepoRoot: "/tmp/r2",
            worktreePath: "/tmp/wt2",
            stashRef: nil
        )
        let store = TestStore(initialState: GraftFeature.State()) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil) },
                stop: { _ in },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [orphan] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.orphansDetected([orphan])) { state in
            state.orphans = [orphan]
        }
    }

    // MARK: - Issue #231 regressions

    @Test func forceStopOnErroredSessionCallsServiceStop() async {
        // THE regression for issue #231: a session in `.error` status
        // can be a LIVE session whose sync failed — it still owns the
        // watcher, the parent-root claim, and the breadcrumb.
        // `forceStop` (used by every removal path) must call
        // graftService.stop for it, not just drop the reducer state.
        var erroredSession = makeSession()
        erroredSession.status = .error("sync failed: worktree missing")
        var initial = GraftFeature.State()
        initial.sessions.append(erroredSession)

        let stopCalls = ConcurrentCounter()
        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil) },
                stop: { _ in stopCalls.increment() },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.forceStop(Self.assocID))
        await store.receive(.stopSucceeded(Self.assocID)) { state in
            state.sessions.remove(id: Self.assocID)
        }
        await store.finish()
        #expect(stopCalls.value == 1)
    }

    @Test func forceStopWithoutReducerSessionStillCallsServiceStop() async {
        // The reducer mirror can lose track of a live service session;
        // forceStop must reach the service regardless (stop is a
        // cheap no-op when the service doesn't know the id either).
        let stopCalls = ConcurrentCounter()
        let store = TestStore(initialState: GraftFeature.State()) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil) },
                stop: { _ in stopCalls.increment() },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.forceStop(Self.assocID))
        await store.receive(.stopSucceeded(Self.assocID))
        await store.finish()
        #expect(stopCalls.value == 1)
    }

    @Test func toggleOnErroredSessionStopsBeforeRestarting() async {
        // Retry on an errored session must unwind the service first
        // (release the root claim) or the restart self-collides with
        // its own `alreadyActive`.
        var erroredSession = makeSession()
        erroredSession.status = .error("sync failed")
        var initial = GraftFeature.State()
        initial.sessions.append(erroredSession)

        let ordering = LockedArray()
        let restarted = makeSession()
        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { assoc in
                    ordering.append("start:\(assoc.id.uuidString)")
                    return restarted
                },
                stop: { id in
                    ordering.append("stop:\(id.uuidString)")
                },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggleGraft(makeAssociation())) { state in
            state.sessions.remove(id: Self.assocID)
        }
        await store.receive(.startSucceeded(restarted)) { state in
            state.sessions[id: Self.assocID] = restarted
        }
        await store.finish()

        #expect(ordering.snapshot.first?.hasPrefix("stop:") == true)
        #expect(ordering.snapshot.last?.hasPrefix("start:") == true)
    }

    @Test func toggleOnErroredSessionAbortsRetryWhenStopFails() async {
        // If the unwind fails, the recovery breadcrumb (and any
        // stash) is still on disk — retry-starting would overwrite
        // it. The retry must abort with a visible error instead.
        var erroredSession = makeSession()
        erroredSession.status = .error("sync failed")
        var initial = GraftFeature.State()
        initial.sessions.append(erroredSession)

        let startCalls = ConcurrentCounter()
        let store = TestStore(initialState: initial) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in
                    startCalls.increment()
                    return .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil)
                },
                stop: { _ in throw GraftError.unknown("restore failed") },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let assoc = makeAssociation()
        await store.send(.toggleGraft(assoc)) { state in
            state.sessions.remove(id: Self.assocID)
        }
        await store.receive(\.startFailed)
        await store.finish()

        // A visible `.error` session is re-inserted; start never ran.
        #expect(startCalls.value == 0)
        let reinserted = store.state.sessions[id: Self.assocID]
        if case .error(let message)? = reinserted?.status {
            #expect(message.contains("Couldn't unwind"))
        } else {
            Issue.record("expected a visible .error session, got \(String(describing: reinserted))")
        }
    }

    @Test func alreadyActiveWithOrphanedServiceSessionPresentsSwapPrompt() async {
        // The silent-button fix: reducer state has NO session for the
        // contested root, but the service still holds one (the #231
        // orphan). The reducer must query the service, re-adopt the
        // session, and present the swap prompt instead of doing
        // nothing.
        let orphanID = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!
        let orphanSession = GraftSession(
            id: orphanID,
            worktreePath: "/tmp/wt-orphan",
            parentRepoRoot: "/tmp/repo",
            branch: "orphan-branch",
            status: .watching,
            stashRef: nil,
            lastSync: nil
        )
        let store = TestStore(initialState: GraftFeature.State()) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in
                    throw GraftError.alreadyActive(parentRepoRoot: "/tmp/repo")
                },
                stop: { _ in },
                activeSessions: { [orphanSession] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let newAssoc = makeAssociation()
        await store.send(.toggleGraft(newAssoc))
        await store.receive(.alreadyActiveOwnerFound(
            association: newAssoc,
            existing: orphanSession
        )) { state in
            state.sessions[id: orphanID] = orphanSession
            state.swapPrompt = GraftSwapPrompt(
                id: newAssoc.id,
                newAssociation: newAssoc,
                existingSessionID: orphanID,
                existingBranch: "orphan-branch",
                existingWorktreePath: "/tmp/wt-orphan",
                parentRepoRoot: "/tmp/repo"
            )
        }
    }

    @Test func alreadyActiveWithSameAssociationReadoptsWithoutPrompt() async {
        // The service session belongs to the SAME association the
        // user toggled — reducer state just lost track of it. That
        // must repair state (session re-adopted, shown active), not
        // offer to swap a worktree with itself.
        let orphanSession = makeSession()
        let store = TestStore(initialState: GraftFeature.State()) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in
                    throw GraftError.alreadyActive(parentRepoRoot: "/tmp/repo")
                },
                stop: { _ in },
                activeSessions: { [orphanSession] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let assoc = makeAssociation()
        await store.send(.toggleGraft(assoc))
        await store.receive(.alreadyActiveOwnerFound(
            association: assoc,
            existing: orphanSession
        )) { state in
            state.sessions[id: Self.assocID] = orphanSession
        }
        await store.finish()
        #expect(store.state.swapPrompt == nil)
    }

    @Test func alreadyActiveWithNoVisibleOwnerSurfacesError() async {
        // Nobody visibly owns the claim (e.g. a mid-flight start on
        // the same root). The button must not fail silently — a
        // visible `.error` session is inserted. Its parentRepoRoot
        // stays empty so it can never satisfy a future swap-prompt
        // lookup (no phantom-prompt loop).
        let store = TestStore(initialState: GraftFeature.State()) {
            GraftFeature()
        } withDependencies: {
            $0.graftService = GraftService(
                start: { _ in
                    throw GraftError.alreadyActive(parentRepoRoot: "/tmp/repo")
                },
                stop: { _ in },
                activeSessions: { [] },
                updates: { AsyncStream { _ in } },
                detectOrphans: { _ in [] },
                recoverOrphan: { _ in },
                dismissOrphan: { _ in }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let newAssoc = makeAssociation()
        await store.send(.toggleGraft(newAssoc))
        // First the alreadyActive failure, then the follow-up .other
        // failure emitted after the service query finds no owner.
        await store.receive(\.startFailed)
        await store.receive(\.startFailed)
        await store.finish()

        let inserted = store.state.sessions[id: newAssoc.id]
        #expect(inserted?.parentRepoRoot == "")
        if case .error(let message)? = inserted?.status {
            #expect(message.contains("already active"))
        } else {
            Issue.record("expected a visible .error session, got \(String(describing: inserted))")
        }
        #expect(store.state.swapPrompt == nil)
    }
}

private final class ConcurrentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.withLock { _value += 1 }
    }

    var value: Int {
        lock.withLock { _value }
    }
}

private final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []

    func append(_ item: String) {
        lock.withLock { _items.append(item) }
    }

    var snapshot: [String] {
        lock.withLock { _items }
    }
}
