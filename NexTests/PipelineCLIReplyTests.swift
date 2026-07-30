import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Exercises the `pipeline-run` / `pipeline-handoff` / `pipeline-status`
/// / `pipeline-list` / `pipeline-validate` request-response paths
/// through the reducer, mirroring `GraftCLIReplyTests`' CaptureSink
/// pattern. The definition store is fully stubbed — assertions focus on
/// validate-before-reply, reply shape, and the phase-6 boundary (a
/// created run always lands `.paused`, never silently no-ops).
@MainActor
struct PipelineCLIReplyTests {
    private static let wsID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    private static let paneID = UUID(uuidString: "90000000-0000-0000-0000-00000000000A")!

    private final class CaptureSink: @unchecked Sendable {
        var payloads: [[String: Any]] = []
        var closed = 0
    }

    private func makeCaptureHandle(_ sink: CaptureSink) -> SocketServer.ReplyHandle {
        SocketServer.ReplyHandle(
            id: 1,
            send: { json in sink.payloads.append(json) },
            close: { sink.closed += 1 }
        )
    }

    private func validDefinition() -> PipelineDefinition {
        var definition = PipelineDefinition(id: "loop", name: "Loop", entry: "planner")
        var planner = PipelineNode(id: "planner")
        planner.prompt = "Plan {{inputs.task}}"
        definition.nodes = [planner]
        definition.inputs = ["task": PipelineInputSpec(description: "what to build", required: true)]
        return definition
    }

    private func makeStore(
        definitions: [String: PipelineDefinition] = [:],
        pipelines: PipelinesFeature.State = PipelinesFeature.State()
    ) -> TestStoreOf<AppReducer> {
        var workspace = WorkspaceFeature.State(id: Self.wsID, name: "alpha")
        let pane = Pane(id: Self.paneID)
        workspace.panes = IdentifiedArrayOf(uniqueElements: [pane])
        workspace.layout = .leaf(Self.paneID)
        workspace.focusedPaneID = Self.paneID

        var appState = AppReducer.State()
        appState.workspaces = [workspace]
        appState.activeWorkspaceID = Self.wsID
        appState.topLevelOrder = [.workspace(Self.wsID)]
        appState.pipelines = pipelines

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.continuousClock = ImmediateClock()
            $0.uuid = .incrementing
            $0.pipelineDefinitionStore = PipelineDefinitionStore(
                list: { definitions.keys.sorted() },
                load: { id in
                    guard let definition = definitions[id] else {
                        throw PipelineDefinitionStoreError.notFound(id)
                    }
                    return definition
                },
                save: { _ in },
                delete: { _ in },
                watch: { AsyncStream { _ in } }
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    // MARK: - pipeline-run

    @Test func pipelineRunValidatesAndCreatesLaunchingRunUsingCallerWorkspace() async {
        let store = makeStore(definitions: ["loop": validDefinition()])
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineRun(paneID: Self.paneID, name: "loop", inputs: ["task": "add a --version flag"]),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        // The reply is sent synchronously before the execution engine's
        // async spawn chain runs at all, so it always reflects the
        // just-created run's initial status regardless of how spawning
        // later resolves (in this test environment, with no real
        // `SurfaceManager` surfaces, the entry node's spawn eventually
        // times out and the run lands `.failed` — asserted separately).
        #expect(sink.payloads.count == 1)
        #expect(sink.closed == 1)
        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["status"] as? String == "launching")
        #expect((sink.payloads[0]["run_id"] as? String)?.isEmpty == false)
    }

    @Test func pipelineRunFallsBackToActiveWorkspaceWithoutPaneID() async {
        let store = makeStore(definitions: ["loop": validDefinition()])
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineRun(paneID: nil, name: "loop", inputs: ["task": "x"]),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
    }

    @Test func pipelineRunFailsWhenPipelineNotFound() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineRun(paneID: Self.paneID, name: "missing", inputs: [:]),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
    }

    @Test func pipelineRunFailsWhenRequiredInputMissing() async {
        let store = makeStore(definitions: ["loop": validDefinition()])
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineRun(paneID: Self.paneID, name: "loop", inputs: [:]),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("task") == true)
    }

    @Test func pipelineRunFailsWhenDefinitionHasValidationErrors() async {
        var broken = validDefinition()
        broken.nodes = [] // triggers "has no nodes" + "entry not declared"
        let store = makeStore(definitions: ["broken": broken])
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineRun(paneID: Self.paneID, name: "broken", inputs: ["task": "x"]),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        let issues = sink.payloads[0]["issues"] as? [[String: Any]] ?? []
        #expect(!issues.isEmpty)
    }

    @Test func pipelineRunWithWorkspaceLocationProvisionsADedicatedWorkspace() async {
        var definition = validDefinition()
        definition.location = .workspace
        let store = makeStore(definitions: ["loop": definition])
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineRun(paneID: Self.paneID, name: "loop", inputs: ["task": "x"]),
            reply: makeCaptureHandle(sink)
        ))
        // Non-exhaustive mode still requires draining queued
        // actions via `skipReceivedActions()` before `store.state`
        // reflects mutations from actions dispatched by an effect
        // (`.createWorkspace`, the delegate re-entry chain) rather
        // than sent directly by the test — `store.finish()` alone
        // only awaits in-flight effect *work*, not action delivery.
        await store.skipReceivedActions()
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["status"] as? String == "launching")
        // `location: workspace` mints its own workspace asynchronously —
        // the caller's original workspace is untouched, and a second one
        // now exists for the run.
        #expect(store.state.workspaces.count == 2)
        let runID = (sink.payloads[0]["run_id"] as? String).flatMap(UUID.init)
        #expect(runID != nil)
        if let runID {
            let run = store.state.pipelines.runs[id: runID]
            #expect(run?.workspaceID != nil)
            #expect(run?.workspaceID != Self.wsID)
        }
    }

    // MARK: - pipeline-handoff

    @Test func pipelineHandoffWithNoActiveNodeForPaneFailsWithStructuredError() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineHandoff(
                paneID: Self.paneID, outcome: .done, summary: nil, output: nil,
                runID: nil, nodeID: nil, force: false
            ),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("no active pipeline node") == true)
    }

    @Test func pipelineHandoffWithoutPaneIDOrForceFailsWithUsageError() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineHandoff(
                paneID: nil, outcome: .done, summary: nil, output: nil,
                runID: nil, nodeID: nil, force: false
            ),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("NEX_PANE_ID") == true)
    }

    @Test func pipelineHandoffForceWithoutBothRunAndNodeFails() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineHandoff(
                paneID: nil, outcome: .done, summary: nil, output: nil,
                runID: "not-a-real-run", nodeID: nil, force: true
            ),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("--force requires") == true)
    }

    @Test func pipelineHandoffForceWithUnknownRunFails() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineHandoff(
                paneID: nil, outcome: .done, summary: nil, output: nil,
                runID: UUID().uuidString, nodeID: "planner", force: true
            ),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
        #expect((sink.payloads[0]["error"] as? String)?.contains("no such pipeline run") == true)
    }

    /// A node past its first attempt (bounce-back retry) must still be
    /// force-resolvable — matching the FIRST NodeRun for that node id
    /// would keep hitting an already-terminal attempt 1 forever, making
    /// `--force` useless for exactly the case it exists to unstick
    /// (found live during issue #282 phase 6-7 validation).
    @Test func pipelineHandoffForceTargetsLatestAttemptNotFirst() async {
        let runID = UUID()
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        let now = Date()
        var run = PipelineRun(
            id: runID,
            definitionID: "loop",
            definitionSnapshot: PipelineDefinition(id: "loop", name: "Loop", entry: "worker"),
            status: .launching,
            location: .current,
            runDir: "/runs/\(runID.uuidString)",
            createdAt: now,
            updatedAt: now
        )
        run.nodeRuns = [
            PipelineNodeRun(
                id: firstAttemptID, nodeID: "worker", attempt: 1, status: .done,
                startedAt: now, updatedAt: now, completedAt: now
            ),
            PipelineNodeRun(
                id: secondAttemptID, nodeID: "worker", attempt: 2, status: .running,
                startedAt: now, updatedAt: now
            )
        ]
        run.currentNodeRunID = secondAttemptID
        var pipelines = PipelinesFeature.State()
        pipelines.runs = [run]

        let store = makeStore(pipelines: pipelines)
        let sink = CaptureSink()
        await store.send(.socketMessage(
            .pipelineHandoff(
                paneID: nil, outcome: .done, summary: "attempt 2 done", output: nil,
                runID: runID.uuidString, nodeID: "worker", force: true
            ),
            reply: makeCaptureHandle(sink)
        ))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["node_run_id"] as? String == secondAttemptID.uuidString)
    }

    // MARK: - pipeline-status / list / validate

    @Test func pipelineStatusWithNoRunsReturnsEmptyArray() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(.pipelineStatus(runID: nil), reply: makeCaptureHandle(sink)))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect((sink.payloads[0]["runs"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func pipelineStatusUnknownRunIDFails() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(.pipelineStatus(runID: UUID().uuidString), reply: makeCaptureHandle(sink)))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
    }

    @Test func pipelineListReturnsDefinitionsWithCounts() async {
        let store = makeStore(definitions: ["loop": validDefinition()])
        let sink = CaptureSink()
        await store.send(.socketMessage(.pipelineList, reply: makeCaptureHandle(sink)))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        let pipelines = sink.payloads[0]["pipelines"] as? [[String: Any]] ?? []
        #expect(pipelines.count == 1)
        #expect(pipelines.first?["id"] as? String == "loop")
        #expect(pipelines.first?["node_count"] as? Int == 1)
    }

    @Test func pipelineValidateReportsIssuesWithoutCreatingARun() async {
        var broken = validDefinition()
        broken.nodes = []
        let store = makeStore(definitions: ["broken": broken])
        let sink = CaptureSink()
        await store.send(.socketMessage(.pipelineValidate(name: "broken"), reply: makeCaptureHandle(sink)))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == true)
        #expect(sink.payloads[0]["valid"] as? Bool == false)
        #expect(((sink.payloads[0]["issues"] as? [[String: Any]]) ?? []).isEmpty == false)
    }

    @Test func pipelineValidateUnknownPipelineFails() async {
        let store = makeStore()
        let sink = CaptureSink()
        await store.send(.socketMessage(.pipelineValidate(name: "missing"), reply: makeCaptureHandle(sink)))
        await store.finish()

        #expect(sink.payloads[0]["ok"] as? Bool == false)
    }

    /// `reply: nil` must never crash — the legacy fire-and-forget path.
    @Test func pipelineRunToleratesNilReply() async {
        let store = makeStore(definitions: ["loop": validDefinition()])
        await store.send(.socketMessage(
            .pipelineRun(paneID: Self.paneID, name: "loop", inputs: ["task": "x"]), reply: nil
        ))
        await store.finish()
    }
}
