import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises `PipelinesFeature`'s run-lifecycle logic through
/// `TestStore`, with a fake `PipelineEngine` so routing scenarios
/// (bounce-back, declared-only `maxTraversals`, partial→done fallback,
/// approval gates) don't need a real `PipelineDefinition` graph.
/// `.running` runs are hand-seeded — production `pipeline run` (this
/// PR) always lands a run `.paused`, since node spawning is a follow-up
/// (phases 6-7); these tests exercise the routing spine ahead of that
/// wiring landing.
@MainActor
struct PipelinesFeatureTests {
    private static let runID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
    private static let nodeRunID = UUID(uuidString: "80000000-0000-0000-0000-0000000000A1")!
    private static let paneID = UUID(uuidString: "80000000-0000-0000-0000-0000000000B1")!

    private func makeDefinition() -> PipelineDefinition {
        var definition = PipelineDefinition(id: "loop", name: "Loop", entry: "planner")
        definition.nodes = [PipelineNode(id: "planner"), PipelineNode(id: "implementer")]
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
        return PipelineRun(
            id: Self.runID,
            definitionID: "loop",
            definitionSnapshot: makeDefinition(),
            status: status,
            location: .current,
            runDir: "/runs/\(Self.runID.uuidString)",
            nodeRuns: [nodeRun],
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
            return .route(to: "implementer", requiresApproval: false, edgeKey: "planner|done")
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: "done", outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .done
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.summary = "done"
            $0.runs[id: Self.runID]?.status = .paused
            $0.runs[id: Self.runID]?.statusDetail =
                "would route to node \"implementer\" — execution engine lands in a follow-up PR (phases 6-7)"
            $0.runs[id: Self.runID]?.edgeTraversals["planner|done"] = 1
        }
    }

    @Test func approvalGateEdgeSetsAwaitingApproval() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in
            .route(to: "implementer", requiresApproval: true, edgeKey: "planner|done")
        }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .done, summary: nil, outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .done
            $0.runs[id: Self.runID]?.status = .awaitingApproval
            $0.runs[id: Self.runID]?.statusDetail = "edge planner|done → \"implementer\" awaiting approval"
            $0.runs[id: Self.runID]?.edgeTraversals["planner|done"] = 1
        }
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

    @Test func loopExhaustedFailsRunWithEdgeKeyDetail() async {
        let run = makeRun(status: .running)
        let store = makeStore(run: run) { _, _, _, _ in .loopExhausted(edgeKey: "auditor|fail") }
        await store.send(.handoffReceived(
            runID: Self.runID, nodeRunID: Self.nodeRunID, outcome: .fail, summary: nil, outputPath: nil
        )) {
            $0.runs[id: Self.runID]?.nodeRuns[id: Self.nodeRunID]?.status = .failed
            $0.runs[id: Self.runID]?.status = .failed
            $0.runs[id: Self.runID]?.statusDetail = "loop_exhausted: auditor|fail"
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
