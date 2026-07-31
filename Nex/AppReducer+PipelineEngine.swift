import ComposableArchitecture
import Foundation

// MARK: - Cancellable timer identities

private struct PipelineReadinessTimeoutID: Hashable {
    var nodeRunID: UUID
}

private struct PipelineStopGraceTimeoutID: Hashable {
    var nodeRunID: UUID
}

private enum PipelineTiming {
    static let readinessTimeout: Duration = .seconds(30)
    static let stopGraceTimeout: Duration = .seconds(120)
    static let surfacePollInterval: Duration = .milliseconds(300)
    /// ~10s budget at `surfacePollInterval` spacing, expressed as an
    /// iteration count (not wall-clock `ContinuousClock.now` math) so the
    /// whole wait routes through the injected `clock` dependency and
    /// resolves instantly under `ImmediateClock`/`TestClock` in tests.
    static let surfacePollMaxIterations = 34
    static let spawnGrace: Duration = .seconds(2)
}

/// Live execution engine (issue #282 phase 6): turns the pure routing
/// decisions in `PipelinesFeature.applyHandoff` into real panes. Every
/// function here takes `AppReducer.State` directly (not
/// `PipelinesFeature.State`) because spawning/typing/resuming needs
/// `state.workspaces` + `surfaceManager` — the same reason
/// `handlePipelineRun`/`handlePipelineHandoff` in
/// `AppReducer+PipelineSocket.swift` already mutate `inout State`
/// directly instead of round-tripping through a dispatched action.
extension AppReducer {
    // MARK: - Delegate re-entry (the only truly async round-trips)

    func handlePipelineDelegate(_ state: inout State, _ action: PipelinesFeature.Action.Delegate) -> Effect<Action> {
        switch action {
        case .nodeCommandTyped(let runID, let nodeRunID, let paneID, let command, let isResume):
            return .run { send in
                try? await clock.sleep(for: PipelineTiming.readinessTimeout)
                await send(.pipelines(.delegate(.readinessTimedOut(
                    runID: runID, nodeRunID: nodeRunID, paneID: paneID,
                    command: command, isResume: isResume, isRetry: false
                ))))
            }
            .cancellable(id: PipelineReadinessTimeoutID(nodeRunID: nodeRunID))

        case .readinessTimedOut(let runID, let nodeRunID, let paneID, let command, let isResume, let isRetry):
            guard let run = state.pipelines.runs[id: runID], let nodeRun = run.nodeRuns[id: nodeRunID],
                  nodeRun.status == .spawning else {
                // Already progressed (SessionStart arrived and cancelled
                // this timer) — a stale retry racing the cancellation.
                return .none
            }
            if isRetry {
                return pipelineFailNodeSynthetically(
                    &state, runID: runID, nodeRunID: nodeRunID,
                    reason: "node \"\(nodeRun.nodeID)\" never started — no SessionStart within 30s after a retry"
                )
            }
            // One retry: retype the same command (mirrors the restart
            // path's precedent of a shell-readiness grace) and re-arm.
            let mgr = surfaceManager
            return .run { send in
                await mgr.sendCommand(to: paneID, command: command)
                await send(.pipelines(.delegate(.nodeCommandTyped(
                    runID: runID, nodeRunID: nodeRunID, paneID: paneID, command: command, isResume: isResume
                ))))
                try? await clock.sleep(for: PipelineTiming.readinessTimeout)
                await send(.pipelines(.delegate(.readinessTimedOut(
                    runID: runID, nodeRunID: nodeRunID, paneID: paneID,
                    command: command, isResume: isResume, isRetry: true
                ))))
            }
            .cancellable(id: PipelineReadinessTimeoutID(nodeRunID: nodeRunID))

        case .spawnFailed(let runID, let nodeRunID, let reason):
            return pipelineFailNodeSynthetically(&state, runID: runID, nodeRunID: nodeRunID, reason: reason)

        case .stopGraceElapsed(let runID, let nodeRunID):
            guard let run = state.pipelines.runs[id: runID], let nodeRun = run.nodeRuns[id: nodeRunID],
                  !nodeRun.status.isTerminal, nodeRun.status != .stalled else {
                return .none
            }
            PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
                $0.status = .stalled
            }
            PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
                $0.status = .paused
                $0.statusDetail = PipelineRunPauseReason.detail(
                    .stalledNode,
                    "node \"\(nodeRun.nodeID)\" stalled — no handoff 120s after Stop"
                )
            }
            return .send(.persistState)

        case .beginEntryNode(let runID):
            return pipelineBeginEntryNode(&state, runID: runID)

        case .locationProvisionFailed(let runID, let reason):
            PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
                $0.status = .failed
                $0.statusDetail = "location provisioning failed: \(reason)"
                $0.completedAt = Date()
            }
            return pipelineFanOutWatch(&state, runID: runID)
        }
    }

    // MARK: - Run launch

    /// Entry point for a validated `pipeline run` (called from
    /// `handlePipelineRun`). `location: current` already has a
    /// `workspaceID` resolved synchronously; `workspace`/`worktree` mint
    /// one up front and provision it asynchronously before the entry node
    /// can spawn.
    func pipelineLaunchRun(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID] else { return .none }
        if run.workspaceID != nil {
            return pipelineBeginEntryNode(&state, runID: runID)
        }
        return pipelineProvisionLocation(&state, runID: runID)
    }

    /// `location: workspace` mints + creates a dedicated workspace;
    /// `location: worktree` additionally runs `git worktree add` first,
    /// reusing the exact flow `handleSocketWorkspaceCreate` uses for
    /// `workspace create --worktree` (issue #222).
    private func pipelineProvisionLocation(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID] else { return .none }
        let newWorkspaceID = uuid()
        let workspaceName = "Pipeline: \(run.definitionSnapshot.name)"
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
            $0.workspaceID = newWorkspaceID
        }

        switch run.location {
        case .current:
            // Unreachable in practice (handlePipelineRun already resolves
            // `.current` before creating the run) — treat as a same-tick
            // no-op fallback.
            return pipelineBeginEntryNode(&state, runID: runID)

        case .workspace:
            return .concatenate(
                .send(.createWorkspace(name: workspaceName, id: newWorkspaceID)),
                .send(.pipelines(.delegate(.beginEntryNode(runID: runID))))
            )

        case .worktree:
            guard let repoPath = run.definitionSnapshot.nodes.first?.workingDir ?? state.workspaces[id: state.activeWorkspaceID ?? UUID()]?.panes.first?.workingDirectory else {
                return .send(.pipelines(.delegate(.locationProvisionFailed(
                    runID: runID, reason: "no source repo could be resolved for a worktree run"
                ))))
            }
            guard let folderName = WorkspaceFeature.State.sanitizedGitName(from: run.definitionSnapshot.id) else {
                return .send(.pipelines(.delegate(.locationProvisionFailed(
                    runID: runID, reason: "pipeline id \"\(run.definitionSnapshot.id)\" isn't a usable worktree name"
                ))))
            }
            let branch = "pipeline-\(folderName)-\(runID.uuidString.prefix(8))"
            let basePath = state.settings.resolvedWorktreeBasePath(forRepoPath: repoPath)
            let worktreePath = "\(basePath)/\(folderName)-\(runID.uuidString.prefix(8))"
            let sourceRepo: Repo = state.repoRegistry.first(where: {
                ($0.path as NSString).standardizingPath == (repoPath as NSString).standardizingPath
            }) ?? Repo(id: uuid(), path: repoPath, name: (repoPath as NSString).lastPathComponent)
            let gitSvc = gitService
            return .run { send in
                do {
                    try await performWorktreeAdd(
                        gitService: gitSvc, repoPath: repoPath, worktreePath: worktreePath,
                        branch: branch, updateMain: false
                    )
                    await send(.createWorkspace(
                        name: workspaceName, repos: [sourceRepo], id: newWorkspaceID,
                        worktree: WorktreeSeed(path: worktreePath, branchName: branch)
                    ))
                    await send(.pipelines(.delegate(.beginEntryNode(runID: runID))))
                } catch {
                    await send(.pipelines(.delegate(.locationProvisionFailed(
                        runID: runID, reason: worktreeErrorMessage(error)
                    ))))
                }
            }
        }
    }

    private func pipelineBeginEntryNode(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID] else { return .none }
        let newID = uuid()
        guard let nodeRunID = PipelinesFeature.appendNodeRun(
            runID: runID, nodeID: run.definitionSnapshot.entry, newID: newID, now: Date(), state: &state.pipelines
        ) else { return .none }
        return .merge(
            .send(.persistState),
            pipelineEngageNode(&state, runID: runID, nodeRunID: nodeRunID, feedback: nil)
        )
    }

    // MARK: - Node engagement (fresh spawn vs bounce-back reuse)

    /// Decides how to bring `nodeRunID` (already appended, `.spawning`,
    /// with no `paneID` yet) to life: this is where the bounce-back rule
    /// from issue section 3 is applied. A node is a "bounce" when this
    /// run has a PRIOR `PipelineNodeRun` for the same node id with a
    /// bound pane — sequential progression to a never-visited node is
    /// always a fresh spawn.
    func pipelineEngageNode(_ state: inout State, runID: UUID, nodeRunID: UUID, feedback: PipelineFeedback?) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID],
              let nodeRun = run.nodeRuns[id: nodeRunID],
              let node = run.definitionSnapshot.nodes.first(where: { $0.id == nodeRun.nodeID })
        else { return .none }

        let priorAttempt = run.nodeRuns
            .filter { $0.nodeID == nodeRun.nodeID && $0.id != nodeRunID && $0.paneID != nil }
            .sorted { $0.attempt > $1.attempt }
            .first

        guard let priorAttempt, let priorPaneID = priorAttempt.paneID else {
            return pipelineSpawnFresh(&state, runID: runID, nodeRunID: nodeRunID, feedback: feedback)
        }

        // Bounce-back: reuse the prior attempt's pane. "Session still
        // live" is read straight off the pane's own `agentSessionID` —
        // `WorkspaceFeature`'s existing SessionEnd match-guard (issue
        // #178) already keeps that field nil'd out only once a session
        // has genuinely exited, dual-fire-safe. No separate liveness
        // bookkeeping needed here.
        guard let workspaceID = run.workspaceID,
              let pane = state.workspaces[id: workspaceID]?.panes[id: priorPaneID] else {
            return pipelineSpawnFresh(&state, runID: runID, nodeRunID: nodeRunID, feedback: feedback)
        }
        PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
            $0.paneID = priorPaneID
        }
        if let liveSessionID = pane.agentSessionID, liveSessionID == priorAttempt.agentSessionID {
            return pipelineBounceLiveSession(
                &state, runID: runID, nodeRunID: nodeRunID, paneID: priorPaneID,
                node: node, feedback: feedback
            )
        }
        if let lastKnownSessionID = priorAttempt.agentSessionID {
            return pipelineBounceResume(
                &state, runID: runID, nodeRunID: nodeRunID, paneID: priorPaneID,
                node: node, sessionID: lastKnownSessionID, feedback: feedback
            )
        }
        // Neither a live session nor a known id to resume — fresh spawn
        // in a NEW pane (the old one is abandoned but left open for
        // inspection, matching "panes are never auto-closed in v1").
        return pipelineSpawnFresh(&state, runID: runID, nodeRunID: nodeRunID, feedback: feedback)
    }

    /// Fresh spawn: mint a pane (split off the target workspace's
    /// focused/first pane, or lay out the first pane of an empty
    /// workspace), then type the full launch command once the surface
    /// exists.
    private func pipelineSpawnFresh(_ state: inout State, runID: UUID, nodeRunID: UUID, feedback: PipelineFeedback?) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID],
              let nodeRun = run.nodeRuns[id: nodeRunID],
              let node = run.definitionSnapshot.nodes.first(where: { $0.id == nodeRun.nodeID }),
              let workspaceID = run.workspaceID,
              let workspace = state.workspaces[id: workspaceID]
        else {
            return pipelineFailNodeSynthetically(
                &state, runID: runID, nodeRunID: nodeRunID, reason: "no resolvable workspace to spawn into"
            )
        }

        guard let promptPath = pipelineWritePrompt(
            state: state, run: run, node: node, attempt: nodeRun.attempt, feedback: feedback
        ) else {
            return pipelineFailNodeSynthetically(&state, runID: runID, nodeRunID: nodeRunID, reason: prepErrorFallback)
        }

        switch pipelineEngine.composeLaunchCommand(node, run.id.uuidString, nodeRun.attempt, run.runDir, promptPath) {
        case .failure(let error):
            return pipelineFailNodeSynthetically(
                &state, runID: runID, nodeRunID: nodeRunID, reason: "unsafe launch parameters: \(pipelineLaunchErrorMessage(error))"
            )
        case .success(let command):
            let newPaneID = uuid()
            let label = "pipe:\(node.id):\(run.id.uuidString.prefix(8))"
            PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
                $0.paneID = newPaneID
            }
            let spawnAction: Effect<Action>
            if let sourceID = workspace.focusedPaneID ?? workspace.panes.first?.id {
                state.workspaces[id: workspaceID]?.setFocus(sourceID)
                spawnAction = .send(.workspaces(.element(
                    id: workspaceID,
                    action: .splitPane(direction: .horizontal, sourcePaneID: sourceID, label: label, newPaneID: newPaneID)
                )))
            } else {
                spawnAction = .send(.workspaces(.element(
                    id: workspaceID,
                    action: .createPane(newPaneID: newPaneID, label: label, workingDirectory: node.workingDir)
                )))
            }
            let pointerMessage = node.mode == .interactive ? pipelineMissionPointer(promptPath: promptPath) : nil
            if let pointerMessage {
                state.pipelinePendingPointerMessages[nodeRunID] = pointerMessage
            }
            return .concatenate(
                .send(.persistState),
                spawnAction,
                pipelineTypeCommandAfterSurfaceReady(
                    runID: runID, nodeRunID: nodeRunID, paneID: newPaneID, command: command, isResume: false
                )
            )
        }
    }

    /// Bounce-back with a live interactive session: no relaunch at all —
    /// just a file-pointer follow-up message into the pane that's
    /// already sitting at a claude prompt.
    private func pipelineBounceLiveSession(
        _ state: inout State, runID: UUID, nodeRunID: UUID, paneID: UUID,
        node: PipelineNode, feedback: PipelineFeedback?
    ) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID],
              let nodeRun = run.nodeRuns[id: nodeRunID]
        else {
            return pipelineFailNodeSynthetically(&state, runID: runID, nodeRunID: nodeRunID, reason: prepErrorFallback)
        }
        guard let promptPath = pipelineWritePrompt(
            state: state, run: run, node: node, attempt: nodeRun.attempt, feedback: feedback
        ) else {
            return pipelineFailNodeSynthetically(&state, runID: runID, nodeRunID: nodeRunID, reason: prepErrorFallback)
        }
        let liveSessionID = state.workspaces[id: run.workspaceID ?? UUID()]?.panes[id: paneID]?.agentSessionID
        PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
            $0.status = .running
            $0.agentSessionID = liveSessionID
        }
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) { $0.status = .running }
        return .merge(
            .send(.persistState),
            paneSendText(paneID: paneID, text: pipelineMissionPointer(promptPath: promptPath), bare: false)
        )
    }

    /// Bounce-back with an exited-but-known session: type
    /// `claude --resume <id>` into the same pane, then (like a fresh
    /// interactive spawn) wait for SessionStart before sending the
    /// pointer message — resuming always re-enters the TUI regardless of
    /// the node's declared `mode`.
    private func pipelineBounceResume(
        _ state: inout State, runID: UUID, nodeRunID: UUID, paneID: UUID,
        node: PipelineNode, sessionID: String, feedback: PipelineFeedback?
    ) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID],
              let nodeRun = run.nodeRuns[id: nodeRunID]
        else {
            return pipelineFailNodeSynthetically(&state, runID: runID, nodeRunID: nodeRunID, reason: prepErrorFallback)
        }
        guard let promptPath = pipelineWritePrompt(
            state: state, run: run, node: node, attempt: nodeRun.attempt, feedback: feedback
        ) else {
            return pipelineFailNodeSynthetically(&state, runID: runID, nodeRunID: nodeRunID, reason: prepErrorFallback)
        }
        switch pipelineEngine.composeResumeCommand(node, run.id.uuidString, nodeRun.attempt, sessionID) {
        case .failure(let error):
            return pipelineFailNodeSynthetically(
                &state, runID: runID, nodeRunID: nodeRunID, reason: "unsafe resume parameters: \(pipelineLaunchErrorMessage(error))"
            )
        case .success(let command):
            state.pipelinePendingPointerMessages[nodeRunID] = pipelineMissionPointer(promptPath: promptPath)
            return .merge(
                .send(.persistState),
                pipelineTypeCommandAfterSurfaceReady(
                    runID: runID, nodeRunID: nodeRunID, paneID: paneID, command: command, isResume: true
                )
            )
        }
    }

    private var prepErrorFallback: String { "failed to prepare node attempt directory" }

    /// Polls for the pane's surface to exist (a split/create effect just
    /// dispatched is async), waits the shell-readiness grace, types the
    /// command, then hands off to the SessionStart readiness gate via
    /// `.nodeCommandTyped`.
    private func pipelineTypeCommandAfterSurfaceReady(
        runID: UUID, nodeRunID: UUID, paneID: UUID, command: String, isResume: Bool
    ) -> Effect<Action> {
        let mgr = surfaceManager
        // Every wait goes through the injected `clock` (never raw
        // `Task.sleep`) so `ImmediateClock`/`TestClock` govern this like
        // every other timed effect in the codebase — a poll budget
        // counted in iterations rather than wall-clock `ContinuousClock.now`.
        let maxIterations = PipelineTiming.surfacePollMaxIterations
        return .run { send in
            var iterations = 0
            while await mgr.surface(for: paneID) == nil {
                if iterations >= maxIterations {
                    await send(.pipelines(.delegate(.spawnFailed(
                        runID: runID, nodeRunID: nodeRunID, reason: "pane surface never came up"
                    ))))
                    return
                }
                iterations += 1
                try? await clock.sleep(for: PipelineTiming.surfacePollInterval)
            }
            try? await clock.sleep(for: PipelineTiming.spawnGrace)
            await mgr.sendCommand(to: paneID, command: command)
            await send(.pipelines(.delegate(.nodeCommandTyped(
                runID: runID, nodeRunID: nodeRunID, paneID: paneID, command: command, isResume: isResume
            ))))
        }
    }

    // MARK: - Prompt rendering + file work

    private func pipelineWritePrompt(
        state: State, run: PipelineRun, node: PipelineNode, attempt: Int, feedback: PipelineFeedback?
    ) -> String? {
        let context = pipelineTemplateContext(run: run, feedback: feedback)
        let rendered = pipelineEngine.renderPrompt(node, context)
        do {
            let attemptDir = try pipelineEngine.prepareAttemptDir(run.runDir, node.id, attempt)
            return try pipelineEngine.writePrompt(attemptDir, rendered.text)
        } catch {
            return nil
        }
    }

    private func pipelineTemplateContext(run: PipelineRun, feedback: PipelineFeedback?) -> PipelineTemplateContext {
        var artifacts: [String: PipelineNodeArtifact] = [:]
        for nodeID in Set(run.nodeRuns.map(\.nodeID)) {
            let completedAttempts = run.nodeRuns.filter {
                $0.nodeID == nodeID && ($0.status == .done || $0.status == .partial)
            }
            guard let latest = completedAttempts.max(by: { $0.attempt < $1.attempt }) else { continue }
            let path = latest.outputPath ?? PipelineEngineLogic.attemptDirPath(
                runDir: run.runDir, nodeID: nodeID, attempt: latest.attempt
            ).appending("/output.md")
            artifacts[nodeID] = PipelineNodeArtifact(outputPath: path, summary: latest.summary ?? "")
        }
        return PipelineTemplateContext(
            inputs: run.inputs, nodeArtifacts: artifacts, runID: run.id.uuidString, runDir: run.runDir, feedback: feedback
        )
    }

    private func pipelineMissionPointer(promptPath: String) -> String {
        "Read and execute the mission in \(promptPath)."
    }

    private func pipelineLaunchErrorMessage(_ error: PipelineLaunchError) -> String {
        switch error {
        case .unsafeModel(let model): "model \"\(model)\" contains unsafe characters"
        case .unsafeEnvValue(let key): "env value for \"\(key)\" is unsafe (control characters or invalid session id)"
        }
    }

    // MARK: - Synthetic failure (spawn/readiness exhaustion routes like `fail`)

    /// A node that never got a chance to hand off (spawn failure,
    /// readiness-gate exhaustion) is routed exactly like an explicit
    /// `nex pipeline fail` — same `applyHandoff` call, same follow-up.
    func pipelineFailNodeSynthetically(_ state: inout State, runID: UUID, nodeRunID: UUID, reason: String) -> Effect<Action> {
        let result = PipelinesFeature.applyHandoff(
            runID: runID, nodeRunID: nodeRunID, outcome: .fail, summary: reason, outputPath: nil,
            engine: pipelineEngine, newNodeRunID: { self.uuid() }, state: &state.pipelines
        )
        return pipelineFollowUpOnHandoff(&state, result: result)
    }

    /// Shared follow-up after any `applyHandoff` call (real or
    /// synthetic): engages every freshly spawned NodeRun (fan-out, issue
    /// #282 round 3, can be more than one from a single handoff);
    /// cancels timers for any sibling branch a whole-run failure just
    /// marked `.interrupted`; always fans out `pipeline watch`.
    func pipelineFollowUpOnHandoff(_ state: inout State, result: PipelinesFeature.HandoffResult) -> Effect<Action> {
        switch result {
        case .runNotFound, .nodeRunNotFound, .idempotent:
            return .none
        case .recorded(let run):
            return .merge(.send(.persistState), pipelineFanOutWatch(&state, runID: run.id))
        case .applied(let run, let spawnNodeRunIDs):
            var effects: [Effect<Action>] = [.send(.persistState), pipelineFanOutWatch(&state, runID: run.id)]
            if run.status == .failed {
                for nodeRun in run.nodeRuns where nodeRun.status == .interrupted {
                    effects.append(pipelineCancelTimers(nodeRunID: nodeRun.id))
                }
            }
            for spawnNodeRunID in spawnNodeRunIDs {
                effects.append(pipelineEngageNode(
                    &state, runID: run.id, nodeRunID: spawnNodeRunID,
                    feedback: pipelineFeedback(run: run, nodeRunID: spawnNodeRunID)
                ))
            }
            return .merge(effects)
        }
    }

    /// The feedback surfaced to a node via `{{feedback}}`: the summary +
    /// artifact of the SPECIFIC NodeRun whose handoff routed here
    /// (`PipelineNodeRun.feedbackSourceNodeRunID`, set when the NodeRun
    /// was appended) — not "whichever else in the run most recently
    /// finished", which would be ambiguous once concurrent fan-out
    /// branches exist (issue #282 round 3). Nil on a node's first-ever
    /// visit in this run.
    private func pipelineFeedback(run: PipelineRun, nodeRunID: UUID) -> PipelineFeedback? {
        guard let nodeRun = run.nodeRuns[id: nodeRunID], let sourceID = nodeRun.feedbackSourceNodeRunID,
              let source = run.nodeRuns[id: sourceID]
        else { return nil }
        let path = source.outputPath ?? PipelineEngineLogic.attemptDirPath(
            runDir: run.runDir, nodeID: source.nodeID, attempt: source.attempt
        ).appending("/output.md")
        return PipelineFeedback(summary: source.summary ?? "", artifactPath: path)
    }

    // MARK: - Manual controls (CLI `pipeline approve|deny|cancel|retry|resume`)

    /// Resolves which pending approval an `approve`/`deny` call targets:
    /// the explicit `--edge <key>` match if given, else the sole pending
    /// approval when unambiguous. Nil (including "more than one pending
    /// and no edge given") is the caller's cue to reject with a
    /// structured "ambiguous, pass --edge" error — see
    /// `AppReducer+PipelineSocket.swift`'s `handlePipelineApprove`/`Deny`.
    static func resolvePendingApproval(_ pending: [PipelinePendingApproval], edgeKey: String?) -> PipelinePendingApproval? {
        if let edgeKey {
            return pending.first { $0.edgeKey == edgeKey }
        }
        return pending.count == 1 ? pending.first : nil
    }

    func pipelineApprove(_ state: inout State, runID: UUID, edgeKey: String? = nil) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID], run.status == .awaitingApproval else { return .none }
        let pending = PipelinePendingApproval.parseAll(run.statusDetail)
        guard let target = Self.resolvePendingApproval(pending, edgeKey: edgeKey) else { return .none }
        let remaining = pending.filter { $0.edgeKey != target.edgeKey }
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
            $0.statusDetail = PipelinePendingApproval.encodeAll(remaining)
            $0.status = remaining.isEmpty ? .running : .awaitingApproval
        }
        let newID = uuid()
        guard let newNodeRunID = PipelinesFeature.appendNodeRun(
            runID: runID, nodeID: target.toNodeID, newID: newID,
            feedbackSourceNodeRunID: target.fromNodeRunID, now: Date(), state: &state.pipelines
        ), let updatedRun = state.pipelines.runs[id: runID] else { return .none }
        let feedback = pipelineFeedback(run: updatedRun, nodeRunID: newNodeRunID)
        return .merge(
            .send(.persistState),
            pipelineEngageNode(&state, runID: runID, nodeRunID: newNodeRunID, feedback: feedback)
        )
    }

    /// Denying one gated branch doesn't necessarily kill the whole run —
    /// with fan-out, sibling branches may still be active or may already
    /// have succeeded. The run only becomes `.cancelled` (legacy
    /// single-branch behaviour) when this was the last thing keeping it
    /// alive and nothing ever reached `.done`; if a sibling already
    /// succeeded, denying a late bounce-back approval completes the run
    /// instead of retroactively undoing that success.
    func pipelineDeny(_ state: inout State, runID: UUID, edgeKey: String? = nil) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID], run.status == .awaitingApproval else { return .none }
        let pending = PipelinePendingApproval.parseAll(run.statusDetail)
        guard let target = Self.resolvePendingApproval(pending, edgeKey: edgeKey) else { return .none }
        let remaining = pending.filter { $0.edgeKey != target.edgeKey }
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
            $0.statusDetail = PipelinePendingApproval.encodeAll(remaining)
        }
        guard let updatedRun = state.pipelines.runs[id: runID] else { return .none }
        if !remaining.isEmpty {
            PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) { $0.status = .awaitingApproval }
        } else if updatedRun.activeNodeRunIDs.isEmpty {
            let reachedDone = updatedRun.nodeRuns.contains { $0.status == .done }
            PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
                $0.status = reachedDone ? .completed : .cancelled
                $0.statusDetail = reachedDone ? nil : "approval denied"
                $0.completedAt = Date()
            }
        } else {
            PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) { $0.status = .running }
        }
        return .merge(.send(.persistState), pipelineFanOutWatch(&state, runID: runID))
    }

    func pipelineCancel(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID], !run.status.isTerminal else { return .none }
        let timerCancels = Set(run.activeNodeRunIDs + run.blockingNodeRunIDs).map(pipelineCancelTimers)
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
            $0.status = .cancelled
            $0.statusDetail = "cancelled by user"
            $0.completedAt = Date()
        }
        return .merge([.send(.persistState), pipelineFanOutWatch(&state, runID: runID)] + timerCancels)
    }

    /// `nex pipeline resume` — the appRestart-specific re-entry:
    /// re-engages every blocked NodeRun (fan-out can leave more than one
    /// `.interrupted`/`.stalled` at once), each message framing the
    /// re-verify instruction the issue calls for (issue section 5).
    func pipelineResume(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID], run.status == .paused,
              let reason = PipelineRunPauseReason.parse(run.statusDetail)
        else { return .none }
        let blocking = run.blockingNodeRunIDs
        guard !blocking.isEmpty else { return .none }
        let message: String = switch reason {
        case .appRestart:
            "You were interrupted by an app restart before finishing. Check the run directory for " +
                "any work you already completed, then hand off accordingly (done/fail/partial)."
        case .stalledNode:
            "No handoff was received from your previous turn. If you already finished, hand off now; " +
                "otherwise continue and hand off when done."
        case .paneClosed:
            "Your pane was closed and a new one was opened to continue this node. Continue the " +
                "mission and hand off when done."
        }
        var effects: [Effect<Action>] = []
        for nodeRunID in blocking {
            effects.append(pipelineReengageNode(&state, runID: runID, nodeRunID: nodeRunID, feedbackMessage: message))
        }
        return .merge(effects)
    }

    /// `nex pipeline retry` — generic manual escalation for a stalled /
    /// pane-closed / failed run: force the run back to `.running` and
    /// start a fresh attempt of every node it stopped on — every
    /// currently blocking (stalled/interrupted) NodeRun, plus, if the run
    /// itself is `.failed`, each node's latest attempt that actually
    /// failed (fan-out can leave more than one of either).
    func pipelineRetry(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID] else { return .none }
        var targets = Set(run.blockingNodeRunIDs)
        if run.status == .failed {
            let latestByNode = Dictionary(grouping: run.nodeRuns, by: \.nodeID)
                .compactMapValues { $0.max { $0.attempt < $1.attempt } }
            for nodeRun in latestByNode.values where nodeRun.status == .failed {
                targets.insert(nodeRun.id)
            }
        }
        guard !targets.isEmpty else { return .none }
        var effects: [Effect<Action>] = []
        for nodeRunID in targets {
            effects.append(pipelineReengageNode(
                &state, runID: runID, nodeRunID: nodeRunID,
                feedbackMessage: "Retrying at operator request. Continue the mission and hand off when done."
            ))
        }
        return .merge(effects)
    }

    private func pipelineReengageNode(_ state: inout State, runID: UUID, nodeRunID: UUID, feedbackMessage: String) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID], let current = run.nodeRuns[id: nodeRunID] else { return .none }
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
            $0.status = .running
            $0.statusDetail = nil
            $0.completedAt = nil
        }
        let newID = uuid()
        guard let newNodeRunID = PipelinesFeature.appendNodeRun(
            runID: runID, nodeID: current.nodeID, newID: newID, now: Date(), state: &state.pipelines
        ) else { return .none }
        let artifactPath = current.outputPath ?? PipelineEngineLogic.attemptDirPath(
            runDir: run.runDir, nodeID: current.nodeID, attempt: current.attempt
        ).appending("/output.md")
        let feedback = PipelineFeedback(summary: feedbackMessage, artifactPath: artifactPath)
        return .merge(
            .send(.persistState),
            pipelineEngageNode(&state, runID: runID, nodeRunID: newNodeRunID, feedback: feedback)
        )
    }

    func pipelineCancelTimers(nodeRunID: UUID) -> Effect<Action> {
        .merge(
            .cancel(id: PipelineReadinessTimeoutID(nodeRunID: nodeRunID)),
            .cancel(id: PipelineStopGraceTimeoutID(nodeRunID: nodeRunID))
        )
    }

    // MARK: - Agent-event forwarding (issue section 3 liveness rules)

    /// Finds the NodeRun bound to `paneID` whose status matches one of
    /// `statuses` — there is at most one live NodeRun per PANE at a time
    /// (each fan-out branch gets its own pane, issue #282 round 3), even
    /// though a run as a whole can have several concurrently-active
    /// NodeRuns across different panes.
    private func pipelineActiveNodeRun(
        _ state: State, paneID: UUID, statuses: Set<PipelineNodeRunStatus>
    ) -> (runID: UUID, nodeRunID: UUID)? {
        for run in state.pipelines.runs {
            if let nodeRun = run.nodeRuns.first(where: { $0.paneID == paneID && statuses.contains($0.status) }) {
                return (run.id, nodeRun.id)
            }
        }
        return nil
    }

    /// A new turn started — clears `.awaitingHuman` (the agent is working
    /// again, whatever prompted the notification was resolved).
    func pipelineHandleAgentStarted(_ state: inout State, paneID: UUID) -> Effect<Action> {
        guard let (runID, nodeRunID) = pipelineActiveNodeRun(state, paneID: paneID, statuses: [.awaitingHuman]) else {
            return .none
        }
        PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
            $0.status = .running
        }
        return .none
    }

    /// The Stop-hook fallback (issue section 3): a Stop with zero
    /// background tasks arms a 120s grace timer; background work still in
    /// flight (or the node isn't `.running`) cancels/skips it.
    func pipelineHandleStop(_ state: inout State, paneID: UUID, backgroundTaskCount: Int) -> Effect<Action> {
        guard let (runID, nodeRunID) = pipelineActiveNodeRun(state, paneID: paneID, statuses: [.running, .awaitingHuman])
        else { return .none }
        if backgroundTaskCount > 0 {
            return .cancel(id: PipelineStopGraceTimeoutID(nodeRunID: nodeRunID))
        }
        return .run { send in
            try? await clock.sleep(for: PipelineTiming.stopGraceTimeout)
            await send(.pipelines(.delegate(.stopGraceElapsed(runID: runID, nodeRunID: nodeRunID))))
        }
        .cancellable(id: PipelineStopGraceTimeoutID(nodeRunID: nodeRunID), cancelInFlight: true)
    }

    /// A Notification (permission prompt) suspends the stall timer and
    /// flags the node `.awaitingHuman` — distinct from a bare Stop, which
    /// might just mean "forgot to call done" (issue section 3).
    func pipelineHandleNotification(_ state: inout State, paneID: UUID) -> Effect<Action> {
        guard let (runID, nodeRunID) = pipelineActiveNodeRun(state, paneID: paneID, statuses: [.running])
        else { return .none }
        PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
            $0.status = .awaitingHuman
        }
        return .cancel(id: PipelineStopGraceTimeoutID(nodeRunID: nodeRunID))
    }

    /// SessionStart serves two purposes: (1) the readiness-gate
    /// confirmation for a `.spawning` node — cancel the timeout, deliver
    /// any queued pointer message, flip to `.running`; (2) a rebind for
    /// an already-active or `.stalled` node (compaction, or a late
    /// SessionStart racing this node's own SessionEnd in either order) —
    /// always update `agentSessionID`, and clear a stall if present.
    func pipelineHandleSessionStarted(_ state: inout State, paneID: UUID, sessionID: String) -> Effect<Action> {
        guard let (runID, nodeRunID) = pipelineActiveNodeRun(
            state, paneID: paneID, statuses: [.spawning, .running, .awaitingHuman, .stalled]
        ) else { return .none }
        guard let run = state.pipelines.runs[id: runID], let nodeRun = run.nodeRuns[id: nodeRunID] else { return .none }
        let wasSpawning = nodeRun.status == .spawning
        let wasStalled = nodeRun.status == .stalled

        PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
            $0.agentSessionID = sessionID
            if wasSpawning || wasStalled { $0.status = .running }
        }

        var effects: [Effect<Action>] = []
        if wasSpawning {
            effects.append(.cancel(id: PipelineReadinessTimeoutID(nodeRunID: nodeRunID)))
            if let pointer = state.pipelinePendingPointerMessages.removeValue(forKey: nodeRunID) {
                effects.append(paneSendText(paneID: paneID, text: pointer, bare: false))
            }
        }
        // Only lift the run-level pause once EVERY blocking branch has
        // cleared — fan-out can leave more than one node `.stalled` under
        // the same pause, and a late SessionStart for one of them
        // shouldn't resume routing while a sibling is still stuck.
        if wasStalled, run.status == .paused, PipelineRunPauseReason.parse(run.statusDetail) == .stalledNode,
           (state.pipelines.runs[id: runID]?.blockingNodeRunIDs ?? []).isEmpty {
            PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
                $0.status = .running
                $0.statusDetail = nil
            }
        }
        effects.append(.send(.persistState))
        effects.append(pipelineFanOutWatch(&state, runID: runID))
        return .merge(effects)
    }

    /// A genuine session exit with no handoff recorded stalls the node —
    /// the `agentSessionID` match-guard (mirroring `WorkspaceFeature`'s
    /// own SessionEnd handling, issue #178) makes this safe regardless of
    /// whether SessionEnd(old) or SessionStart(new) arrives first on a
    /// compaction/resume dual-fire: only an end matching the id we're
    /// STILL tracking counts as a real exit.
    func pipelineHandleSessionEnded(_ state: inout State, paneID: UUID, sessionID: String) -> Effect<Action> {
        guard let (runID, nodeRunID) = pipelineActiveNodeRun(state, paneID: paneID, statuses: [.running, .awaitingHuman]),
              let run = state.pipelines.runs[id: runID], let nodeRun = run.nodeRuns[id: nodeRunID],
              nodeRun.agentSessionID == sessionID
        else { return .none }
        PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
            $0.status = .stalled
        }
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
            $0.status = .paused
            $0.statusDetail = PipelineRunPauseReason.detail(
                .stalledNode, "node \"\(nodeRun.nodeID)\" session ended with no handoff"
            )
        }
        return .merge(
            .cancel(id: PipelineStopGraceTimeoutID(nodeRunID: nodeRunID)),
            .send(.persistState),
            pipelineFanOutWatch(&state, runID: runID)
        )
    }

    /// The user closed a node's pane mid-run — ambiguous intent, never
    /// auto-route (issue section 3).
    func pipelineHandlePaneClosed(_ state: inout State, paneID: UUID) -> Effect<Action> {
        guard let (runID, nodeRunID) = pipelineActiveNodeRun(
            state, paneID: paneID, statuses: [.spawning, .running, .awaitingHuman, .stalled]
        ) else { return .none }
        guard let nodeID = state.pipelines.runs[id: runID]?.nodeRuns[id: nodeRunID]?.nodeID else { return .none }
        PipelinesFeature.updateNodeRun(runID: runID, nodeRunID: nodeRunID, state: &state.pipelines) {
            $0.status = .interrupted
        }
        PipelinesFeature.updateRun(runID: runID, state: &state.pipelines) {
            $0.status = .paused
            $0.statusDetail = PipelineRunPauseReason.detail(.paneClosed, "node \"\(nodeID)\" pane was closed")
        }
        return .merge(
            pipelineCancelTimers(nodeRunID: nodeRunID),
            .send(.persistState),
            pipelineFanOutWatch(&state, runID: runID)
        )
    }

    /// A deleted workspace cancels its active runs (issue section 3) —
    /// history survives, since `PipelineRun.workspaceID` carries no FK.
    func cancelPipelineRuns(_ state: inout State, workspaceID: UUID, reason: String) -> Effect<Action> {
        var effects: [Effect<Action>] = []
        for run in state.pipelines.runs where run.workspaceID == workspaceID && !run.status.isTerminal {
            let id = run.id
            for nodeRunID in Set(run.activeNodeRunIDs + run.blockingNodeRunIDs) {
                effects.append(pipelineCancelTimers(nodeRunID: nodeRunID))
            }
            PipelinesFeature.updateRun(runID: id, state: &state.pipelines) {
                $0.status = .cancelled
                $0.statusDetail = reason
                $0.completedAt = Date()
            }
            effects.append(pipelineFanOutWatch(&state, runID: id))
        }
        return effects.isEmpty ? .none : .merge(effects)
    }

    // MARK: - GUI monitor entry points (pane-header play button, HUD)

    /// The pane's open document's definition name, if any — used to
    /// resolve what to launch for the play button (there's no `name`
    /// argument the way the CLI has one; the pane already has a
    /// document open).
    private func pipelineOpenDefinitionName(_ state: State, paneID: UUID) -> String? {
        guard let workspace = state.workspaceContainingPane(paneID) else { return nil }
        return workspace.pipelinePanes[paneID]?.pipelineName
    }

    /// Resolves the `runID` a pipeline pane's monitor-mode HUD is
    /// currently showing, if any.
    private func pipelineMonitorRunID(_ state: State, paneID: UUID) -> UUID? {
        guard let workspace = state.workspaceContainingPane(paneID),
              case let .monitor(runID) = workspace.pipelinePanes[paneID]?.mode
        else { return nil }
        return runID
    }

    func handlePipelineRunFromPane(_ state: inout State, paneID: UUID, inputs: [String: String]) -> Effect<Action> {
        guard let workspace = state.workspaceContainingPane(paneID),
              let name = pipelineOpenDefinitionName(state, paneID: paneID)
        else { return .none }

        switch createPipelineRun(&state, paneID: paneID, name: name, inputs: inputs) {
        case .failure(let message, let issues):
            state.workspaces[id: workspace.id]?.pipelinePanes[paneID]?.validationIssues =
                issues.isEmpty ? [.error(message)] : issues
            return .none
        case .created(let runID, let effect):
            state.workspaces[id: workspace.id]?.pipelinePanes[paneID]?.mode = .monitor(runID: runID)
            return effect
        }
    }

    func handlePipelineCancelRunFromPane(_ state: inout State, paneID: UUID) -> Effect<Action> {
        guard let runID = pipelineMonitorRunID(state, paneID: paneID) else { return .none }
        return pipelineCancel(&state, runID: runID)
    }

    func handlePipelineApproveRunFromPane(_ state: inout State, paneID: UUID, edgeKey: String) -> Effect<Action> {
        guard let runID = pipelineMonitorRunID(state, paneID: paneID) else { return .none }
        return pipelineApprove(&state, runID: runID, edgeKey: edgeKey)
    }

    func handlePipelineDenyRunFromPane(_ state: inout State, paneID: UUID, edgeKey: String) -> Effect<Action> {
        guard let runID = pipelineMonitorRunID(state, paneID: paneID) else { return .none }
        return pipelineDeny(&state, runID: runID, edgeKey: edgeKey)
    }

    func handlePipelineResumeRunFromPane(_ state: inout State, paneID: UUID) -> Effect<Action> {
        guard let runID = pipelineMonitorRunID(state, paneID: paneID) else { return .none }
        return pipelineResume(&state, runID: runID)
    }

    func handlePipelineBackToEditFromPane(_ state: inout State, paneID: UUID) {
        guard let workspace = state.workspaceContainingPane(paneID) else { return }
        state.workspaces[id: workspace.id]?.pipelinePanes[paneID]?.mode = .edit
    }

    /// Double-click on a node card in monitor mode: resolve the node's
    /// current/latest `PipelineNodeRun`'s pane, switch to its workspace,
    /// and focus it — the command-palette confirm mechanics (issue
    /// section 6: "jump-to-node").
    func handlePipelineJumpToNode(_ state: inout State, paneID: UUID, nodeID: String) -> Effect<Action> {
        guard let runID = pipelineMonitorRunID(state, paneID: paneID),
              let run = state.pipelines.runs[id: runID]
        else { return .none }
        guard let targetPaneID = run.nodeRuns
            .filter({ $0.nodeID == nodeID })
            .max(by: { $0.attempt < $1.attempt })?
            .paneID,
            let targetWorkspace = state.workspaceContainingPane(targetPaneID)
        else { return .none }

        state.activeWorkspaceID = targetWorkspace.id
        state.workspaces[id: targetWorkspace.id]?.setFocus(targetPaneID)
        let mgr = surfaceManager
        return .run { _ in
            await mgr.focus(paneID: targetPaneID)
        }
    }

    /// StatusBar popover row click: focus the run's current node's pane
    /// if one exists, else just switch to its workspace (e.g. a run
    /// still `.launching` or `.awaitingApproval` before anything spawned).
    func handlePipelineFocusRun(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let run = state.pipelines.runs[id: runID] else { return .none }
        if let currentPaneID = run.mostRecentNodeRun?.paneID,
           let workspace = state.workspaceContainingPane(currentPaneID) {
            state.activeWorkspaceID = workspace.id
            state.workspaces[id: workspace.id]?.setFocus(currentPaneID)
            let mgr = surfaceManager
            return .run { _ in await mgr.focus(paneID: currentPaneID) }
        }
        if let workspaceID = run.workspaceID, state.workspaces[id: workspaceID] != nil {
            state.activeWorkspaceID = workspaceID
        }
        return .none
    }

    // MARK: - `pipeline watch` streaming

    /// Pushes the run's current JSON to every live `pipeline watch`
    /// subscriber (mirrors `fanOutWebConsoleLine`). Subscribers of a run
    /// that just reached a terminal state get one final line, then are
    /// closed and released — a finished run has nothing further to
    /// stream (issue section 4).
    func pipelineFanOutWatch(_ state: inout State, runID: UUID) -> Effect<Action> {
        guard let subscribers = state.pipelineWatchSubscribers[runID], !subscribers.isEmpty,
              let run = state.pipelines.runs[id: runID]
        else { return .none }
        for (_, handle) in subscribers {
            handle.send(["ok": true, "run": Self.runJSON(run)])
        }
        if run.status.isTerminal {
            for (_, handle) in subscribers { handle.close() }
            state.pipelineWatchSubscribers.removeValue(forKey: runID)
        }
        return .none
    }
}
