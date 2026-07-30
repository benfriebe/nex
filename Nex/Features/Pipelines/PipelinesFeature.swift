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

        /// Async re-entry points for the execution engine (phase 6). Every
        /// other engine step (spawn decision, handoff routing, liveness
        /// forwarding) runs synchronously against `AppReducer.State` from
        /// `AppReducer+PipelineEngine.swift` and doesn't need a dispatched
        /// action — these three exist ONLY because a `.run` effect can't
        /// mutate state directly and must `send` its way back in.
        case delegate(Delegate)

        enum Delegate: Equatable {
            /// The launch/resume command was typed into `paneID`; start the
            /// 30s SessionStart readiness gate (issue section 3).
            case nodeCommandTyped(runID: UUID, nodeRunID: UUID, paneID: UUID, command: String, isResume: Bool)
            /// No SessionStart within 30s. `isRetry == false` → retype the
            /// command once and re-arm the gate; `isRetry == true` → the
            /// retry also timed out, so the node fails synthetically.
            case readinessTimedOut(runID: UUID, nodeRunID: UUID, paneID: UUID, command: String, isResume: Bool, isRetry: Bool)
            /// The pane never came into existence (`surfaceManager.surface`
            /// stayed nil past the poll budget), or `composeLaunchCommand`
            /// rejected the node (unsafe model/env). Fails the node
            /// synthetically the same way a readiness-gate exhaustion does.
            case spawnFailed(runID: UUID, nodeRunID: UUID, reason: String)
            /// 120s elapsed since a handoff-less Stop with no intervening
            /// handoff — stall the node (issue section 3, never guess).
            case stopGraceElapsed(runID: UUID, nodeRunID: UUID)
            /// `location: workspace`/`worktree` provisioning (dispatched
            /// as a `.createWorkspace`, possibly after an async worktree
            /// add) has landed — now that `run.workspaceID` resolves to a
            /// real workspace, spawn the entry node.
            case beginEntryNode(runID: UUID)
            /// The async half of `location: workspace`/`worktree`
            /// provisioning failed (e.g. `git worktree add`) — the run
            /// never got a chance to spawn anything.
            case locationProvisionFailed(runID: UUID, reason: String)
        }
    }

    @Dependency(\.pipelineEngine) var pipelineEngine
    @Dependency(\.uuid) var uuid

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
                    newNodeRunID: uuid(),
                    state: &state
                )
                return .none

            case .runsLoaded(let runs):
                state.runs = IdentifiedArrayOf(uniqueElements: runs)
                return .none

            case .delegate:
                // Purely a signal for `AppReducer`'s core switch, which
                // owns `surfaceManager` / workspace state and reacts in
                // `AppReducer+PipelineEngine.swift`. Nothing for this
                // reducer's own state to do.
                return .none
            }
        }
    }

    // MARK: - Shared mutation logic

    static func insert(run: PipelineRun, into state: inout State) {
        state.runs.append(run)
        state.runs = PipelineRun.pruned(state.runs)
    }

    /// Appends a new `PipelineNodeRun` (`.spawning`) for `nodeID` — either
    /// the entry node's first attempt, or the next attempt of a
    /// bounced-back node (`attempt` = 1 + however many prior NodeRuns this
    /// run already has for that node id). Sets it as `currentNodeRunID`
    /// and moves the run to `.launching`. Returns the new NodeRun's id, or
    /// nil if `runID` doesn't resolve.
    @discardableResult
    static func appendNodeRun(
        runID: UUID,
        nodeID: String,
        newID: UUID,
        now: Date,
        state: inout State
    ) -> UUID? {
        guard var run = state.runs[id: runID] else { return nil }
        let attempt = run.nodeRuns.count { $0.nodeID == nodeID } + 1
        let nodeRun = PipelineNodeRun(
            id: newID, nodeID: nodeID, attempt: attempt,
            status: .spawning, startedAt: now, updatedAt: now
        )
        run.nodeRuns.append(nodeRun)
        run.currentNodeRunID = newID
        run.status = .launching
        run.statusDetail = nil
        run.updatedAt = now
        state.runs[id: runID] = run
        return newID
    }

    /// Generic NodeRun field mutator used throughout the engine (binding a
    /// pane, rebinding a session id, flipping status) so every call site
    /// doesn't hand-roll the `runs[id:].nodeRuns[id:]` chain.
    static func updateNodeRun(runID: UUID, nodeRunID: UUID, state: inout State, _ body: (inout PipelineNodeRun) -> Void) {
        guard var run = state.runs[id: runID], var nodeRun = run.nodeRuns[id: nodeRunID] else { return }
        body(&nodeRun)
        nodeRun.updatedAt = Date()
        run.nodeRuns[id: nodeRunID] = nodeRun
        run.updatedAt = Date()
        state.runs[id: runID] = run
    }

    /// Generic run-level mutator (status/detail changes: approval,
    /// cancel, resume, stall, provisioning).
    static func updateRun(runID: UUID, state: inout State, _ body: (inout PipelineRun) -> Void) {
        guard var run = state.runs[id: runID] else { return }
        body(&run)
        run.updatedAt = Date()
        state.runs[id: runID] = run
    }

    enum HandoffResult: Equatable {
        case runNotFound
        case nodeRunNotFound
        /// Recorded while the run wasn't in a routing status (paused,
        /// awaitingApproval, or terminal) — routing holds until an
        /// explicit `pipeline resume` re-engages the run.
        case recorded(PipelineRun)
        /// Repeat of the same outcome for an already-terminal node run —
        /// no-op success (issue section 4: "idempotent on repeat
        /// same-outcome").
        case idempotent(PipelineRun)
        /// Routed to a new node. `spawnNodeRunID` is set (and a fresh
        /// `PipelineNodeRun` already appended in `.spawning`) when the
        /// edge didn't require approval — the caller (`AppReducer`) must
        /// follow up by spawning/resuming that NodeRun's pane. Nil when
        /// the edge required approval instead (run parked
        /// `.awaitingApproval`; nothing to spawn until `pipeline approve`).
        case applied(PipelineRun, spawnNodeRunID: UUID?)
    }

    /// Records a handoff outcome against one `PipelineNodeRun` and, when
    /// the owning run is in a routing status, evaluates the resulting
    /// `PipelineTransition` via `engine.evaluateTransition`. A `.route`
    /// transition either parks the run `.awaitingApproval` (gated edge) or
    /// immediately appends the next node's `PipelineNodeRun` and reports
    /// its id back via `spawnNodeRunID` — `AppReducer` follows up by
    /// actually spawning/resuming that node's pane (issue section 3);
    /// this function only ever touches `PipelinesFeature.State`.
    static func applyHandoff(
        runID: UUID,
        nodeRunID: UUID,
        outcome: PipelineNodeOutcome,
        summary: String?,
        outputPath: String?,
        engine: PipelineEngine,
        newNodeRunID: UUID,
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

        // A late handoff for the node the run stalled on clears the stall
        // and resumes routing (issue section 3: "clears the stall and
        // routes normally") rather than being merely recorded.
        if run.status == .paused, PipelineRunPauseReason.parse(run.statusDetail) == .stalledNode,
           run.currentNodeRunID == nodeRunID {
            run.status = .running
            run.statusDetail = nil
        }

        guard run.status.routesOnHandoff else {
            state.runs[id: runID] = run
            return .recorded(run)
        }

        let transition = engine.evaluateTransition(
            run.definitionSnapshot, nodeRun.nodeID, outcome, run.edgeTraversals
        )
        var spawnNodeRunID: UUID?
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
                run.statusDetail = PipelinePendingApproval.encode(
                    PipelinePendingApproval(toNodeID: to, edgeKey: edgeKey),
                    message: "edge \(edgeKey) → \"\(to)\" awaiting approval"
                )
            } else {
                state.runs[id: runID] = run
                spawnNodeRunID = Self.appendNodeRun(
                    runID: runID, nodeID: to, newID: newNodeRunID, now: now, state: &state
                )
                run = state.runs[id: runID] ?? run
            }
        }

        state.runs[id: runID] = run
        return .applied(run, spawnNodeRunID: spawnNodeRunID)
    }
}

/// The pending routing target while a run sits `.awaitingApproval`,
/// encoded into `PipelineRun.statusDetail` (no DB column of its own — the
/// same free-text-with-a-parseable-prefix convention as
/// `PipelineRunPauseReason`). Node ids and edge keys are slug/pipe-joined
/// text with no spaces, so a simple space-delimited `key=value` scan is
/// safe.
struct PipelinePendingApproval: Equatable {
    var toNodeID: String
    var edgeKey: String

    static func encode(_ pending: Self, message: String) -> String {
        "[approval to=\(pending.toNodeID) edge=\(pending.edgeKey)] \(message)"
    }

    static func parse(_ detail: String?) -> Self? {
        guard let detail, detail.hasPrefix("[approval "), let end = detail.firstIndex(of: "]") else { return nil }
        let start = detail.index(detail.startIndex, offsetBy: "[approval ".count)
        guard start <= end else { return nil }
        var toNodeID: String?
        var edgeKey: String?
        for part in detail[start ..< end].split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "to" {
                toNodeID = String(kv[1])
            }
            if kv[0] == "edge" {
                edgeKey = String(kv[1])
            }
        }
        guard let toNodeID, let edgeKey else { return nil }
        return Self(toNodeID: toNodeID, edgeKey: edgeKey)
    }
}
