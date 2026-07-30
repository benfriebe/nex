import ComposableArchitecture
import Foundation

/// Lifecycle status of a `PipelineRun`. Free-text context (which edge is
/// awaiting approval, why a run is paused, why it failed) lives in
/// `PipelineRun.statusDetail` rather than as associated values here, so
/// the pair round-trips through two plain DB columns (`status` +
/// `statusDetail`, migration `v20_pipelines`).
enum PipelineRunStatus: String, Codable, Equatable, CaseIterable {
    case launching
    case running
    case awaitingApproval
    case paused
    case completed
    case failed
    case cancelled

    /// Runs in these statuses accept a handoff and route on it.
    /// Everything else (paused, awaitingApproval, and the terminal
    /// statuses) records the handoff but holds routing — matching the
    /// issue's "handoff while paused is accepted and recorded; routing
    /// holds until resume" rule.
    var routesOnHandoff: Bool {
        self == .launching || self == .running
    }

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

/// Lifecycle status of a single `PipelineNodeRun` attempt.
enum PipelineNodeRunStatus: String, Codable, Equatable, CaseIterable {
    case spawning
    case running
    case awaitingHuman
    case done
    case failed
    case partial
    case timedOut
    case stalled
    case interrupted

    init(outcome: PipelineNodeOutcome) {
        switch outcome {
        case .done: self = .done
        case .fail: self = .failed
        case .partial: self = .partial
        }
    }

    var isTerminal: Bool {
        self == .done || self == .failed || self == .partial || self == .timedOut
    }
}

/// One attempt of one node within a run. `attempt` starts at 1 and
/// increments on bounce-back (issue section 3). `paneID` /
/// `agentSessionID` are nil until the (not-yet-implemented) spawn
/// delegate binds them in a follow-up phase.
struct PipelineNodeRun: Codable, Equatable, Identifiable {
    var id: UUID
    var nodeID: String
    var attempt: Int
    var paneID: UUID?
    var agentSessionID: String?
    var status: PipelineNodeRunStatus
    var summary: String?
    var outputPath: String?
    var warnings: [String] = []
    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID,
        nodeID: String,
        attempt: Int = 1,
        paneID: UUID? = nil,
        agentSessionID: String? = nil,
        status: PipelineNodeRunStatus = .spawning,
        summary: String? = nil,
        outputPath: String? = nil,
        warnings: [String] = [],
        startedAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.attempt = attempt
        self.paneID = paneID
        self.agentSessionID = agentSessionID
        self.status = status
        self.summary = summary
        self.outputPath = outputPath
        self.warnings = warnings
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

/// A single execution of a `PipelineDefinition`. `definitionSnapshot` is
/// frozen at launch time so a mid-run YAML edit can't corrupt routing —
/// the run always evaluates edges against the graph it started with.
struct PipelineRun: Codable, Equatable, Identifiable {
    var id: UUID
    var definitionID: String
    var definitionSnapshot: PipelineDefinition
    var status: PipelineRunStatus
    var statusDetail: String?
    var location: PipelineLocation
    /// No FK to `workspace` — a run's history must survive the workspace
    /// being deleted (issue section 5).
    var workspaceID: UUID?
    var worktreePath: String?
    var runDir: String
    var inputs: [String: String]
    var nodeRuns: IdentifiedArrayOf<PipelineNodeRun> = []
    var currentNodeRunID: UUID?
    /// Traversal counts keyed by `PipelineRun.traversalKey(from:on:)`
    /// ("<from>|<on>"), not `PipelineEdge.Key` directly — a non-String/Int
    /// dictionary key would encode as a flat array under `JSONEncoder`
    /// instead of an object, which is a worse fit for the `edgeTraversalsJSON`
    /// DB column.
    var edgeTraversals: [String: Int] = [:]
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID,
        definitionID: String,
        definitionSnapshot: PipelineDefinition,
        status: PipelineRunStatus,
        statusDetail: String? = nil,
        location: PipelineLocation,
        workspaceID: UUID? = nil,
        worktreePath: String? = nil,
        runDir: String,
        inputs: [String: String] = [:],
        nodeRuns: IdentifiedArrayOf<PipelineNodeRun> = [],
        currentNodeRunID: UUID? = nil,
        edgeTraversals: [String: Int] = [:],
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.definitionID = definitionID
        self.definitionSnapshot = definitionSnapshot
        self.status = status
        self.statusDetail = statusDetail
        self.location = location
        self.workspaceID = workspaceID
        self.worktreePath = worktreePath
        self.runDir = runDir
        self.inputs = inputs
        self.nodeRuns = nodeRuns
        self.currentNodeRunID = currentNodeRunID
        self.edgeTraversals = edgeTraversals
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    static func traversalKey(from: String, on: PipelineNodeOutcome) -> String {
        "\(from)|\(on.rawValue)"
    }

    /// `~/Library/Application Support/Nex/pipeline-runs/<runID>/` — the
    /// app's existing data-dir convention (mirrors `DatabaseService`'s
    /// `nex.db` path). Node attempt directories are created under this
    /// by `PipelineEngine.prepareAttemptDir` once the spawn delegate
    /// lands (phases 6-7).
    static func runDirectory(for runID: UUID) -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Nex", isDirectory: true)
        return appSupport
            .appendingPathComponent("pipeline-runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .path
    }

    /// Most recent 50 terminal runs are kept; older ones are pruned
    /// (issue section 5). Non-terminal runs are never pruned regardless
    /// of age.
    static func pruned(_ runs: IdentifiedArrayOf<PipelineRun>, keepingTerminal limit: Int = 50) -> IdentifiedArrayOf<PipelineRun> {
        var active: [PipelineRun] = []
        var terminal: [PipelineRun] = []
        for run in runs {
            if run.status.isTerminal {
                terminal.append(run)
            } else {
                active.append(run)
            }
        }
        guard terminal.count > limit else { return runs }
        let keptTerminal = terminal
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
        var result = IdentifiedArrayOf<PipelineRun>()
        for run in active + Array(keptTerminal) {
            result.append(run)
        }
        return result
    }
}
