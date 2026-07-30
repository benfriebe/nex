import ComposableArchitecture
import Foundation

/// Socket handlers for the `pipeline-*` wire commands (issue #282 phase
/// 5). Mirrors the `handleGraft*` family in `AppReducer+Socket.swift`:
/// synchronous `inout State` mutation so the reply reflects the
/// post-mutation state, `reply?.sendAndClose(...)` for the response, and
/// tolerance for `reply == nil` (the legacy fire-and-forget path — not
/// actually reachable for these commands since they're all in
/// `replyCommandAllowlist`, but every other handler in this codebase
/// guards the same way).
///
/// **Phase-6 boundary**: node spawning doesn't exist yet. `pipeline run`
/// still does the full validate-before-reply + run creation +
/// persistence — it just can't hand the run to anything, so it lands
/// `.paused` with a detail explaining why, never a silent no-op.
extension AppReducer {
    // MARK: - pipeline run

    func handlePipelineRun(
        _ state: inout State,
        paneID: UUID?,
        name: String,
        inputs: [String: String],
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        func fail(_ message: String, issues: [PipelineValidationIssue] = []) -> Effect<Action> {
            var payload: [String: Any] = ["ok": false, "error": message]
            if !issues.isEmpty {
                payload["issues"] = issues.map(Self.issueJSON)
            }
            reply?.sendAndClose(payload)
            return .none
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

        guard definition.location == .current else {
            return fail(
                "pipeline \"\(name)\" has location \"\(definition.location.rawValue)\" — only " +
                    "'current' is supported until the workspace/worktree run engine lands (phases 6-7)"
            )
        }

        let missingInputs = definition.inputs
            .filter(\.value.required)
            .keys
            .filter { (inputs[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
            .sorted()
        guard missingInputs.isEmpty else {
            return fail("pipeline \"\(name)\" is missing required input(s): \(missingInputs.joined(separator: ", "))")
        }

        let resolvedWorkspaceID: UUID
        if let paneID, let workspace = state.workspaceContainingPane(paneID) {
            resolvedWorkspaceID = workspace.id
        } else if let activeID = state.activeWorkspaceID, state.workspaces[id: activeID] != nil {
            resolvedWorkspaceID = activeID
        } else {
            return fail("pipeline run requires NEX_PANE_ID (run from inside a pane) or an active workspace")
        }

        let runID = uuid()
        let now = Date()
        let run = PipelineRun(
            id: runID,
            definitionID: definition.id,
            definitionSnapshot: definition,
            status: .paused,
            statusDetail:
            "created; execution engine lands in a follow-up PR (phases 6-7) — no pipeline nodes have been spawned",
            location: definition.location,
            workspaceID: resolvedWorkspaceID,
            runDir: PipelineRun.runDirectory(for: runID),
            inputs: inputs,
            createdAt: now,
            updatedAt: now
        )
        PipelinesFeature.insert(run: run, into: &state.pipelines)

        reply?.sendAndClose([
            "ok": true,
            "run_id": run.id.uuidString,
            "status": run.status.rawValue,
            "status_detail": run.statusDetail ?? ""
        ])
        return .send(.persistState)
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
            guard let nodeID, let nodeRun = run.nodeRuns.first(where: { $0.nodeID == nodeID }) else {
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
                state: &state.pipelines
            )
            switch result {
            case .runNotFound, .nodeRunNotFound:
                return fail("internal error resolving pipeline node run")
            case .applied(let run), .recorded(let run), .idempotent(let run):
                let nodeRun = run.nodeRuns[id: targetNodeRunID]
                reply?.sendAndClose([
                    "ok": true,
                    "run_id": run.id.uuidString,
                    "node_run_id": targetNodeRunID.uuidString,
                    "node_id": nodeRun?.nodeID ?? "",
                    "node_status": nodeRun?.status.rawValue ?? "",
                    "run_status": run.status.rawValue
                ])
                return .send(.persistState)
            }
        }
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

    private static func runJSON(_ run: PipelineRun) -> [String: Any] {
        var dict: [String: Any] = [
            "id": run.id.uuidString,
            "definition_id": run.definitionID,
            "status": run.status.rawValue,
            "location": run.location.rawValue,
            "run_dir": run.runDir,
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
                return nrDict
            }
        ]
        if let statusDetail = run.statusDetail {
            dict["status_detail"] = statusDetail
        }
        if let workspaceID = run.workspaceID {
            dict["workspace_id"] = workspaceID.uuidString
        }
        return dict
    }
}
