import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises `PipelinesFeature`'s run-lifecycle logic through
/// `TestStore`, with a fake `PipelineEngine` so routing scenarios
/// (bounce-back, declared-only `maxTraversals`, partial→done fallback,
/// approval gates, fan-out) don't need a real `PipelineDefinition` graph.
/// `.running` runs are hand-seeded — production `pipeline run` always
/// lands a run `.paused` initially, since node spawning is a follow-up
/// (phases 6-7); these tests exercise the routing spine ahead of that
/// wiring landing.
@MainActor
struct PipelinesFeatureTests {
    private static let runID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
    private static let nodeRunID = UUID(uuidString: "80000000-0000-0000-0000-0000000000A1")!
    private static let implementerNodeRunID = UUID(uuidString: "80000000-0000-0000-0000-0000000000A2")!
    private static let auditorNodeRunID = UUID(uuidString: "80000000-0000-0000-0000-0000000000A3")!
    private static let paneID = UUID(uuidString: "80000000-0000-0000-0000-0000000000B1")!

    private func makeDefinition() -> PipelineDefinition {
        var definition = PipelineDefinition(id: "loop", name: "Loop", entry: "planner")
        definition.nodes = [
            PipelineNode(id: "planner"), PipelineNode(id: "implementer"),
            PipelineNode(id: "auditor"), PipelineNode(id: "tester")
        ]
        return definition
    }

    private func makeRun(status: PipelineRunStatus = .running, nodeRunStatus: PipelineNodeRunStatus = .running) -> PipelineRun {
        let nodeRun = PipelineNodeRun(
            id: Self.nodeRunID,
            nodeID: "planner",
            paneID: Self.paneID,
            status: nodeRunStatus,
            startedAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        return makeRun(status: status, nodeRuns: [nodeRun])
    }

    /// Fan-out variant: caller supplies the full NodeRun set (e.g. several
    /// concurrently-active branches) rather than the single-planner
    /// default.
    private func makeRun(status: PipelineRunStatus, statusDetail: String? = nil, nodeRuns: [PipelineNodeRun]) -> PipelineRun {
        PipelineRun(
            id: Self.runID,
            definitionID: "loop",
            definitionSnapshot: makeDefinition(),
            status: status,
            statusDetail: statusDetail,
            location: .current,
            runDir: "/runs/\(Self.runID.uuidString)",
            nodeRuns: IdentifiedArrayOf(uniqueElements: nodeRuns),
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private func makeStore(
        run: PipelineRun,
        evaluateTransition: @escaping @Sendable (PipelineDefinition, String, PipelineNodeOutcome, [String: Int]) -> PipelineTransition
    ) -> TestStoreOf<PipelinesFeature> {
        var state = PipelinesFeature.State()
        state.runs = [run]
        let store = TestStore(initialState: state) {
            PipelinesFeature()
        } withDependencies: {
            $0.pipelineEngine.evaluateTransition = evaluateTransition
            $0.uuid = .incrementing
        }
        // `applyHandoff` stamps wall-clock `Date()` timestamps (matching
        // this codebase's existing convention of not injecting a `.date`
        // dependency — see `AppReducer.swift`'s direct `Date()` calls) —
        // exhaustive mode can't predict those, so these tests assert
        // only the fields that matter for routing.
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    @Test func runCreatedInsertsAndPrunesTerminalRuns() {
        var state = PipelinesFeature.State()
        var terminalRuns: [PipelineRun] = []
        for i in 0 ..< 52 {
            var run = makeRun(status: .completed, nodeRunStatus: .done)
            run.id = UUID()
            run.updatedAt = Date(timeIntervalSince1970: Double(i))
            terminalRuns.append(run)
        }
        for run in terminalRuns {
            PipelinesFeature.insert(run: run, into: &state)
        }
        #expect(state.runs.count == 50)
        // The oldest (lowest updatedAt) terminal runs are the ones pruned.
        #expect(!state.runs.contains(where: { $0.updatedAt == Date(timeIntervalSince1970: 0) }))
        #expect(state.runs.contains(where: { $0.updatedAt == Date(timeIntervalSince1970: 51) }))
    }

    @Test func nonTerminalRunsAreNeverPruned() {
        var state = PipelinesFeature.State()
        for i in 0 ..< 55 {
            var run = makeRun(status: .running)
            run.id = UUID()
            run.updatedAt = Date(timeIntervalSince1970: Double(i))
            PipelinesFeature.insert(run: run, into: &state)
        }
        #expect(state.runs.count == 55)
    }

    @Test func handoffRoutesToNextNodeWhenRunning() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, from, outcome, _ in
            #expect(from == "planner")
            #expect(outcome == .done)
            return .routes([PipelineRoute(to: "implementer", requiresApproval: false, edgeKey: "planner|done|implementer")])
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: "done", outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .done
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.summary = "done"
            $0.runs[id: Self.runID]?.edgeTraversals["planner|done|implementer"] = 1
        }
        // A non-approval route immediately appends the next node's
        // `PipelineNodeRun` (`.spawning`, attempt 1) as an active branch,
        // with its `feedbackSourceNodeRunID` bound to the node that fired
        // it — checked outside the exhaustivity-off closure since it
        // carries a fresh wall-clock `Date()`.
        let updated = store.state.runs[id: Self.runID]
        #expect(updated?.nodeRuns.last?.nodeID == "implementer")
        #expect(updated?.nodeRuns.last?.status == .spawning)
        #expect(updated?.nodeRuns.last?.attempt == 1)
        #expect(updated?.nodeRuns.last?.feedbackSourceNodeRunID == Self.nodeRunID)
        #expect(updated?.activeNodeRunIDs == [updated?.nodeRuns.last?.id].compactMap(\.self))
        // Run status is left alone by a routing handoff that still has an
        // active branch — no more forced `.launching` stamp.
        #expect(updated?.status == .running)
    }

    @Test func fanOutSpawnsMultipleNodeRunsFromOneHandoff() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in
            .routes([
                PipelineRoute(to: "implementer", requiresApproval: false, edgeKey: "planner|done|implementer"),
                PipelineRoute(to: "auditor", requiresApproval: false, edgeKey: "planner|done|auditor")
            ])
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        ))
        let updated = store.state.runs[id: Self.runID]
        #expect(updated?.nodeRuns.count == 3)
        let spawnedNodeIDs = Set(updated?.nodeRuns.filter { $0.status == .spawning }.map(\.nodeID) ?? [])
        #expect(spawnedNodeIDs == ["implementer", "auditor"])
        #expect(updated?.activeNodeRunIDs.count == 2)
        #expect(updated?.edgeTraversals["planner|done|implementer"] == 1)
        #expect(updated?.edgeTraversals["planner|done|auditor"] == 1)
        // Both fresh branches trace their feedback back to the same
        // handing-off node.
        #expect(updated?.nodeRuns.filter { $0.status == .spawning }.allSatisfy { $0.feedbackSourceNodeRunID == Self.nodeRunID } == true)
    }

    @Test func fanOutCoalescesIntoAlreadyActiveBranchWithoutDoubleSpawning() async {
        let planner = PipelineNodeRun(
            id: Self.nodeRunID, nodeID: "planner", status: .running,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let implementer = PipelineNodeRun(
            id: Self.implementerNodeRunID, nodeID: "implementer", status: .running,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let run = makeRun(status: .running, nodeRuns: [planner, implementer])
        let store = makeStore(run: run) { _, _, _, _ in
            .routes([
                // "implementer" is already an active branch — must coalesce.
                PipelineRoute(to: "implementer", requiresApproval: false, edgeKey: "planner|done|implementer"),
                PipelineRoute(to: "auditor", requiresApproval: false, edgeKey: "planner|done|auditor")
            ])
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        ))
        let updated = store.state.runs[id: Self.runID]
        // Only ONE new NodeRun (auditor) — no second implementer NodeRun.
        #expect(updated?.nodeRuns.count == 3)
        #expect(updated?.nodeRuns.count { $0.nodeID == "implementer" } == 1)
        #expect(updated?.nodeRuns.count { $0.nodeID == "auditor" } == 1)
        // The coalesced edge still records its traversal.
        #expect(updated?.edgeTraversals["planner|done|implementer"] == 1)
        #expect(updated?.edgeTraversals["planner|done|auditor"] == 1)
    }

    @Test func approvalGateEdgeSetsAwaitingApproval() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in
            .routes([PipelineRoute(to: "implementer", requiresApproval: true, edgeKey: "planner|done|implementer")])
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .done
            $0.runs[id: Self.runID]?.status = .awaitingApproval
            $0.runs[id: Self.runID]?.statusDetail =
                "[approval to=implementer edge=planner|done|implementer from=\(Self.nodeRunID.uuidString)] — 1 pending approval"
            $0.runs[id: Self.runID]?.edgeTraversals["planner|done|implementer"] = 1
        }
        // Nothing spawned yet — parked behind the gate.
        #expect(store.state.runs[id: Self.runID]?.nodeRuns.count == 1)
    }

    @Test func fanOutGatesOnlyTheApprovalEdgeWhileSiblingBranchSpawnsFreely() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in
            .routes([
                PipelineRoute(to: "implementer", requiresApproval: false, edgeKey: "planner|done|implementer"),
                PipelineRoute(to: "auditor", requiresApproval: true, edgeKey: "planner|done|auditor")
            ])
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        ))
        let updated = store.state.runs[id: Self.runID]
        // implementer spawned immediately...
        #expect(updated?.nodeRuns.contains { $0.nodeID == "implementer" && $0.status == .spawning } == true)
        // ...auditor did NOT — it's parked behind its own gate.
        #expect(updated?.nodeRuns.contains { $0.nodeID == "auditor" } == false)
        #expect(updated?.pendingApprovals.map(\.toNodeID) == ["auditor"])
        #expect(updated?.status == .awaitingApproval)
    }

    @Test func pendingApprovalOnOneBranchDoesNotBlockSiblingBranchHandoffFromRouting() async {
        let auditorGate = PipelinePendingApproval(
            toNodeID: "auditor", edgeKey: "planner|done|auditor", fromNodeRunID: Self.nodeRunID
        )
        let planner = PipelineNodeRun(
            id: Self.nodeRunID, nodeID: "planner", status: .done,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let implementer = PipelineNodeRun(
            id: Self.implementerNodeRunID, nodeID: "implementer", status: .running,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let run = makeRun(
            status: .awaitingApproval,
            statusDetail: PipelinePendingApproval.encodeAll([auditorGate]),
            nodeRuns: [planner, implementer]
        )
        let store = makeStore(run: run) { _, from, _, _ in
            #expect(from == "implementer")
            return .routes([PipelineRoute(to: "tester", requiresApproval: false, edgeKey: "implementer|done|tester")])
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.implementerNodeRunID, outcome: .done, summary: nil, outputPath: nil
        ))
        let updated = store.state.runs[id: Self.runID]
        // implementer's own handoff routed normally despite the run
        // sitting `.awaitingApproval` on auditor's unrelated gate.
        #expect(updated?.nodeRuns.contains { $0.nodeID == "tester" && $0.status == .spawning } == true)
        // The pre-existing pending approval survived untouched.
        #expect(updated?.pendingApprovals.map(\.toNodeID) == ["auditor"])
        #expect(updated?.status == .awaitingApproval)
    }

    @Test func completedTransitionCompletesRun() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in .completed }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .done
            $0.runs[id: Self.runID]?.status = .completed
        }
    }

    @Test func runOnlyCompletesOnceEveryBranchIsDoneAndAtLeastOneReachedDone() async {
        let planner = PipelineNodeRun(
            id: Self.nodeRunID, nodeID: "planner", status: .running,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let implementer = PipelineNodeRun(
            id: Self.implementerNodeRunID, nodeID: "implementer", status: .running,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let run = makeRun(status: .running, nodeRuns: [planner, implementer])
        let store = makeStore(run: run) { _, _, _, _ in .completed }

        // First branch dead-ends — the run must NOT complete yet, since
        // "implementer" is still active.
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        ))
        #expect(store.state.runs[id: Self.runID]?.status == .running)

        // Second (last) branch dead-ends too — now the run completes,
        // since at least one branch (both, here) reached `.done`.
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.implementerNodeRunID, outcome: .done, summary: nil, outputPath: nil
        ))
        #expect(store.state.runs[id: Self.runID]?.status == .completed)
    }

    @Test func failWithNoEdgeFailsRun() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in .failed(reason: "no fail edge") }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .fail, summary: "broke", outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .failed
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.summary = "broke"
            $0.runs[id: Self.runID]?.status = .failed
            $0.runs[id: Self.runID]?.statusDetail = "no fail edge"
        }
    }

    @Test func branchFailWithNoEdgeFailsWholeRunAndInterruptsSiblingBranches() async {
        let implementer = PipelineNodeRun(
            id: Self.nodeRunID, nodeID: "implementer", status: .running,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let auditor = PipelineNodeRun(
            id: Self.auditorNodeRunID, nodeID: "auditor", paneID: Self.paneID, status: .running,
            startedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let run = makeRun(status: .running, nodeRuns: [implementer, auditor])
        let store = makeStore(run: run) { _, _, _, _ in .failed(reason: "node \"implementer\" reported fail with no matching fail edge") }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .fail, summary: "broke", outputPath: nil
        ))
        let updated = store.state.runs[id: Self.runID]
        #expect(updated?.status == .failed)
        #expect(updated?.nodeRuns[id: Self.nodeRunID]?.status == .failed)
        // The still-active sibling branch is interrupted, not silently
        // left `.running` forever — its pane is left open (untouched).
        #expect(updated?.nodeRuns[id: Self.auditorNodeRunID]?.status == .interrupted)
        #expect(updated?.nodeRuns[id: Self.auditorNodeRunID]?.paneID == Self.paneID)
    }

    @Test func loopExhaustedFailsRunWithEdgeKeyDetail() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in .failed(reason: "loop_exhausted: auditor|fail|planner") }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .fail, summary: nil, outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .failed
            $0.runs[id: Self.runID]?.status = .failed
            $0.runs[id: Self.runID]?.statusDetail = "loop_exhausted: auditor|fail|planner"
        }
    }

    /// "A handoff while the run is paused is accepted and recorded;
    /// routing holds until resume" (issue section 4) — the fake engine
    /// asserting it's never called is the proof no routing happens.
    @Test func handoffWhilePausedIsRecordedButDoesNotRoute() async {
        let run = makeRun(status: .paused)
        let store = makeStore(run: run) { _, _, _, _ in
            Issue.record("engine should not be consulted while the run is paused")
            return .completed
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: "done anyway", outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .done
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.summary = "done anyway"
            // Run status untouched — still .paused.
        }
    }

    @Test func repeatSameOutcomeOnTerminalNodeIsIdempotentNoOp() async {
        let run = makeRun(status: .running, nodeRunStatus: .done)
        let callCount = LockedCounter()
        let store = makeStore(run: run) { _, _, _, _ in
            callCount.increment()
            return .completed
        }
        // No state-change expectation block — this must be a true no-op.
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        ))
        #expect(callCount.value == 0)
    }

    @Test func runsLoadedReplacesState() async {
        let store = TestStore(initialState: PipelinesFeature.State()) {
            PipelinesFeature()
        }
        let run = makeRun()
        await store.send(.runsLoaded([run])) {
            $0.runs = [run]
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() {
        lock.withLock { _value += 1 }
    }

    var value: Int { lock.withLock { _value } }
}
