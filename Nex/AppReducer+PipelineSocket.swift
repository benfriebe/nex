import ComposableArchitecture
import Foundation

/// Socket handlers for the `pipeline-*` wire commands (issue #282 phases
/// 5-7). Mirrors the `handleGraft*` family in `AppReducer+Socket.swift`:
/// synchronous `inout State` mutation so the reply reflects the
/// post-mutation state, `reply?.sendAndClose(...)` for the response, and
/// tolerance for `reply == nil` (the legacy fire-and-forget path — not
/// actually reachable for these commands since they're all in
/// `replyCommandAllowlist`, but every other handler in this codebase
/// guards the same way). The actual execution engine (spawn/handoff
/// routing/liveness) lives in `AppReducer+PipelineEngine.swift`; this
/// file stays the validation + wire-shape boundary.
extension AppReducer {
    // MARK: - pipeline run

    /// Outcome of `createPipelineRun` — the shared validate → create →
    /// launch core used by both the socket handler (below) and the GUI
    /// play-button entry point (`AppReducer+PipelineEngine.swift`'s
    /// `handlePipelineRunFromPane`).
    enum CreatePipelineRunResult {
        case failure(message: String, issues: [PipelineValidationIssue])
        case created(runID: UUID, effect: Effect<Action>)
    }

    func createPipelineRun(
        _ state: inout State,
        paneID: UUID?,
        name: String,
        inputs: [String: String]
    ) -> CreatePipelineRunResult {
        func fail(_ message: String, issues: [PipelineValidationIssue] = []) -> CreatePipelineRunResult {
            .failure(message: message, issues: issues)
        }

        let definition: PipelineDefinition
        do {
            definition = try pipelineDefinitionStore.load(name)
        } catch {
            return fail("pipeline \"\(name)\" could not be loaded: \(String(describing: error))")
        }

        let issues = definition.validate()
        if issues.contains(where: { $0.severity == .error }) {
            return fail("pipeline \"\(name)\" failed validation", issues: issues)
        }

        let missingInputs = definition.inputs
            .filter(\.value.required)
            .keys
            .filter { (inputs[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
            .sorted()
        guard missingInputs.isEmpty else {
            return fail("pipeline \"\(name)\" is missing required input(s): \(missingInputs.joined(separator: ", "))")
        }

        // `location: current` resolves a workspace synchronously so the
        // caller can validate it up front; `workspace`/`worktree` mint
        // their own workspace asynchronously post-reply (only genuinely
        // async failures — worktree add, spawn — surface post-reply via
        // `pipeline status`/`watch`, per issue section 4).
        var resolvedWorkspaceID: UUID?
        if definition.location == .current {
            if let paneID, let workspace = state.workspaceContainingPane(paneID) {
                resolvedWorkspaceID = workspace.id
            } else if let activeID = state.activeWorkspaceID, state.workspaces[id: activeID] != nil {
                resolvedWorkspaceID = activeID
            } else {
                return fail("pipeline run requires NEX_PANE_ID (run from inside a pane) or an active workspace")
            }
        }

        let runID = uuid()
        let now = Date()
        let run = PipelineRun(
            id: runID,
            definitionID: definition.id,
            definitionSnapshot: definition,
            status: .launching,
            location: definition.location,
            workspaceID: resolvedWorkspaceID,
            runDir: PipelineRun.runDirectory(for: runID),
            inputs: inputs,
            createdAt: now,
            updatedAt: now
        )
        PipelinesFeature.insert(run: run, into: &state.pipelines)

        let effect = Effect<Action>.merge(.send(.persistState), pipelineLaunchRun(&state, runID: runID))
        return .created(runID: runID, effect: effect)
    }

    func handlePipelineRun(
        _ state: inout State,
        paneID: UUID?,
        name: String,
        inputs: [String: String],
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        switch createPipelineRun(&state, paneID: paneID, name: name, inputs: inputs) {
        case .failure(let message, let issues):
            var payload: [String: Any] = ["ok": false, "error": message]
            if !issues.isEmpty {
                payload["issues"] = issues.map(Self.issueJSON)
            }
            reply?.sendAndClose(payload)
            return .none
        case .created(let runID, let effect):
            reply?.sendAndClose([
                "ok": true,
                "run_id": runID.uuidString,
                "status": state.pipelines.runs[id: runID]?.status.rawValue ?? ""
            ])
            return effect
        }
    }

    // MARK: - pipeline handoff

    /// Resolves the `(runID, nodeRunID)` a handoff applies to. The
    /// pane-scoped path finds the NodeRun whose `paneID` matches the
    /// caller and is still live (`running` / `awaitingHuman`); the
    /// forced path requires both `--run` and `--node` and matches by
    /// node slug within that run. Neither path ever matches anything in
    /// this PR — no NodeRun is ever bound to a pane without the spawn
    /// delegate (phases 6-7) — so callers reliably see a structured
    /// "no active node" error, which is the documented behaviour until
    /// then.
    private enum HandoffTargetResolution {
        case found(runID: UUID, nodeRunID: UUID)
        case notFound(String)
    }

    private func resolveHandoffTarget(
        paneID: UUID?,
        runID: String?,
        nodeID: String?,
        force: Bool,
        state: State
    ) -> HandoffTargetResolution {
        if force {
            guard let runIDString = runID, let runUUID = UUID(uuidString: runIDString),
                  let run = state.pipelines.runs[id: runUUID] else {
                return .notFound("no such pipeline run '\(runID ?? "")'")
            }
            // The LATEST attempt, not the first — a node past attempt 1
            // (e.g. a bounce-back retry) must still be force-resolvable;
            // matching the first NodeRun would keep hitting an
            // already-terminal attempt 1 forever (found live, issue
            // #282 validation).
            guard let nodeID, let nodeRun = run.nodeRuns
                .filter({ $0.nodeID == nodeID })
                .max(by: { $0.attempt < $1.attempt })
            else {
                return .notFound("no node run for node '\(nodeID ?? "")' in run \(run.id.uuidString)")
            }
            return .found(runID: run.id, nodeRunID: nodeRun.id)
        }
        guard let paneID else {
            return .notFound("pipeline handoff requires NEX_PANE_ID, or --run/--node with --force from outside a pane")
        }
        for run in state.pipelines.runs {
            if let nodeRun = run.nodeRuns.first(where: {
                $0.paneID == paneID && ($0.status == .running || $0.status == .awaitingHuman)
            }) {
                return .found(runID: run.id, nodeRunID: nodeRun.id)
            }
        }
        return .notFound("no active pipeline node for this pane")
    }

    func handlePipelineHandoff(
        _ state: inout State,
        paneID: UUID?,
        outcome: PipelineNodeOutcome,
        summary: String?,
        output: String?,
        runID: String?,
        nodeID: String?,
        force: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        func fail(_ message: String) -> Effect<Action> {
            reply?.sendAndClose(["ok": false, "error": message])
            return .none
        }

        if force, runID == nil || nodeID == nil {
            return fail("--force requires both --run and --node")
        }

        switch resolveHandoffTarget(paneID: paneID, runID: runID, nodeID: nodeID, force: force, state: state) {
        case .notFound(let message):
            return fail(message)
        case .found(let targetRunID, let targetNodeRunID):
            let result = PipelinesFeature.applyHandoff(
                runID: targetRunID,
                nodeRunID: targetNodeRunID,
                outcome: outcome,
                summary: summary,
                outputPath: output,
                engine: pipelineEngine,
                newNodeRunID: { self.uuid() },
                state: &state.pipelines
            )
            switch result {
            case .runNotFound, .nodeRunNotFound:
                return fail("internal error resolving pipeline node run")
            case .applied(let run, _), .recorded(let run), .idempotent(let run):
                let nodeRun = run.nodeRuns[id: targetNodeRunID]
                reply?.sendAndClose([
                    "ok": true,
                    "run_id": run.id.uuidString,
                    "node_run_id": targetNodeRunID.uuidString,
                    "node_id": nodeRun?.nodeID ?? "",
                    "node_status": nodeRun?.status.rawValue ?? "",
                    "run_status": run.status.rawValue
                ])
                // Cancel this node's readiness/stop-grace timers before
                // following up — a handoff always supersedes them,
                // whether it clears a stall, completes the run, or hands
                // off to the next spawn.
                return .merge(pipelineCancelTimers(nodeRunID: targetNodeRunID), pipelineFollowUpOnHandoff(&state, result: result))
            }
        }
    }

    // MARK: - pipeline cancel / retry / approve / deny / resume

    /// Shared resolution + dispatch for the five single-run manual
    /// control verbs — each just differs in which `AppReducer` orchestrator
    /// to call and what an already-terminal/mismatched-status run should
    /// reply as an error.
    private func handlePipelineControl(
        _ state: inout State,
        runIDString: String,
        reply: SocketServer.ReplyHandle?,
        precondition: (PipelineRun) -> String?,
        orchestrate: (inout State, UUID) -> Effect<Action>
    ) -> Effect<Action> {
        guard let runUUID = UUID(uuidString: runIDString), let run = state.pipelines.runs[id: runUUID] else {
            reply?.sendAndClose(["ok": false, "error": "no such pipeline run '\(runIDString)'"])
            return .none
        }
        if let error = precondition(run) {
            reply?.sendAndClose(["ok": false, "error": error])
            return .none
        }
        let effect = orchestrate(&state, runUUID)
        reply?.sendAndClose(["ok": true, "run_id": runUUID.uuidString, "status": state.pipelines.runs[id: runUUID]?.status.rawValue ?? ""])
        return effect
    }

    func handlePipelineCancel(_ state: inout State, runID: String, reply: SocketServer.ReplyHandle?) -> Effect<Action> {
        handlePipelineControl(
            &state, runIDString: runID, reply: reply,
            precondition: { $0.status.isTerminal ? "run is already \($0.status.rawValue)" : nil },
            orchestrate: { s, id in self.pipelineCancel(&s, runID: id) }
        )
    }

    func handlePipelineRetry(_ state: inout State, runID: String, reply: SocketServer.ReplyHandle?) -> Effect<Action> {
        handlePipelineControl(
            &state, runIDString: runID, reply: reply,
            precondition: { $0.nodeRuns.isEmpty ? "run has no node to retry" : nil },
            orchestrate: { s, id in self.pipelineRetry(&s, runID: id) }
        )
    }

    /// Approve/deny share the same ambiguity rule: with fan-out (issue
    /// #282 round 3) more than one branch can be gated at once, so
    /// `--edge <key>` is required unless there's exactly one pending
    /// approval — an omitted/unmatched edge on an ambiguous run is
    /// rejected up front with the candidate keys rather than silently
    /// no-op'ing (`AppReducer+PipelineEngine.pipelineApprove`/`Deny`
    /// already no-op on an unresolved target for the same reason).
    private func pendingApprovalPrecondition(_ run: PipelineRun, edgeKey: String?) -> String? {
        guard run.status == .awaitingApproval else {
            return "run is not awaiting approval (status: \(run.status.rawValue))"
        }
        let pending = run.pendingApprovals
        if let edgeKey {
            return pending.contains { $0.edgeKey == edgeKey }
                ? nil
                : "no pending approval for edge '\(edgeKey)' — pending: \(pending.map(\.edgeKey).joined(separator: ", "))"
        }
        if pending.count > 1 {
            return "multiple pending approvals — pass --edge (one of: \(pending.map(\.edgeKey).joined(separator: ", ")))"
        }
        return nil
    }

    func handlePipelineApprove(_ state: inout State, runID: String, edgeKey: String?, reply: SocketServer.ReplyHandle?) -> Effect<Action> {
        handlePipelineControl(
            &state, runIDString: runID, reply: reply,
            precondition: { self.pendingApprovalPrecondition($0, edgeKey: edgeKey) },
            orchestrate: { s, id in self.pipelineApprove(&s, runID: id, edgeKey: edgeKey) }
        )
    }

    func handlePipelineDeny(_ state: inout State, runID: String, edgeKey: String?, reply: SocketServer.ReplyHandle?) -> Effect<Action> {
        handlePipelineControl(
            &state, runIDString: runID, reply: reply,
            precondition: { self.pendingApprovalPrecondition($0, edgeKey: edgeKey) },
            orchestrate: { s, id in self.pipelineDeny(&s, runID: id, edgeKey: edgeKey) }
        )
    }

    func handlePipelineResume(_ state: inout State, runID: String, reply: SocketServer.ReplyHandle?) -> Effect<Action> {
        handlePipelineControl(
            &state, runIDString: runID, reply: reply,
            precondition: {
                guard $0.status == .paused else { return "run is not paused (status: \($0.status.rawValue))" }
                return nil
            },
            orchestrate: { s, id in self.pipelineResume(&s, runID: id) }
        )
    }

    // MARK: - pipeline watch

    /// `nex pipeline watch <run-id>` — streaming via a held `ReplyHandle`
    /// (`AppReducer.State.pipelineWatchSubscribers`), the exact
    /// `webConsoleSubscribers` shape. Sends the run's current snapshot
    /// immediately (so a `watch` against an already-terminal run still
    /// gets one line before closing), then leaves the handle open for
    /// `pipelineFanOutWatch` to push further transitions.
    func handlePipelineWatch(_ state: inout State, runID: String, reply: SocketServer.ReplyHandle?) {
        guard let runUUID = UUID(uuidString: runID), let run = state.pipelines.runs[id: runUUID] else {
            reply?.send(["ok": false, "error": "no such pipeline run '\(runID)'"])
            reply?.close()
            return
        }
        guard let reply else { return }
        reply.send(["ok": true, "run": Self.runJSON(run)])
        if run.status.isTerminal {
            reply.close()
            return
        }
        state.pipelineWatchSubscribers[runUUID, default: [:]][reply.id] = reply
    }

    // MARK: - pipeline status

    func handlePipelineStatus(state: State, runID: String?, reply: SocketServer.ReplyHandle?) {
        if let runIDString = runID {
            guard let runUUID = UUID(uuidString: runIDString), let run = state.pipelines.runs[id: runUUID] else {
                reply?.sendAndClose(["ok": false, "error": "no such pipeline run '\(runIDString)'"])
                return
            }
            reply?.sendAndClose(["ok": true, "run": Self.runJSON(run)])
        } else {
            reply?.sendAndClose(["ok": true, "runs": state.pipelines.runs.map(Self.runJSON)])
        }
    }

    // MARK: - pipeline list / validate

    func handlePipelineList(reply: SocketServer.ReplyHandle?) {
        let items: [[String: Any]] = pipelineDefinitionStore.list().map { id in
            guard let definition = try? pipelineDefinitionStore.load(id) else {
                return ["id": id, "name": id, "error": "failed to load"]
            }
            let issues = definition.validate()
            return [
                "id": id,
                "name": definition.name,
                "node_count": definition.nodes.count,
                "edge_count": definition.edges.count,
                "error_count": issues.count(where: { $0.severity == .error }),
                "warning_count": issues.count(where: { $0.severity == .warning })
            ]
        }
        reply?.sendAndClose(["ok": true, "pipelines": items])
    }

    func handlePipelineValidate(name: String, reply: SocketServer.ReplyHandle?) {
        let definition: PipelineDefinition
        do {
            definition = try pipelineDefinitionStore.load(name)
        } catch {
            reply?.sendAndClose(["ok": false, "error": String(describing: error)])
            return
        }
        let issues = definition.validate()
        reply?.sendAndClose([
            "ok": true,
            "id": definition.id,
            "name": definition.name,
            "valid": !issues.contains { $0.severity == .error },
            "issues": issues.map(Self.issueJSON)
        ])
    }

    // MARK: - JSON helpers

    private static func issueJSON(_ issue: PipelineValidationIssue) -> [String: Any] {
        var dict: [String: Any] = ["severity": issue.severity.rawValue, "message": issue.message]
        if let nodeID = issue.nodeID {
            dict["node_id"] = nodeID
        }
        if let edgeIndex = issue.edgeIndex {
            dict["edge_index"] = edgeIndex
        }
        return dict
    }

    static func runJSON(_ run: PipelineRun) -> [String: Any] {
        // Fan-out (issue #282 round 3): every branch is independently
        // identifiable by node id, both per-NodeRun (`node_id`,
        // `from_node_run_id`) and at the run level (`active_node_ids`,
        // `pending_approvals`) — `pipeline status`/`watch` consumers
        // can't assume a single "the current node" anymore.
        var dict: [String: Any] = [
            "id": run.id.uuidString,
            "definition_id": run.definitionID,
            "status": run.status.rawValue,
            "location": run.location.rawValue,
            "run_dir": run.runDir,
            "active_node_ids": run.activeNodeRunIDs.compactMap { run.nodeRuns[id: $0]?.nodeID },
            "created_at": ISO8601DateFormatter().string(from: run.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: run.updatedAt),
            "node_runs": run.nodeRuns.map { nodeRun -> [String: Any] in
                var nrDict: [String: Any] = [
                    "id": nodeRun.id.uuidString,
                    "node_id": nodeRun.nodeID,
                    "attempt": nodeRun.attempt,
                    "status": nodeRun.status.rawValue
                ]
                if let paneID = nodeRun.paneID {
                    nrDict["pane_id"] = paneID.uuidString
                }
                if let summary = nodeRun.summary {
                    nrDict["summary"] = summary
                }
                if let sourceID = nodeRun.feedbackSourceNodeRunID {
                    nrDict["from_node_run_id"] = sourceID.uuidString
                    nrDict["from_node_id"] = run.nodeRuns[id: sourceID]?.nodeID
                }
                return nrDict
            }
        ]
        if let statusDetail = run.statusDetail {
            dict["status_detail"] = statusDetail
        }
        if run.status == .awaitingApproval {
            dict["pending_approvals"] = run.pendingApprovals.map { pending -> [String: Any] in
                ["to_node_id": pending.toNodeID, "edge": pending.edgeKey]
            }
        }
        if let workspaceID = run.workspaceID {
            dict["workspace_id"] = workspaceID.uuidString
        }
        return dict
    }
}
