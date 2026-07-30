import ComposableArchitecture
import Foundation

/// App-scoped run tracking for pipelines, modeled on `GraftFeature`.
/// Definitions themselves are NOT mirrored here — `PipelineDefinitionStore`
/// (filesystem, config-file-as-source-of-truth) is already the single
/// source of truth the CLI and the canvas editor both read through
/// directly, so duplicating a `definitions` cache here would just be a
/// second thing to keep in sync.
///
/// `insert(run:into:)` / `applyHandoff` are static and take `inout State`
/// so socket handlers (`AppReducer+PipelineSocket.swift`) can call them
/// directly and read the post-mutation state synchronously for the CLI
/// reply — the same requirement that makes `handleWorkspaceLabel` mutate
/// `state.workspaces` inline rather than round-tripping through a
/// dispatched action. The `Reduce` block below calls the exact same
/// functions, so `PipelinesFeatureTests` exercises the identical code
/// path via `TestStore`.
@Reducer
struct PipelinesFeature {
    @ObservableState
    struct State: Equatable {
        var runs: IdentifiedArrayOf<PipelineRun> = []
    }

    enum Action: Equatable {
        case runCreated(PipelineRun)
        case handoffReceived(
            runID: UUID,
            nodeRunID: UUID,
            outcome: PipelineNodeOutcome,
            summary: String?,
            outputPath: String?
        )
        /// Restores runs from GRDB on app launch (`.stateLoaded`).
        case runsLoaded([PipelineRun])
    }

    @Dependency(\.pipelineEngine) var pipelineEngine

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .runCreated(let run):
                Self.insert(run: run, into: &state)
                return .none

            case .handoffReceived(let runID, let nodeRunID, let outcome, let summary, let outputPath):
                _ = Self.applyHandoff(
                    runID: runID,
                    nodeRunID: nodeRunID,
                    outcome: outcome,
                    summary: summary,
                    outputPath: outputPath,
                    engine: pipelineEngine,
                    state: &state
                )
                return .none

            case .runsLoaded(let runs):
                state.runs = IdentifiedArrayOf(uniqueElements: runs)
                return .none
            }
        }
    }

    // MARK: - Shared mutation logic

    static func insert(run: PipelineRun, into state: inout State) {
        state.runs.append(run)
        state.runs = PipelineRun.pruned(state.runs)
    }

    enum HandoffResult: Equatable {
        case runNotFound
        case nodeRunNotFound
        /// Recorded while the run wasn't in a routing status (paused,
        /// awaitingApproval, or terminal) — routing holds until an
        /// explicit `pipeline resume` (phases 6-7) re-engages the run.
        case recorded(PipelineRun)
        /// Repeat of the same outcome for an already-terminal node run —
        /// no-op success (issue section 4: "idempotent on repeat
        /// same-outcome").
        case idempotent(PipelineRun)
        case applied(PipelineRun)
    }

    /// Records a handoff outcome against one `PipelineNodeRun` and, when
    /// the owning run is in a routing status, evaluates the resulting
    /// `PipelineTransition` via `engine.evaluateTransition`. Since node
    /// spawning doesn't exist yet (phases 6-7), a `.route` transition
    /// can never actually move to the next node — it pauses the run with
    /// a detail explaining why, rather than silently completing or
    /// dropping the handoff.
    static func applyHandoff(
        runID: UUID,
        nodeRunID: UUID,
        outcome: PipelineNodeOutcome,
        summary: String?,
        outputPath: String?,
        engine: PipelineEngine,
        state: inout State
    ) -> HandoffResult {
        guard var run = state.runs[id: runID] else { return .runNotFound }
        guard let existing = run.nodeRuns[id: nodeRunID] else { return .nodeRunNotFound }

        let newStatus = PipelineNodeRunStatus(outcome: outcome)
        if existing.status.isTerminal, existing.status == newStatus {
            return .idempotent(run)
        }

        var nodeRun = existing
        nodeRun.status = newStatus
        nodeRun.summary = summary
        if let outputPath {
            nodeRun.outputPath = outputPath
        }
        let now = Date()
        nodeRun.updatedAt = now
        nodeRun.completedAt = now
        run.nodeRuns[id: nodeRunID] = nodeRun
        run.updatedAt = now

        guard run.status.routesOnHandoff else {
            state.runs[id: runID] = run
            return .recorded(run)
        }

        let transition = engine.evaluateTransition(
            run.definitionSnapshot, nodeRun.nodeID, outcome, run.edgeTraversals
        )
        switch transition {
        case .completed:
            run.status = .completed
            run.statusDetail = nil
            run.completedAt = now

        case .failed(let reason):
            run.status = .failed
            run.statusDetail = reason
            run.completedAt = now

        case .loopExhausted(let edgeKey):
            run.status = .failed
            run.statusDetail = "loop_exhausted: \(edgeKey)"
            run.completedAt = now

        case .route(let to, let requiresApproval, let edgeKey):
            run.edgeTraversals[edgeKey, default: 0] += 1
            if requiresApproval {
                run.status = .awaitingApproval
                run.statusDetail = "edge \(edgeKey) → \"\(to)\" awaiting approval"
            } else {
                run.status = .paused
                run.statusDetail =
                    "would route to node \"\(to)\" — execution engine lands in a follow-up PR (phases 6-7)"
            }
        }

        state.runs[id: runID] = run
        return .applied(run)
    }
}
