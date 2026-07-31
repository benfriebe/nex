import CoreGraphics
import Foundation
import Yams

/// Where a pipeline run's node panes are spawned. `current` resolves to
/// the caller's workspace (or the active workspace when launched from
/// the GUI); `workspace` opens a dedicated workspace; `worktree` creates
/// a fresh git worktree + workspace (reusing the `workspace create
/// --worktree` flow from issue #222).
enum PipelineLocation: String, Codable, Equatable, CaseIterable {
    case current
    case workspace
    case worktree
}

/// Headless nodes run `claude -p` to completion and exit; interactive
/// nodes stay open in a TUI and receive a pointer message.
enum PipelineNodeMode: String, Codable, Equatable, CaseIterable {
    case headless
    case interactive
}

/// Mirrors the claude CLI's actual `--permission-mode` values. There is
/// deliberately no "auto" — every mode here is something `claude`
/// itself accepts.
enum PipelinePermissionMode: String, Codable, Equatable, CaseIterable {
    case `default`
    case acceptEdits
    case plan
    case bypassPermissions
    case dontAsk
}

/// The three handoff outcomes a node can report via
/// `nex pipeline done|fail|partial`. Routing (`PipelineEdge.on`) is
/// keyed on this.
enum PipelineNodeOutcome: String, Codable, Equatable, CaseIterable {
    case done
    case fail
    case partial
}

/// One declared pipeline input, surfaced in `RunPipelineSheet` and
/// substituted via `{{inputs.<name>}}`.
struct PipelineInputSpec: Codable, Equatable {
    var description: String?
    var required: Bool = false

    init(description: String? = nil, required: Bool = false) {
        self.description = description
        self.required = required
    }

    private enum CodingKeys: String, CodingKey {
        case description, required
    }

    /// Swift's synthesized Decodable does NOT fall back to a property's
    /// default value when the key is missing (defaults only affect the
    /// memberwise initializer) — every type below with optional YAML
    /// fields needs this same hand-rolled `init(from:)`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }
}

/// One node in the pipeline graph. `id` is a slug (`[a-z0-9-]+`), unique
/// within the definition, and is how edges/templates/CLI reference it.
struct PipelineNode: Codable, Equatable, Identifiable {
    var id: String
    var name: String?
    var agent: AgentKind = .claude
    var model: String?
    var mode: PipelineNodeMode = .headless
    var permissionMode: PipelinePermissionMode = .default
    var env: [String: String] = [:]
    var workingDir: String?
    var timeoutMinutes: Int?
    var prompt: String = ""

    /// Display name for the canvas/inspector — falls back to `id`.
    var displayName: String { name?.isEmpty == false ? name! : id }

    init(
        id: String,
        name: String? = nil,
        agent: AgentKind = .claude,
        model: String? = nil,
        mode: PipelineNodeMode = .headless,
        permissionMode: PipelinePermissionMode = .default,
        env: [String: String] = [:],
        workingDir: String? = nil,
        timeoutMinutes: Int? = nil,
        prompt: String = ""
    ) {
        self.id = id
        self.name = name
        self.agent = agent
        self.model = model
        self.mode = mode
        self.permissionMode = permissionMode
        self.env = env
        self.workingDir = workingDir
        self.timeoutMinutes = timeoutMinutes
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, agent, model, mode, permissionMode, env, workingDir, timeoutMinutes, prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        model = try container.decodeIfPresent(String.self, forKey: .model)
        mode = try container.decodeIfPresent(PipelineNodeMode.self, forKey: .mode) ?? .headless
        permissionMode = try container.decodeIfPresent(PipelinePermissionMode.self, forKey: .permissionMode) ?? .default
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        workingDir = try container.decodeIfPresent(String.self, forKey: .workingDir)
        timeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .timeoutMinutes)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}

/// A routing rule: when node `from` reports outcome `on`, transition to
/// node `to`. `maxTraversals` is nil (unlimited) unless declared — only
/// declared limits are enforced, so a default cap can't silently kill a
/// legitimate bounce-back loop via forward-edge exhaustion.
struct PipelineEdge: Codable, Equatable {
    var from: String
    var on: PipelineNodeOutcome
    var to: String
    var maxTraversals: Int?
    var requiresApproval: Bool = false

    init(
        from: String,
        on: PipelineNodeOutcome,
        to: String,
        maxTraversals: Int? = nil,
        requiresApproval: Bool = false
    ) {
        self.from = from
        self.on = on
        self.to = to
        self.maxTraversals = maxTraversals
        self.requiresApproval = requiresApproval
    }

    private enum CodingKeys: String, CodingKey {
        case from, on, to, maxTraversals, requiresApproval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        on = try container.decode(PipelineNodeOutcome.self, forKey: .on)
        to = try container.decode(String.self, forKey: .to)
        maxTraversals = try container.decodeIfPresent(Int.self, forKey: .maxTraversals)
        requiresApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresApproval) ?? false
    }

    /// Stable identity for one edge: `from|on|to`. Fan-out (multiple
    /// edges sharing a `(from, on)` pair, routing to different targets)
    /// is legal — only an exactly-identical triple twice is rejected at
    /// validation time — so `identityKey` (not just `(from, on)`) is
    /// what's unique. Used to track per-edge `maxTraversals` counts
    /// (`PipelineRun.edgeTraversals`), to key `ui.edges` layout overrides,
    /// and as the wire `edge` key for `pipeline approve|deny --edge`.
    var identityKey: String { "\(from)|\(on.rawValue)|\(to)" }
}

/// Editor-owned layout metadata. The engine ignores this entirely; the
/// YAML codec round-trips it losslessly. This is the sole position
/// store — there is no separate `layout:` key or sidecar file.
///
/// `CGPoint`'s own Codable conformance encodes as a 2-element array
/// (`[x, y]`), not the keyed `{x: .., y: ..}` shape the YAML schema
/// wants, so positions are coded through a private keyed proxy.
struct PipelineUIMetadata: Equatable {
    var nodes: [String: CGPoint] = [:]
    /// Per-edge curve overrides, keyed by `PipelineEdge.identityKey`
    /// (`from|on|to`) — needed now that duplicate `(from, on)` pairs are
    /// legal (fan-out), so an edge's UI identity must include `to`.
    /// Absent = the canvas falls back to its deterministic default curve
    /// (`PipelineEdgeLayer`'s symmetric horizontal control points) — a
    /// hand-authored YAML file never needs an `edges:` block.
    var edges: [String: PipelineEdgeUI] = [:]
}

/// One edge's saved curve bend, as a control-point offset (document
/// units) applied symmetrically to both cubic bezier control points —
/// dragging an edge's midpoint handle writes here.
struct PipelineEdgeUI: Equatable {
    var offset: CGPoint
}

extension PipelineUIMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case nodes, edges
    }

    private struct PointCoding: Codable {
        var x: Double
        var y: Double
    }

    private struct EdgeCoding: Codable {
        var offsetX: Double
        var offsetY: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawNodes = try container.decodeIfPresent([String: PointCoding].self, forKey: .nodes) ?? [:]
        nodes = rawNodes.mapValues { CGPoint(x: $0.x, y: $0.y) }
        let rawEdges = try container.decodeIfPresent([String: EdgeCoding].self, forKey: .edges) ?? [:]
        edges = rawEdges.mapValues { PipelineEdgeUI(offset: CGPoint(x: $0.offsetX, y: $0.offsetY)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let rawNodes = nodes.mapValues { PointCoding(x: Double($0.x), y: Double($0.y)) }
        try container.encode(rawNodes, forKey: .nodes)
        if !edges.isEmpty {
            let rawEdges = edges.mapValues { EdgeCoding(offsetX: Double($0.offset.x), offsetY: Double($0.offset.y)) }
            try container.encode(rawEdges, forKey: .edges)
        }
    }
}

/// A single non-fatal-or-fatal problem found by `PipelineDefinition.validate()`.
/// Shared between the CLI (`nex pipeline validate`) and the canvas editor's
/// live error display.
struct PipelineValidationIssue: Equatable, Identifiable {
    enum Severity: String, Equatable {
        case error
        case warning
    }

    var severity: Severity
    var message: String
    var nodeID: String?
    var edgeIndex: Int?

    var id: String {
        "\(severity.rawValue)|\(nodeID ?? "")|\(edgeIndex.map(String.init) ?? "")|\(message)"
    }

    static func error(_ message: String, nodeID: String? = nil, edgeIndex: Int? = nil) -> Self {
        Self(severity: .error, message: message, nodeID: nodeID, edgeIndex: edgeIndex)
    }

    static func warning(_ message: String, nodeID: String? = nil, edgeIndex: Int? = nil) -> Self {
        Self(severity: .warning, message: message, nodeID: nodeID, edgeIndex: edgeIndex)
    }
}

/// A pipeline: a graph of agent nodes with outcome-conditional edges.
/// Definitions live as YAML files in `~/.config/nex/pipelines/`
/// (`PipelineDefinitionStore`); the filename slug (minus `.yaml`) is
/// the definition's `id` and is deliberately NOT part of the YAML
/// payload — it's assigned by the store when a file is loaded.
struct PipelineDefinition: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    /// Filename slug. Not serialized — see `CodingKeys`.
    var id: String = ""

    var name: String
    var description: String?
    var version: Int = PipelineDefinition.currentSchemaVersion
    var location: PipelineLocation = .current
    var inputs: [String: PipelineInputSpec] = [:]
    var entry: String
    var nodes: [PipelineNode] = []
    var edges: [PipelineEdge] = []
    var ui: PipelineUIMetadata = .init()

    private enum CodingKeys: String, CodingKey {
        case name, description, version, location, inputs, entry, nodes, edges, ui
    }

    init(
        id: String = "",
        name: String,
        description: String? = nil,
        version: Int = PipelineDefinition.currentSchemaVersion,
        location: PipelineLocation = .current,
        inputs: [String: PipelineInputSpec] = [:],
        entry: String,
        nodes: [PipelineNode] = [],
        edges: [PipelineEdge] = [],
        ui: PipelineUIMetadata = PipelineUIMetadata()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.location = location
        self.inputs = inputs
        self.entry = entry
        self.nodes = nodes
        self.edges = edges
        self.ui = ui
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? PipelineDefinition.currentSchemaVersion
        location = try container.decodeIfPresent(PipelineLocation.self, forKey: .location) ?? .current
        inputs = try container.decodeIfPresent([String: PipelineInputSpec].self, forKey: .inputs) ?? [:]
        entry = try container.decode(String.self, forKey: .entry)
        nodes = try container.decodeIfPresent([PipelineNode].self, forKey: .nodes) ?? []
        edges = try container.decodeIfPresent([PipelineEdge].self, forKey: .edges) ?? []
        ui = try container.decodeIfPresent(PipelineUIMetadata.self, forKey: .ui) ?? PipelineUIMetadata()
    }

    /// `id`'s allowed shape: lowercase alnum + hyphen, non-empty. Also
    /// used for node ids (same slug rule).
    static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        return slug.allSatisfy { $0.isASCII && ($0.isLowercaseLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: - YAML codec

    static func fromYAML(_ yaml: String, id: String) throws -> PipelineDefinition {
        var definition = try YAMLDecoder().decode(PipelineDefinition.self, from: yaml)
        definition.id = id
        return definition
    }

    func toYAML() throws -> String {
        try YAMLEncoder().encode(self)
    }

    // MARK: - Validation

    /// Validates structural and semantic rules shared by the CLI
    /// (`nex pipeline validate`) and the canvas editor. Does not touch
    /// the filesystem or check template placeholders (that's the
    /// engine's job at render time).
    func validate() -> [PipelineValidationIssue] {
        var issues: [PipelineValidationIssue] = []

        if !Self.isValidSlug(id), !id.isEmpty {
            issues.append(.error("Pipeline id \"\(id)\" must match [a-z0-9-]+"))
        }
        if nodes.isEmpty {
            issues.append(.error("Pipeline has no nodes"))
        }

        var seenNodeIDs: Set<String> = []
        var nodeIDs: Set<String> = []
        for node in nodes {
            nodeIDs.insert(node.id)
            if !Self.isValidSlug(node.id) {
                issues.append(.error("Node id \"\(node.id)\" must match [a-z0-9-]+", nodeID: node.id))
            }
            if seenNodeIDs.contains(node.id) {
                issues.append(.error("Duplicate node id \"\(node.id)\"", nodeID: node.id))
            }
            seenNodeIDs.insert(node.id)
            if node.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.error("Node \"\(node.id)\" has an empty prompt", nodeID: node.id))
            }
            if node.agent != .claude {
                issues.append(.error(
                    "Node \"\(node.id)\": agent \"\(node.agent.rawValue)\" is not supported in v1 (claude only)",
                    nodeID: node.id
                ))
            }
            if node.mode == .headless, node.permissionMode == .plan {
                issues.append(.error(
                    "Node \"\(node.id)\": headless mode cannot use permissionMode \"plan\" " +
                        "(plan mode blocks the deliverable write + handoff)",
                    nodeID: node.id
                ))
            }
        }

        if entry.isEmpty {
            issues.append(.error("Pipeline has no entry node"))
        } else if !nodeIDs.contains(entry) {
            issues.append(.error("Entry node \"\(entry)\" is not a declared node"))
        }

        // Fan-out is legal: multiple edges may share a `(from, on)` pair
        // as long as they route to different targets. An exactly
        // identical `(from, on, to)` triple twice is meaningless, so
        // that's what's actually rejected.
        var seenEdgeKeys: Set<String> = []
        for (index, edge) in edges.enumerated() {
            if !nodeIDs.contains(edge.from) {
                issues.append(.error("Edge #\(index): unknown source node \"\(edge.from)\"", edgeIndex: index))
            }
            if !nodeIDs.contains(edge.to) {
                issues.append(.error("Edge #\(index): unknown target node \"\(edge.to)\"", edgeIndex: index))
            }
            if seenEdgeKeys.contains(edge.identityKey) {
                issues.append(.error(
                    "Duplicate edge (\(edge.from) --\(edge.on.rawValue)--> \(edge.to))",
                    edgeIndex: index
                ))
            }
            seenEdgeKeys.insert(edge.identityKey)
            if let max = edge.maxTraversals, max < 1 {
                issues.append(.error("Edge #\(index): maxTraversals must be >= 1", edgeIndex: index))
            }
        }

        // Unreachable nodes (warning only): BFS forward from entry.
        if nodeIDs.contains(entry) {
            var reachable: Set<String> = [entry]
            var frontier = [entry]
            while !frontier.isEmpty {
                var next: [String] = []
                for id in frontier {
                    for edge in edges where edge.from == id && !reachable.contains(edge.to) {
                        reachable.insert(edge.to)
                        next.append(edge.to)
                    }
                }
                frontier = next
            }
            for node in nodes where !reachable.contains(node.id) {
                issues.append(.warning("Node \"\(node.id)\" is unreachable from entry \"\(entry)\"", nodeID: node.id))
            }
        }

        return issues
    }

    var hasErrors: Bool {
        validate().contains { $0.severity == .error }
    }
}

private extension Character {
    var isLowercaseLetter: Bool {
        isASCII && isLetter && isLowercase
    }
}
