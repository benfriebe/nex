import CoreGraphics
@testable import Nex
import Testing

@MainActor
struct PipelineAutoLayoutTests {
    private func node(_ id: String) -> PipelineNode {
        PipelineNode(id: id, prompt: "do \(id)")
    }

    @Test func linearChainPlacesNodesInIncreasingColumns() {
        let nodes = [node("a"), node("b"), node("c")]
        let edges = [
            PipelineEdge(from: "a", on: .done, to: "b"),
            PipelineEdge(from: "b", on: .done, to: "c")
        ]
        let positions = PipelineAutoLayout.layout(nodes: nodes, edges: edges, entry: "a")
        #expect(positions["a"]!.x < positions["b"]!.x)
        #expect(positions["b"]!.x < positions["c"]!.x)
    }

    @Test func backEdgeDoesNotPushTargetFurtherRight() {
        // a -> b -> c, c -(fail)-> b (bounce-back). b's column must stay
        // determined by the FORWARD edge (depth 1), not get shoved to
        // depth 3 by the back-edge.
        let nodes = [node("a"), node("b"), node("c")]
        let edges = [
            PipelineEdge(from: "a", on: .done, to: "b"),
            PipelineEdge(from: "b", on: .done, to: "c"),
            PipelineEdge(from: "c", on: .fail, to: "b", maxTraversals: 3)
        ]
        let positions = PipelineAutoLayout.layout(nodes: nodes, edges: edges, entry: "a")
        #expect(positions["b"]!.x == PipelineAutoLayout.origin.x + PipelineAutoLayout.columnSpacing)
    }

    @Test func layoutIsDeterministicAcrossRuns() {
        let nodes = [node("planner"), node("implementer"), node("auditor"), node("tester")]
        let edges = [
            PipelineEdge(from: "planner", on: .done, to: "implementer"),
            PipelineEdge(from: "implementer", on: .done, to: "auditor"),
            PipelineEdge(from: "auditor", on: .fail, to: "implementer", maxTraversals: 3),
            PipelineEdge(from: "auditor", on: .done, to: "tester")
        ]
        let first = PipelineAutoLayout.layout(nodes: nodes, edges: edges, entry: "planner")
        let second = PipelineAutoLayout.layout(nodes: nodes, edges: edges, entry: "planner")
        #expect(first == second)
    }

    @Test func unreachableNodesGetTrailingColumn() {
        let nodes = [node("a"), node("b"), node("orphan")]
        let edges = [PipelineEdge(from: "a", on: .done, to: "b")]
        let positions = PipelineAutoLayout.layout(nodes: nodes, edges: edges, entry: "a")
        #expect(positions["orphan"]!.x > positions["b"]!.x)
    }

    @Test func sameColumnNodesStackInDeclaredOrderWithRowSpacing() {
        let nodes = [node("a"), node("b1"), node("b2")]
        let edges = [
            PipelineEdge(from: "a", on: .done, to: "b1"),
            PipelineEdge(from: "a", on: .fail, to: "b2")
        ]
        let positions = PipelineAutoLayout.layout(nodes: nodes, edges: edges, entry: "a")
        #expect(positions["b1"]!.x == positions["b2"]!.x)
        #expect(abs(positions["b1"]!.y - positions["b2"]!.y) == PipelineAutoLayout.rowSpacing)
    }

    @Test func invalidEntryFallsBackToNaiveLayoutWithoutCrashing() {
        let nodes = [node("a"), node("b")]
        let positions = PipelineAutoLayout.layout(nodes: nodes, edges: [], entry: "missing")
        #expect(positions.count == 2)
    }

    @Test func reconciledPositionsPrefersSavedOverAutoLayout() {
        var definition = PipelineDefinition(
            id: "p", name: "P", entry: "a",
            nodes: [node("a"), node("b")],
            edges: [PipelineEdge(from: "a", on: .done, to: "b")]
        )
        definition.ui.nodes["a"] = CGPoint(x: 999, y: 999)
        let positions = PipelineAutoLayout.reconciledPositions(for: definition)
        #expect(positions["a"] == CGPoint(x: 999, y: 999))
        // b has no saved position -> falls back to auto-layout.
        #expect(positions["b"] != nil)
    }

    @Test func reconciledPositionsDropsStalePositionsForDeletedNodes() {
        var definition = PipelineDefinition(id: "p", name: "P", entry: "a", nodes: [node("a")])
        definition.ui.nodes["ghost"] = CGPoint(x: 1, y: 1)
        let positions = PipelineAutoLayout.reconciledPositions(for: definition)
        #expect(positions["ghost"] == nil)
    }
}
