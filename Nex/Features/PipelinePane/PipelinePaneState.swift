import CoreGraphics
import Foundation

/// Which pipeline node/edge is selected on the canvas (mutually
/// exclusive with each other; the inspector reads whichever is set).
enum PipelineCanvasSelection: Equatable {
    case node(String)
    case edge(Int)
    case none
}

/// Sidecar state for a `.pipeline` pane. Lives on
/// `WorkspaceFeature.State` in the `pipelinePanes: [UUID:
/// PipelinePaneState]` dictionary, keyed by pane id — mirrors the
/// `webPanes` sidecar so consumers that don't care about pipeline
/// internals don't have to learn the type.
struct PipelinePaneState: Equatable {
    /// nil = library view (no pipeline open yet).
    var pipelineName: String?
    var document: PipelineDefinition?
    var mode: Mode = .edit
    var selection: PipelineCanvasSelection = .none
    /// Value-snapshot undo/redo, capped at 50 entries each per the plan.
    var undoStack: [PipelineDefinition] = []
    var redoStack: [PipelineDefinition] = []
    var isDirty: Bool = false
    /// In-memory only — never persisted (matches the `zoom`/`pan` note
    /// in the sidecar persistence checklist).
    var zoom: CGFloat = 1.0
    var pan: CGPoint = .zero
    /// Validation issues for the currently-open document, recomputed on
    /// every edit for the editor's live error display.
    var validationIssues: [PipelineValidationIssue] = []
    /// Cached listing of `~/.config/nex/pipelines` for the library view.
    /// Refreshed via `.pipelineLibraryRequested`.
    var libraryNames: [String] = []

    enum Mode: Equatable {
        case edit
        case monitor(runID: UUID)
    }

    static let undoStackLimit = 50

    init(
        pipelineName: String? = nil,
        document: PipelineDefinition? = nil,
        mode: Mode = .edit,
        selection: PipelineCanvasSelection = .none,
        undoStack: [PipelineDefinition] = [],
        redoStack: [PipelineDefinition] = [],
        isDirty: Bool = false,
        zoom: CGFloat = 1.0,
        pan: CGPoint = .zero,
        validationIssues: [PipelineValidationIssue] = [],
        libraryNames: [String] = []
    ) {
        self.pipelineName = pipelineName
        self.document = document
        self.mode = mode
        self.selection = selection
        self.undoStack = undoStack
        self.redoStack = redoStack
        self.isDirty = isDirty
        self.zoom = zoom
        self.pan = pan
        self.validationIssues = validationIssues
        self.libraryNames = libraryNames
    }
}

/// A structural edit applied to the pane's open document. Selection
/// clamping (e.g. deleting the selected node) is handled alongside the
/// document mutation in `PipelinePaneState.apply(_:)`.
enum PipelineEdit: Equatable {
    case moveNode(id: String, to: CGPoint)
    /// Drag-to-bend an edge's curve (issue #282 round 3) — `edgeKey` is
    /// `PipelineEdge.identityKey`, `offset` is the new saved control-point
    /// offset (document units). Purely a layout change, like `moveNode`
    /// — never blocked in monitor mode.
    case moveEdgeHandle(edgeKey: String, offset: CGPoint)
    case addNode(at: CGPoint)
    case deleteNode(id: String)
    case deleteEdge(index: Int)
    case addEdge(from: String, on: PipelineNodeOutcome, to: String)
    case setEntry(String)
    case renamePipeline(String)
    case updateNodeName(id: String, name: String)
    case updateNodePrompt(id: String, prompt: String)
    case updateNodeModel(id: String, model: String)
    case updateNodeMode(id: String, mode: PipelineNodeMode)
    case updateNodePermissionMode(id: String, mode: PipelinePermissionMode)
    case updateNodeAgent(id: String, agent: AgentKind)
    case updateEdgeOutcome(index: Int, outcome: PipelineNodeOutcome)
    case updateEdgeMaxTraversals(index: Int, value: Int?)
    case updateEdgeRequiresApproval(index: Int, value: Bool)
}

extension PipelinePaneState {
    /// Applies `edit` to the open document, adjusting `selection` when
    /// the edited item is deleted. Returns `false` (no state change) for
    /// edits that would violate an invariant the editor enforces
    /// proactively — self-edge, duplicate `(from, on)`, out-of-range
    /// index — rather than merely flagging it via `validate()`.
    @discardableResult
    mutating func apply(_ edit: PipelineEdit) -> Bool {
        guard var document else { return false }
        defer { self.document = document }

        switch edit {
        case let .moveNode(id, point):
            guard document.nodes.contains(where: { $0.id == id }) else { return false }
            document.ui.nodes[id] = point

        case let .moveEdgeHandle(edgeKey, offset):
            guard document.edges.contains(where: { $0.identityKey == edgeKey }) else { return false }
            document.ui.edges[edgeKey] = PipelineEdgeUI(offset: offset)

        case let .addNode(point):
            let existing = Set(document.nodes.map(\.id))
            var newID = "node"
            var suffix = 1
            while existing.contains(newID) {
                newID = "node-\(suffix)"
                suffix += 1
            }
            document.nodes.append(PipelineNode(id: newID, prompt: ""))
            document.ui.nodes[newID] = point
            if document.entry.isEmpty {
                document.entry = newID
            }
            selection = .node(newID)

        case let .deleteNode(id):
            guard document.nodes.contains(where: { $0.id == id }) else { return false }
            document.nodes.removeAll { $0.id == id }
            document.edges.removeAll { $0.from == id || $0.to == id }
            document.ui.nodes.removeValue(forKey: id)
            if document.entry == id {
                document.entry = document.nodes.first?.id ?? ""
            }
            if selection == .node(id) {
                selection = .none
            }

        case let .deleteEdge(index):
            guard document.edges.indices.contains(index) else { return false }
            document.edges.remove(at: index)
            selection = .none

        case let .addEdge(from, on, to):
            guard from != to else { return false }
            guard document.nodes.contains(where: { $0.id == from }),
                  document.nodes.contains(where: { $0.id == to })
            else { return false }
            let newEdge = PipelineEdge(from: from, on: on, to: to)
            // Fan-out (multiple edges off the same (from, on)) is legal;
            // only an exactly identical (from, on, to) triple is rejected.
            guard !document.edges.contains(where: { $0.identityKey == newEdge.identityKey }) else { return false }
            document.edges.append(newEdge)

        case let .setEntry(id):
            guard document.nodes.contains(where: { $0.id == id }) else { return false }
            document.entry = id

        case let .renamePipeline(name):
            document.name = name

        case let .updateNodeName(id, name):
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return false }
            document.nodes[index].name = name

        case let .updateNodePrompt(id, prompt):
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return false }
            document.nodes[index].prompt = prompt

        case let .updateNodeModel(id, model):
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return false }
            document.nodes[index].model = model.isEmpty ? nil : model

        case let .updateNodeMode(id, mode):
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return false }
            document.nodes[index].mode = mode

        case let .updateNodePermissionMode(id, mode):
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return false }
            document.nodes[index].permissionMode = mode

        case let .updateNodeAgent(id, agent):
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return false }
            document.nodes[index].agent = agent

        case let .updateEdgeOutcome(index, outcome):
            guard document.edges.indices.contains(index) else { return false }
            document.edges[index].on = outcome

        case let .updateEdgeMaxTraversals(index, value):
            guard document.edges.indices.contains(index) else { return false }
            document.edges[index].maxTraversals = value

        case let .updateEdgeRequiresApproval(index, value):
            guard document.edges.indices.contains(index) else { return false }
            document.edges[index].requiresApproval = value
        }
        return true
    }
}
