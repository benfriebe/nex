import CoreGraphics
@testable import Nex
import Testing

@MainActor
struct PipelineDefinitionTests {
    private func makeValidDefinition() -> PipelineDefinition {
        PipelineDefinition(
            id: "feature-loop",
            name: "Feature Loop",
            description: "plan -> implement -> audit -> test",
            entry: "planner",
            nodes: [
                PipelineNode(id: "planner", prompt: "Plan the implementation of: {{inputs.task}}"),
                PipelineNode(
                    id: "implementer", mode: .interactive, permissionMode: .acceptEdits,
                    prompt: "Implement the plan.\n{{feedback}}"
                ),
                PipelineNode(id: "auditor", prompt: "Review the implementation."),
                PipelineNode(id: "tester", permissionMode: .acceptEdits, prompt: "Run the tests.")
            ],
            edges: [
                PipelineEdge(from: "planner", on: .done, to: "implementer"),
                PipelineEdge(from: "implementer", on: .done, to: "auditor"),
                PipelineEdge(from: "auditor", on: .fail, to: "implementer", maxTraversals: 3),
                PipelineEdge(from: "auditor", on: .done, to: "tester", requiresApproval: true)
            ],
            ui: PipelineUIMetadata(nodes: ["planner": CGPoint(x: 80, y: 120), "implementer": CGPoint(x: 320, y: 120)])
        )
    }

    // MARK: - YAML round-trip

    @Test func yamlRoundTripPreservesAllFields() throws {
        let original = makeValidDefinition()
        let yaml = try original.toYAML()
        let decoded = try PipelineDefinition.fromYAML(yaml, id: original.id)
        #expect(decoded == original)
    }

    @Test func yamlRoundTripPreservesUIPositions() throws {
        let original = makeValidDefinition()
        let yaml = try original.toYAML()
        let decoded = try PipelineDefinition.fromYAML(yaml, id: original.id)
        #expect(decoded.ui.nodes["planner"] == CGPoint(x: 80, y: 120))
        #expect(decoded.ui.nodes["implementer"] == CGPoint(x: 320, y: 120))
    }

    @Test func idIsNotSerializedIntoYAML() throws {
        let original = makeValidDefinition()
        let yaml = try original.toYAML()
        // Node ids legitimately appear as "  - id: planner" etc.; only
        // a TOP-LEVEL (column-0) "id:" key would mean the pipeline's
        // own id leaked into the payload.
        let topLevelIDLines = yaml.components(separatedBy: "\n").filter { $0.hasPrefix("id:") }
        #expect(topLevelIDLines.isEmpty)
    }

    @Test func decodingAppliesDefaultsForOmittedFields() throws {
        let yaml = """
        name: Minimal
        entry: only
        nodes:
          - id: only
            prompt: Do the thing.
        """
        let decoded = try PipelineDefinition.fromYAML(yaml, id: "minimal")
        #expect(decoded.version == PipelineDefinition.currentSchemaVersion)
        #expect(decoded.location == .current)
        #expect(decoded.nodes[0].agent == .claude)
        #expect(decoded.nodes[0].mode == .headless)
        #expect(decoded.nodes[0].permissionMode == .default)
        #expect(decoded.edges.isEmpty)
        #expect(decoded.ui.nodes.isEmpty)
    }

    @Test func decodingToleratesUnknownTopLevelKeys() throws {
        let yaml = """
        name: Forward Compat
        entry: only
        futureTopLevelKey: some value
        nodes:
          - id: only
            prompt: Do the thing.
            futureNodeKey: 42
        """
        let decoded = try PipelineDefinition.fromYAML(yaml, id: "forward-compat")
        #expect(decoded.name == "Forward Compat")
        #expect(decoded.nodes.count == 1)
        #expect(decoded.validate().isEmpty)
    }

    // MARK: - Validation

    @Test func validDefinitionHasNoIssues() {
        #expect(makeValidDefinition().validate().isEmpty)
    }

    @Test func emptyNodesIsAnError() {
        let definition = PipelineDefinition(id: "empty", name: "Empty", entry: "")
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("no nodes") })
    }

    @Test func unknownEntryIsAnError() {
        var definition = makeValidDefinition()
        definition.entry = "nonexistent"
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("Entry node") })
    }

    @Test func duplicateNodeIDsIsAnError() {
        var definition = makeValidDefinition()
        definition.nodes.append(PipelineNode(id: "planner", prompt: "duplicate"))
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("Duplicate node id") })
    }

    @Test func duplicateFromOnEdgePairIsAnError() {
        var definition = makeValidDefinition()
        definition.edges.append(PipelineEdge(from: "planner", on: .done, to: "auditor"))
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("Duplicate edge") })
    }

    @Test func unknownEdgeEndpointsAreErrors() {
        var definition = makeValidDefinition()
        definition.edges.append(PipelineEdge(from: "planner", on: .partial, to: "ghost"))
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("unknown target node") })
    }

    @Test func emptyPromptIsAnError() {
        var definition = makeValidDefinition()
        definition.nodes[0].prompt = "   "
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.nodeID == "planner" && $0.message.contains("empty prompt") })
    }

    @Test func codexAgentIsRejectedInV1() {
        var definition = makeValidDefinition()
        definition.nodes[0].agent = .codex
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("not supported in v1") })
    }

    @Test func headlessPlanPermissionModeIsAnError() {
        var definition = makeValidDefinition()
        definition.nodes[0].mode = .headless
        definition.nodes[0].permissionMode = .plan
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("plan mode blocks") })
    }

    @Test func unreachableNodeIsAWarningNotAnError() {
        var definition = makeValidDefinition()
        definition.nodes.append(PipelineNode(id: "orphan", prompt: "never reached"))
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .warning && $0.nodeID == "orphan" })
        #expect(!issues.contains { $0.severity == .error && $0.nodeID == "orphan" })
    }

    @Test func maxTraversalsBelowOneIsAnError() {
        var definition = makeValidDefinition()
        definition.edges[2].maxTraversals = 0
        let issues = definition.validate()
        #expect(issues.contains { $0.severity == .error && $0.message.contains("maxTraversals") })
    }

    @Test func undeclaredMaxTraversalsIsUnlimited() {
        let definition = makeValidDefinition()
        // The done->implementer edge has no maxTraversals declared.
        #expect(definition.edges[0].maxTraversals == nil)
        #expect(definition.validate().isEmpty)
    }

    @Test func slugValidationRejectsUppercaseAndSymbols() {
        #expect(PipelineDefinition.isValidSlug("feature-loop-2"))
        #expect(!PipelineDefinition.isValidSlug("Feature_Loop"))
        #expect(!PipelineDefinition.isValidSlug(""))
        #expect(!PipelineDefinition.isValidSlug("has space"))
    }
}
