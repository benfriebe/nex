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
            lastSync: nil,
            recentLog: []
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
            lastSync: nil,
            recentLog: []
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
                start: { _ in .init(id: Self.assocID, worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil, recentLog: []) },
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
                start: { _ in .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil, recentLog: []) },
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
                start: { _ in .init(id: UUID(), worktreePath: "", parentRepoRoot: "", branch: "", status: .starting, stashRef: nil, lastSync: nil, recentLog: []) },
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
