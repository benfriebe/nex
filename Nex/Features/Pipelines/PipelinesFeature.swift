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
                    newNodeRunID: { uuid() },
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
    /// the entry node's first attempt, a fanned-out/bounced-back node's
    /// next attempt (`attempt` = 1 + however many prior NodeRuns this run
    /// already has for that node id), or an operator-initiated retry.
    /// `feedbackSourceNodeRunID` is the NodeRun whose handoff routed here
    /// (nil for the entry node and operator actions) — see
    /// `PipelineNodeRun.feedbackSourceNodeRunID`. Returns the new
    /// NodeRun's id, or nil if `runID` doesn't resolve.
    ///
    /// Deliberately does NOT touch `run.status`/`run.statusDetail` —
    /// with fan-out, several branches can be mid-flight (or gated behind
    /// separate pending approvals) at once, so only the caller knows
    /// what the run-level status should become after this append. Every
    /// call site sets it explicitly.
    @discardableResult
    static func appendNodeRun(
        runID: UUID,
        nodeID: String,
        newID: UUID,
        feedbackSourceNodeRunID: UUID? = nil,
        now: Date,
        state: inout State
    ) -> UUID? {
        guard var run = state.runs[id: runID] else { return nil }
        let attempt = run.nodeRuns.count { $0.nodeID == nodeID } + 1
        let nodeRun = PipelineNodeRun(
            id: newID, nodeID: nodeID, attempt: attempt,
            status: .spawning, feedbackSourceNodeRunID: feedbackSourceNodeRunID,
            startedAt: now, updatedAt: now
        )
        run.nodeRuns.append(nodeRun)
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
        /// Recorded while the run wasn't in a routing status (paused or
        /// terminal) — routing holds until an explicit `pipeline resume`
        /// re-engages the run.
        case recorded(PipelineRun)
        /// Repeat of the same outcome for an already-terminal node run —
        /// no-op success (issue section 4: "idempotent on repeat
        /// same-outcome").
        case idempotent(PipelineRun)
        /// Routing was evaluated. `spawnNodeRunIDs` lists every freshly
        /// appended `PipelineNodeRun` (`.spawning`, fan-out can produce
        /// more than one from a single handoff) the caller must follow up
        /// on by spawning/resuming its pane — empty when every fired edge
        /// either required approval (parked, nothing to spawn until
        /// `pipeline approve`) or coalesced into an already-active
        /// branch, or when this branch simply dead-ended.
        case applied(PipelineRun, spawnNodeRunIDs: [UUID])
    }

    /// Records a handoff outcome against one `PipelineNodeRun` and, when
    /// the owning run isn't paused/terminal, evaluates the resulting
    /// `PipelineTransition` via `engine.evaluateTransition`. Fan-out
    /// (issue #282 round 3): ALL edges matching `(from, outcome)` fire —
    /// each either parks a pending approval, coalesces into an already-
    /// active NodeRun for the same target (no double-spawn), or appends a
    /// fresh `PipelineNodeRun` and is reported back via `spawnNodeRunIDs`
    /// for `AppReducer` to actually spawn/resume (issue section 3). A
    /// branch that fails with no matching fail edge (or trips a
    /// `maxTraversals` guard) fails the WHOLE run and marks every other
    /// still-active NodeRun `.interrupted` — no AND-join/barrier
    /// semantics in this round (future work). This function only ever
    /// touches `PipelinesFeature.State`.
    static func applyHandoff(
        runID: UUID,
        nodeRunID: UUID,
        outcome: PipelineNodeOutcome,
        summary: String?,
        outputPath: String?,
        engine: PipelineEngine,
        newNodeRunID: () -> UUID,
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

        // A late handoff for a node the run stalled on clears the stall
        // and resumes routing (issue section 3: "clears the stall and
        // routes normally") rather than being merely recorded — but only
        // once every OTHER blocking branch has also cleared (fan-out can
        // leave more than one node `.stalled` under the same pause).
        // `existing.status` (captured before this handoff's mutation
        // above) is what to check — `run.blockingNodeRunIDs` no longer
        // includes `nodeRunID` at this point since `nodeRun`'s new
        // terminal status was already written into `run` above.
        if run.status == .paused, PipelineRunPauseReason.parse(run.statusDetail) == .stalledNode,
           existing.status == .stalled, run.blockingNodeRunIDs.isEmpty {
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

        switch transition {
        case .failed(let reason):
            state.runs[id: runID] = run
            return Self.failRun(runID: runID, reason: reason, state: &state)

        case .completed:
            state.runs[id: runID] = run
            return Self.finishRouting(runID: runID, spawnNodeRunIDs: [], state: &state)

        case .routes(let routes):
            var pendingApprovals = PipelinePendingApproval.parseAll(run.statusDetail)
            var spawnNodeRunIDs: [UUID] = []
            state.runs[id: runID] = run
            for route in routes {
                PipelinesFeature.updateRun(runID: runID, state: &state) {
                    $0.edgeTraversals[route.edgeKey, default: 0] += 1
                }
                let targetAlreadyQueued = pendingApprovals.contains { $0.toNodeID == route.to }
                let targetAlreadyActive = state.runs[id: runID]?.nodeRuns
                    .contains { $0.nodeID == route.to && $0.status.isActive } ?? false

                if route.requiresApproval {
                    if !targetAlreadyQueued {
                        pendingApprovals.append(PipelinePendingApproval(
                            toNodeID: route.to, edgeKey: route.edgeKey, fromNodeRunID: nodeRunID
                        ))
                    }
                } else if targetAlreadyActive || targetAlreadyQueued {
                    // Coalesced: the traversal is recorded above, but no
                    // second NodeRun/pane is spawned for an already-live
                    // (or already-gated-and-about-to-spawn) branch.
                    continue
                } else {
                    let newID = newNodeRunID()
                    Self.appendNodeRun(
                        runID: runID, nodeID: route.to, newID: newID,
                        feedbackSourceNodeRunID: nodeRunID, now: now, state: &state
                    )
                    spawnNodeRunIDs.append(newID)
                }
            }
            PipelinesFeature.updateRun(runID: runID, state: &state) {
                $0.statusDetail = pendingApprovals.isEmpty ? nil : PipelinePendingApproval.encodeAll(pendingApprovals)
            }
            return Self.finishRouting(runID: runID, spawnNodeRunIDs: spawnNodeRunIDs, state: &state)
        }
    }

    /// Fails the whole run and marks every other still-active branch
    /// `.interrupted` (its pane is left open — panes are never auto-closed
    /// in v1). The caller (`AppReducer+PipelineEngine`) is responsible for
    /// cancelling those branches' readiness/stop-grace timers.
    private static func failRun(runID: UUID, reason: String, state: inout State) -> HandoffResult {
        guard var run = state.runs[id: runID] else { return .runNotFound }
        let now = Date()
        for id in run.activeNodeRunIDs {
            run.nodeRuns[id: id]?.status = .interrupted
            run.nodeRuns[id: id]?.updatedAt = now
        }
        run.status = .failed
        run.statusDetail = reason
        run.completedAt = now
        run.updatedAt = now
        state.runs[id: runID] = run
        return .applied(run, spawnNodeRunIDs: [])
    }

    /// Recomputes the run-level aggregate status after routing: any
    /// pending approval (from ANY branch) shows as `.awaitingApproval`;
    /// with none pending and no active branches left, the run is
    /// `.completed` if at least one branch reached `.done`, else
    /// `.failed` (every branch dead-ended without ever succeeding — a
    /// misconfigured graph, not left hanging forever). Otherwise the run
    /// is still in progress and its status is left alone (an
    /// `.awaitingApproval` run whose last gate just got resolved by this
    /// same handoff reverts to `.running`).
    private static func finishRouting(runID: UUID, spawnNodeRunIDs: [UUID], state: inout State) -> HandoffResult {
        guard var run = state.runs[id: runID] else { return .runNotFound }
        let pendingApprovals = PipelinePendingApproval.parseAll(run.statusDetail)
        let now = Date()
        if !pendingApprovals.isEmpty {
            run.status = .awaitingApproval
        } else if run.activeNodeRunIDs.isEmpty {
            if run.nodeRuns.contains(where: { $0.status == .done }) {
                run.status = .completed
            } else {
                run.status = .failed
                run.statusDetail = "run finished with no branch reaching done"
            }
            run.completedAt = now
        } else if run.status == .awaitingApproval {
            run.status = .running
        }
        run.updatedAt = now
        state.runs[id: runID] = run
        return .applied(run, spawnNodeRunIDs: spawnNodeRunIDs)
    }
}

/// One pending routing target while a run sits `.awaitingApproval`,
/// encoded into `PipelineRun.statusDetail` (no DB column of its own — the
/// same free-text-with-a-parseable-prefix convention as
/// `PipelineRunPauseReason`). With fan-out (issue #282 round 3) several of
/// these can be pending at once — one per gated branch — so the whole
/// list round-trips through the one free-text column as consecutive
/// `[approval ...]` tokens. Node ids and edge keys are slug/pipe-joined
/// text with no spaces, so a simple space-delimited `key=value` scan is
/// safe. `edgeKey` (`PipelineEdge.identityKey`) is unique among
/// concurrently-pending approvals — the same edge can't fire twice before
/// its source NodeRun (already terminal once it hands off) fires again.
struct PipelinePendingApproval: Equatable, Identifiable {
    var toNodeID: String
    var edgeKey: String
    /// The NodeRun whose handoff fired this gated edge — carried through
    /// to the spawned NodeRun's `feedbackSourceNodeRunID` on approval.
    var fromNodeRunID: UUID

    var id: String { edgeKey }

    static func encodeAll(_ approvals: [Self]) -> String? {
        guard !approvals.isEmpty else { return nil }
        let tokens = approvals.map {
            "[approval to=\($0.toNodeID) edge=\($0.edgeKey) from=\($0.fromNodeRunID.uuidString)]"
        }
        return tokens.joined(separator: " ") + " — \(approvals.count) pending approval\(approvals.count == 1 ? "" : "s")"
    }

    static func parseAll(_ detail: String?) -> [Self] {
        guard let detail else { return [] }
        var results: [Self] = []
        var searchStart = detail.startIndex
        while let openRange = detail.range(of: "[approval ", range: searchStart ..< detail.endIndex),
              let closeIndex = detail[openRange.upperBound...].firstIndex(of: "]") {
            let inner = detail[openRange.upperBound ..< closeIndex]
            var toNodeID: String?
            var edgeKey: String?
            var fromNodeRunID: UUID?
            for part in inner.split(separator: " ") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "to": toNodeID = String(kv[1])
                case "edge": edgeKey = String(kv[1])
                case "from": fromNodeRunID = UUID(uuidString: String(kv[1]))
                default: break
                }
            }
            if let toNodeID, let edgeKey, let fromNodeRunID {
                results.append(Self(toNodeID: toNodeID, edgeKey: edgeKey, fromNodeRunID: fromNodeRunID))
            }
            searchStart = detail.index(after: closeIndex)
        }
        return results
    }
}
