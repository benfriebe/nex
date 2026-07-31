import Foundation
@testable import Nex
import Testing

/// Direct unit tests for `PipelineEngineLogic` — templating (every
/// namespace, unresolved-placeholder warnings, the always-appended
/// context + handoff sections), routing (declared-only `maxTraversals`,
/// partial→done fallback), and launch-command safety validation.
struct PipelineEngineTests {
    // MARK: - Templating

    @Test func rendersInputsNodesRunAndFeedbackNamespaces() {
        var node = PipelineNode(id: "implementer")
        node.prompt = "Task: {{inputs.task}}\nPlan: {{nodes.planner.output}}\nSummary: {{nodes.planner.summary}}\nRun {{run.id}} at {{run.dir}}\n{{feedback}}"

        let context = PipelineTemplateContext(
            inputs: ["task": "add a --version flag"],
            nodeArtifacts: ["planner": PipelineNodeArtifact(outputPath: "/runs/1/planner/output.md", summary: "planned it")],
            runID: "run-1",
            runDir: "/runs/1",
            feedback: PipelineFeedback(summary: "fix the tests", artifactPath: "/runs/1/auditor/output.md")
        )

        let rendered = PipelineEngineLogic.renderPrompt(node: node, context: context)

        #expect(rendered.warnings.isEmpty)
        #expect(rendered.text.contains("Task: add a --version flag"))
        #expect(rendered.text.contains("Plan: /runs/1/planner/output.md"))
        #expect(rendered.text.contains("Summary: planned it"))
        #expect(rendered.text.contains("Run run-1 at /runs/1"))
        #expect(rendered.text.contains("fix the tests"))
        #expect(rendered.text.contains("/runs/1/auditor/output.md"))
    }

    @Test func feedbackIsEmptyNotWarningOnFirstVisit() {
        var node = PipelineNode(id: "implementer")
        node.prompt = "Feedback: [{{feedback}}]"
        let context = PipelineTemplateContext(runID: "run-1", runDir: "/runs/1", feedback: nil)

        let rendered = PipelineEngineLogic.renderPrompt(node: node, context: context)

        #expect(rendered.warnings.isEmpty)
        #expect(rendered.text.contains("Feedback: []"))
    }

    @Test func unresolvedPlaceholderRendersEmptyAndWarns() {
        var node = PipelineNode(id: "planner")
        node.prompt = "See {{nodes.missing.output}} and {{inputs.absent}} and {{bogus}}"
        let context = PipelineTemplateContext(runID: "run-1", runDir: "/runs/1")

        let rendered = PipelineEngineLogic.renderPrompt(node: node, context: context)

        #expect(rendered.warnings.count == 3)
        #expect(rendered.text.contains("See  and  and "))
    }

    @Test func contextSectionAndHandoffAppendixAlwaysAppended() {
        var node = PipelineNode(id: "planner")
        node.prompt = "Do the thing."
        let context = PipelineTemplateContext(runID: "run-1", runDir: "/runs/1")

        let rendered = PipelineEngineLogic.renderPrompt(node: node, context: context)

        #expect(rendered.text.contains("## Pipeline context"))
        #expect(rendered.text.contains("Run: run-1"))
        #expect(rendered.text.contains(PipelineEngineLogic.handoffAppendix))
        #expect(rendered.text.contains("nex pipeline done"))
    }

    // MARK: - Routing

    private func makeDefinition() -> PipelineDefinition {
        var definition = PipelineDefinition(name: "Feature Loop", entry: "planner")
        definition.nodes = [
            PipelineNode(id: "planner"),
            PipelineNode(id: "implementer"),
            PipelineNode(id: "auditor"),
            PipelineNode(id: "tester")
        ]
        definition.edges = [
            PipelineEdge(from: "planner", on: .done, to: "implementer"),
            // Fan-out: planner|done also fires straight to auditor, in
            // parallel with implementer (issue #282 round 3).
            PipelineEdge(from: "planner", on: .done, to: "auditor"),
            PipelineEdge(from: "implementer", on: .done, to: "auditor"),
            PipelineEdge(from: "auditor", on: .fail, to: "implementer", maxTraversals: 3),
            PipelineEdge(from: "auditor", on: .done, to: "tester", requiresApproval: true)
        ]
        return definition
    }

    @Test func routesAlongMatchingEdge() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "implementer", outcome: .done, traversals: [:]
        )
        #expect(transition == .routes([
            PipelineRoute(to: "auditor", requiresApproval: false, edgeKey: "implementer|done|auditor")
        ]))
    }

    @Test func fanOutFiresEveryMatchingEdgeForTheSameFromAndOutcome() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "planner", outcome: .done, traversals: [:]
        )
        #expect(transition == .routes([
            PipelineRoute(to: "implementer", requiresApproval: false, edgeKey: "planner|done|implementer"),
            PipelineRoute(to: "auditor", requiresApproval: false, edgeKey: "planner|done|auditor")
        ]))
    }

    @Test func approvalGateEdgePropagatesRequiresApproval() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "auditor", outcome: .done, traversals: [:]
        )
        #expect(transition == .routes([
            PipelineRoute(to: "tester", requiresApproval: true, edgeKey: "auditor|done|tester")
        ]))
    }

    @Test func doneWithNoMatchingEdgeCompletesRun() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "tester", outcome: .done, traversals: [:]
        )
        #expect(transition == .completed)
    }

    @Test func failWithNoFailEdgeFailsRun() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "planner", outcome: .fail, traversals: [:]
        )
        guard case .failed = transition else {
            Issue.record("expected .failed, got \(transition)")
            return
        }
    }

    @Test func partialWithNoPartialEdgeFallsBackToDoneEdges() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "planner", outcome: .partial, traversals: [:]
        )
        #expect(transition == .routes([
            PipelineRoute(to: "implementer", requiresApproval: false, edgeKey: "planner|done|implementer"),
            PipelineRoute(to: "auditor", requiresApproval: false, edgeKey: "planner|done|auditor")
        ]))
    }

    @Test func partialWithNeitherPartialNorDoneEdgeCompletesRun() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "tester", outcome: .partial, traversals: [:]
        )
        #expect(transition == .completed)
    }

    @Test func declaredMaxTraversalsExhaustionFailsWithLoopExhausted() {
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "auditor", outcome: .fail,
            traversals: ["auditor|fail|implementer": 3]
        )
        guard case .failed(let reason) = transition else {
            Issue.record("expected .failed, got \(transition)")
            return
        }
        #expect(reason == "loop_exhausted: auditor|fail|implementer")
    }

    @Test func undeclaredMaxTraversalsIsUnlimited() {
        // planner->implementer has no maxTraversals — any traversal count routes.
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: makeDefinition(), from: "implementer", outcome: .done,
            traversals: ["implementer|done|auditor": 999]
        )
        #expect(transition == .routes([
            PipelineRoute(to: "auditor", requiresApproval: false, edgeKey: "implementer|done|auditor")
        ]))
    }

    @Test func maxTraversalsExceededOnAnyFiredEdgeFailsTheWholeHandoffAtomically() {
        // planner|done fans out to BOTH implementer and auditor; if the
        // auditor leg alone would exceed its declared cap, the whole
        // handoff fails rather than routing implementer and silently
        // dropping auditor.
        var definition = makeDefinition()
        definition.edges.append(PipelineEdge(from: "planner", on: .done, to: "tester", maxTraversals: 1))
        let transition = PipelineEngineLogic.evaluateTransition(
            definition: definition, from: "planner", outcome: .done,
            traversals: ["planner|done|tester": 1]
        )
        guard case .failed(let reason) = transition else {
            Issue.record("expected .failed, got \(transition)")
            return
        }
        #expect(reason == "loop_exhausted: planner|done|tester")
    }

    // MARK: - Launch command safety

    @Test func composeLaunchCommandHeadlessIncludesAllowlistAndRedirect() {
        var node = PipelineNode(id: "planner", mode: .headless, permissionMode: .acceptEdits)
        node.model = "opus"
        let result = PipelineEngineLogic.composeLaunchCommand(
            node: node, runID: "run-1", attempt: 1,
            runDir: "/runs/run-1", promptPath: "/runs/run-1/nodes/planner/attempt-1/prompt.md"
        )
        guard case .success(let command) = result else {
            Issue.record("expected success")
            return
        }
        #expect(command.contains("claude -p"))
        #expect(command.contains("--permission-mode acceptEdits"))
        #expect(command.contains("--model opus"))
        #expect(command.contains(#"Bash(nex pipeline:*)"#))
        #expect(command.contains("Edit(/runs/run-1/**)"))
        #expect(command.contains("NEX_PIPELINE_RUN='run-1'"))
        #expect(command.contains("NEX_PIPELINE_NODE='planner'"))
        #expect(command.contains("< '/runs/run-1/nodes/planner/attempt-1/prompt.md'"))
    }

    @Test func composeLaunchCommandInteractiveOmitsRedirectAndDashP() {
        let node = PipelineNode(id: "implementer", mode: .interactive, permissionMode: .acceptEdits)
        let result = PipelineEngineLogic.composeLaunchCommand(
            node: node, runID: "run-1", attempt: 1,
            runDir: "/runs/run-1", promptPath: "/runs/run-1/nodes/implementer/attempt-1/prompt.md"
        )
        guard case .success(let command) = result else {
            Issue.record("expected success")
            return
        }
        #expect(!command.contains(" -p"))
        #expect(!command.contains("<"))
    }

    @Test func composeLaunchCommandRejectsUnsafeModel() {
        var node = PipelineNode(id: "planner")
        node.model = "opus; rm -rf /"
        let result = PipelineEngineLogic.composeLaunchCommand(
            node: node, runID: "run-1", attempt: 1, runDir: "/runs/run-1", promptPath: "/p.md"
        )
        #expect(result == .failure(.unsafeModel("opus; rm -rf /")))
    }

    @Test func composeLaunchCommandRejectsEnvValueWithNewline() {
        var node = PipelineNode(id: "planner")
        node.env = ["FOO": "bar\nBash(rm -rf /)="]
        let result = PipelineEngineLogic.composeLaunchCommand(
            node: node, runID: "run-1", attempt: 1, runDir: "/runs/run-1", promptPath: "/p.md"
        )
        #expect(result == .failure(.unsafeEnvValue(key: "FOO")))
    }

    @Test func composeLaunchCommandSingleQuotesEnvValueWithEmbeddedQuote() {
        var node = PipelineNode(id: "planner")
        node.env = ["GREETING": "it's fine"]
        let result = PipelineEngineLogic.composeLaunchCommand(
            node: node, runID: "run-1", attempt: 1, runDir: "/runs/run-1", promptPath: "/p.md"
        )
        guard case .success(let command) = result else {
            Issue.record("expected success")
            return
        }
        #expect(command.contains(#"GREETING='it'\''s fine'"#))
    }

    // MARK: - File work

    @Test func prepareAttemptDirCreatesNestedDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: base) }

        let dir = try PipelineEngineLogic.prepareAttemptDir(runDir: base, nodeID: "planner", attempt: 2)

        #expect(dir == base + "/nodes/planner/attempt-2")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func writeResultJSONRoundTrips() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let result = PipelineNodeResult(nodeID: "planner", attempt: 1, outcome: .done, summary: "done", completedAt: Date(timeIntervalSince1970: 1000))
        try PipelineEngineLogic.writeResultJSON(attemptDir: base, result: result)

        let data = try Data(contentsOf: URL(fileURLWithPath: base + "/result.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PipelineNodeResult.self, from: data)
        #expect(decoded == result)
    }
}
