import ComposableArchitecture
import Foundation

// MARK: - Templating

/// A node's latest completed attempt, as surfaced to downstream prompts
/// via `{{nodes.<id>.output}}` / `{{nodes.<id>.summary}}`. Only the path
/// + summary travel — never the artifact contents (context hygiene, per
/// issue section 2).
struct PipelineNodeArtifact: Equatable {
    var outputPath: String
    var summary: String
}

/// The routing node's feedback on a bounce-back, surfaced via
/// `{{feedback}}`. Nil on a node's first visit.
struct PipelineFeedback: Equatable {
    var summary: String
    var artifactPath: String
}

struct PipelineTemplateContext: Equatable {
    var inputs: [String: String]
    var nodeArtifacts: [String: PipelineNodeArtifact]
    var runID: String
    var runDir: String
    var feedback: PipelineFeedback?

    init(
        inputs: [String: String] = [:],
        nodeArtifacts: [String: PipelineNodeArtifact] = [:],
        runID: String,
        runDir: String,
        feedback: PipelineFeedback? = nil
    ) {
        self.inputs = inputs
        self.nodeArtifacts = nodeArtifacts
        self.runID = runID
        self.runDir = runDir
        self.feedback = feedback
    }
}

struct PipelineRenderedPrompt: Equatable {
    var text: String
    /// One entry per unresolved `{{...}}` placeholder — logged, never
    /// fatal (issue section 2: "Unresolved placeholders render empty +
    /// record a warning").
    var warnings: [String]
}

// MARK: - Routing

/// The outcome of evaluating one handoff against `PipelineEdge`s.
enum PipelineTransition: Equatable {
    /// Proceed to `to`. `requiresApproval` mirrors the traversed edge;
    /// `edgeKey` is `PipelineRun.traversalKey(from:on:)` for the caller
    /// to increment `edgeTraversals`.
    case route(to: String, requiresApproval: Bool, edgeKey: String)
    case completed
    case failed(reason: String)
    /// A declared `maxTraversals` would be exceeded by taking this edge.
    case loopExhausted(edgeKey: String)
}

// MARK: - Launch command safety

enum PipelineLaunchError: Error, Equatable {
    case unsafeModel(String)
    case unsafeEnvValue(key: String)
}

/// Machine-readable outcome record written to `result.json` in a node
/// attempt's directory (issue section 2).
struct PipelineNodeResult: Codable, Equatable {
    var nodeID: String
    var attempt: Int
    var outcome: PipelineNodeOutcome
    var summary: String?
    var completedAt: Date
}

// MARK: - Pure logic (directly unit-testable, no DI needed)

/// All the file-free, deterministic pipeline logic: template rendering,
/// the handoff appendix, edge/loop-guard routing, and launch-command
/// composition. Exposed both as plain static functions (for direct unit
/// tests — `PipelineTemplateTests`) and wrapped in the `PipelineEngine`
/// dependency below (for reducer tests that want to fake the engine).
enum PipelineEngineLogic {
    private static let placeholderPattern = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}"#
    )

    /// The mandatory appendix every node's prompt gets — the sole
    /// machine-readable completion signal in v1 (issue section 3).
    static let handoffAppendix = """
    ## Handoff protocol

    Write your deliverable to `output.md` in this attempt's directory, then finish by running exactly one of:

        nex pipeline done --summary "..."
        nex pipeline fail --summary "..."
        nex pipeline partial --summary "..."

    If the command errors, retry every 30 seconds — the app may not be reachable yet.
    """

    static func renderPrompt(node: PipelineNode, context: PipelineTemplateContext) -> PipelineRenderedPrompt {
        let source = node.prompt
        let nsrange = NSRange(source.startIndex ..< source.endIndex, in: source)
        var rendered = ""
        var warnings: [String] = []
        var lastEnd = source.startIndex

        for match in placeholderPattern.matches(in: source, range: nsrange) {
            guard let matchRange = Range(match.range, in: source),
                  let pathRange = Range(match.range(at: 1), in: source) else { continue }
            rendered += source[lastEnd ..< matchRange.lowerBound]
            let path = String(source[pathRange])
            if let value = resolve(path: path, context: context) {
                rendered += value
            } else {
                warnings.append("unresolved placeholder {{\(path)}}")
            }
            lastEnd = matchRange.upperBound
        }
        rendered += source[lastEnd...]

        let text = [rendered, contextSection(context: context), handoffAppendix]
            .joined(separator: "\n\n")
        return PipelineRenderedPrompt(text: text, warnings: warnings)
    }

    /// Resolves one dotted path. Returns nil for anything unresolvable
    /// (unknown namespace, unknown node id, wrong arity) EXCEPT
    /// `{{feedback}}` on a node's first visit, which resolves to the
    /// empty string by design (not a warning).
    private static func resolve(path: String, context: PipelineTemplateContext) -> String? {
        let parts = path.split(separator: ".").map(String.init)
        switch parts.first {
        case "inputs":
            guard parts.count == 2 else { return nil }
            return context.inputs[parts[1]]
        case "nodes":
            guard parts.count == 3, let artifact = context.nodeArtifacts[parts[1]] else { return nil }
            switch parts[2] {
            case "output": return artifact.outputPath
            case "summary": return artifact.summary
            default: return nil
            }
        case "run":
            guard parts.count == 2 else { return nil }
            switch parts[1] {
            case "id": return context.runID
            case "dir": return context.runDir
            default: return nil
            }
        case "feedback":
            guard parts.count == 1 else { return nil }
            guard let feedback = context.feedback else { return "" }
            return "\(feedback.summary)\n\nSee: \(feedback.artifactPath)"
        default:
            return nil
        }
    }

    private static func contextSection(context: PipelineTemplateContext) -> String {
        var lines = [
            "## Pipeline context",
            "",
            "Run: \(context.runID)",
            "Run directory: \(context.runDir)"
        ]
        if !context.nodeArtifacts.isEmpty {
            lines.append("Upstream artifacts:")
            for nodeID in context.nodeArtifacts.keys.sorted() {
                lines.append("- \(nodeID): \(context.nodeArtifacts[nodeID]!.outputPath)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func evaluateTransition(
        definition: PipelineDefinition,
        from: String,
        outcome: PipelineNodeOutcome,
        traversals: [String: Int]
    ) -> PipelineTransition {
        func checked(_ edge: PipelineEdge) -> PipelineTransition {
            let key = PipelineRun.traversalKey(from: edge.from, on: edge.on)
            if let max = edge.maxTraversals, (traversals[key] ?? 0) >= max {
                return .loopExhausted(edgeKey: key)
            }
            return .route(to: edge.to, requiresApproval: edge.requiresApproval, edgeKey: key)
        }

        if let edge = definition.edges.first(where: { $0.from == from && $0.on == outcome }) {
            return checked(edge)
        }
        // partial with no partial edge falls back to the done edge.
        if outcome == .partial, let doneEdge = definition.edges.first(where: { $0.from == from && $0.on == .done }) {
            return checked(doneEdge)
        }
        switch outcome {
        case .done, .partial:
            return .completed
        case .fail:
            return .failed(reason: "node \"\(from)\" reported fail with no matching fail edge")
        }
    }

    /// Composes the shell command a node's launch types into its pane.
    /// Every piece of untrusted input is validated or quoted before it
    /// touches the string (issue section 7, pitfall 3): `model` must
    /// match `[A-Za-z0-9._-]+`, and `env` values are single-quoted with
    /// embedded-quote escaping and rejected outright if they contain
    /// newlines or other control characters. The handoff allowlist
    /// (`Bash(nex pipeline:*)`, `Write(<runDir>/**)`) is always injected
    /// — without it a headless node could never write its deliverable
    /// or call `nex pipeline done`.
    static func composeLaunchCommand(
        node: PipelineNode,
        runID: String,
        attempt: Int,
        runDir: String,
        promptPath: String
    ) -> Result<String, PipelineLaunchError> {
        if let model = node.model, !model.isEmpty {
            guard isSafeModel(model) else { return .failure(.unsafeModel(model)) }
        }

        var assignments = [
            "NEX_PIPELINE_RUN=\(shellQuote(runID))",
            "NEX_PIPELINE_NODE=\(shellQuote(node.id))",
            "NEX_PIPELINE_ATTEMPT=\(attempt)"
        ]
        for key in node.env.keys.sorted() {
            let value = node.env[key] ?? ""
            guard !containsControlCharacters(value) else {
                return .failure(.unsafeEnvValue(key: key))
            }
            assignments.append("\(key)=\(shellQuote(value))")
        }

        var command = assignments.joined(separator: " ") + " claude"
        if node.mode == .headless {
            command += " -p"
        }
        command += " --permission-mode \(node.permissionMode.rawValue)"
        if let model = node.model, !model.isEmpty {
            command += " --model \(model)"
        }
        command += " --allowedTools \"Bash(nex pipeline:*)\" \"Write(\(runDir)/**)\""
        if node.mode == .headless {
            command += " < \(shellQuote(promptPath))"
        }
        return .success(command)
    }

    private static func isSafeModel(_ model: String) -> Bool {
        !model.isEmpty && model.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - File work

    static func prepareAttemptDir(runDir: String, nodeID: String, attempt: Int) throws -> String {
        let dir = URL(fileURLWithPath: runDir)
            .appendingPathComponent("nodes")
            .appendingPathComponent(nodeID)
            .appendingPathComponent("attempt-\(attempt)")
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeResultJSON(attemptDir: String, result: PipelineNodeResult) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let path = (attemptDir as NSString).appendingPathComponent("result.json")
        try data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - TCA Dependency

/// Struct-of-closures wrapper around `PipelineEngineLogic` (GraftService
/// style) so `PipelinesFeature` reducer tests can inject a fake engine —
/// e.g. to force a specific `PipelineTransition` without constructing a
/// full graph, or to point file work at a scratch directory.
struct PipelineEngine: Sendable {
    var prepareAttemptDir: @Sendable (_ runDir: String, _ nodeID: String, _ attempt: Int) throws -> String
    var writeResultJSON: @Sendable (_ attemptDir: String, _ result: PipelineNodeResult) throws -> Void
    var evaluateTransition: @Sendable (
        _ definition: PipelineDefinition,
        _ from: String,
        _ outcome: PipelineNodeOutcome,
        _ traversals: [String: Int]
    ) -> PipelineTransition
    var renderPrompt: @Sendable (_ node: PipelineNode, _ context: PipelineTemplateContext) -> PipelineRenderedPrompt
    var composeLaunchCommand: @Sendable (
        _ node: PipelineNode,
        _ runID: String,
        _ attempt: Int,
        _ runDir: String,
        _ promptPath: String
    ) -> Result<String, PipelineLaunchError>
}

extension PipelineEngine: DependencyKey {
    static let liveValue = PipelineEngine(
        prepareAttemptDir: { try PipelineEngineLogic.prepareAttemptDir(runDir: $0, nodeID: $1, attempt: $2) },
        writeResultJSON: { try PipelineEngineLogic.writeResultJSON(attemptDir: $0, result: $1) },
        evaluateTransition: { PipelineEngineLogic.evaluateTransition(definition: $0, from: $1, outcome: $2, traversals: $3) },
        renderPrompt: { PipelineEngineLogic.renderPrompt(node: $0, context: $1) },
        composeLaunchCommand: {
            PipelineEngineLogic.composeLaunchCommand(node: $0, runID: $1, attempt: $2, runDir: $3, promptPath: $4)
        }
    )

    /// Every closure above is pure/deterministic (file work is
    /// parameterized by a caller-supplied path), so tests get the same
    /// real behaviour by default and override individual closures only
    /// when a scenario needs to fake routing or a scratch directory.
    static let testValue = liveValue
}

extension DependencyValues {
    var pipelineEngine: PipelineEngine {
        get { self[PipelineEngine.self] }
        set { self[PipelineEngine.self] = newValue }
    }
}
