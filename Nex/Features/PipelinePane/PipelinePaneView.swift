import SwiftUI

/// Root view for a `.pipeline` pane. Shows the library picker when no
/// document is open, otherwise the canvas + inspector editor (edit mode)
/// or the canvas + `PipelineRunHUD` (monitor mode). Native SwiftUI
/// throughout (no WKWebView) per the pipelines design doc.
struct PipelinePaneView: View {
    let pipelineState: PipelinePaneState?
    /// The live run backing `pipelineState.mode`'s `.monitor(runID)`, if
    /// any — nil in edit mode, or if the run hasn't loaded yet.
    let activeRun: PipelineRun?
    let onOpenDefinition: (String) -> Void
    let onCreateDefinition: () -> Void
    let onDeleteDefinition: (String) -> Void
    let onCloseDocument: () -> Void
    let onEdit: (PipelineEdit) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSelect: (PipelineCanvasSelection) -> Void
    let onViewportChange: (CGFloat, CGPoint) -> Void
    var onRun: ([String: String]) -> Void = { _ in }
    var onCancelRun: () -> Void = {}
    var onApproveRun: () -> Void = {}
    var onDenyRun: () -> Void = {}
    var onResumeRun: () -> Void = {}
    var onBackToEdit: () -> Void = {}
    var onJumpToNode: (String) -> Void = { _ in }

    @Environment(\.chromeTheme) private var chromeTheme
    @State private var isRunSheetPresented = false

    var body: some View {
        if let document = pipelineState?.document {
            editor(document: document, pipelineState: pipelineState!)
                .sheet(isPresented: $isRunSheetPresented) {
                    RunPipelineSheet(
                        definition: document,
                        onRun: { inputs in
                            isRunSheetPresented = false
                            onRun(inputs)
                        },
                        onCancel: { isRunSheetPresented = false }
                    )
                }
        } else {
            PipelineLibraryView(
                names: pipelineState?.libraryNames ?? [],
                loadError: pipelineState?.validationIssues.first(where: { $0.message.hasPrefix("Save failed") == false })?.message,
                onOpen: onOpenDefinition,
                onCreate: onCreateDefinition,
                onDelete: onDeleteDefinition
            )
        }
    }

    private var isMonitorMode: Bool {
        if case .monitor = pipelineState?.mode {
            return true
        }
        return false
    }

    /// Latest NodeRun per node id (highest attempt), mapped to the
    /// canvas card's display struct. The run's `currentNodeRunID` marks
    /// which single card gets the focus glow.
    private func nodeStatuses(for run: PipelineRun) -> [String: PipelineNodeRunDisplay] {
        var latestByNode: [String: PipelineNodeRun] = [:]
        for nodeRun in run.nodeRuns {
            if let existing = latestByNode[nodeRun.nodeID], existing.attempt >= nodeRun.attempt {
                continue
            }
            latestByNode[nodeRun.nodeID] = nodeRun
        }
        return latestByNode.mapValues {
            PipelineNodeRunDisplay(status: $0.status, attempt: $0.attempt, isCurrent: $0.id == run.currentNodeRunID)
        }
    }

    @ViewBuilder
    private func editor(document: PipelineDefinition, pipelineState: PipelinePaneState) -> some View {
        let positions = PipelineAutoLayout.reconciledPositions(for: document)
        let errorCount = pipelineState.validationIssues.filter { $0.severity == .error }.count
        let warningCount = pipelineState.validationIssues.filter { $0.severity == .warning }.count

        VStack(spacing: 0) {
            if isMonitorMode, let activeRun {
                PipelineRunHUD(
                    run: activeRun,
                    onCancel: onCancelRun,
                    onApprove: onApproveRun,
                    onDeny: onDenyRun,
                    onResume: onResumeRun,
                    onBackToEdit: onBackToEdit
                )
            } else {
                HStack(spacing: 12) {
                    Button(action: onCloseDocument) {
                        Label("Library", systemImage: "chevron.left")
                    }
                    .font(.system(size: 12))

                    Text(document.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(chromeTheme.textPrimary)

                    if pipelineState.isDirty {
                        Circle().fill(chromeTheme.statusWaiting).frame(width: 6, height: 6)
                            .help("Unsaved changes (autosaving...)")
                    }

                    Spacer()

                    if errorCount > 0 {
                        Label("\(errorCount)", systemImage: "xmark.octagon.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .help(pipelineState.validationIssues.filter { $0.severity == .error }.map(\.message).joined(separator: "\n"))
                    }
                    if warningCount > 0 {
                        Label("\(warningCount)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(chromeTheme.statusWaiting)
                            .help(pipelineState.validationIssues.filter { $0.severity == .warning }.map(\.message).joined(separator: "\n"))
                    }

                    Button {
                        if document.inputs.isEmpty {
                            onRun([:])
                        } else {
                            isRunSheetPresented = true
                        }
                    } label: { Image(systemName: "play.fill") }
                        .disabled(errorCount > 0)
                        .help(errorCount > 0 ? "Fix validation errors before running" : "Run pipeline")

                    Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                        .disabled(pipelineState.undoStack.isEmpty)
                        .help("Undo")
                    Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                        .disabled(pipelineState.redoStack.isEmpty)
                        .help("Redo")
                    Button {
                        onViewportChange(max(pipelineState.zoom - 0.1, PipelineCanvasGeometry.zoomRange.lowerBound), pipelineState.pan)
                    } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out")
                    Button {
                        onViewportChange(1.0, .zero)
                    } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("Fit / reset zoom")
                    Button {
                        onViewportChange(min(pipelineState.zoom + 0.1, PipelineCanvasGeometry.zoomRange.upperBound), pipelineState.pan)
                    } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(chromeTheme.headerBackground)
            }

            HStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    PipelineCanvasView(
                        document: document,
                        positions: positions,
                        selection: pipelineState.selection,
                        zoom: pipelineState.zoom,
                        pan: pipelineState.pan,
                        onSelect: onSelect,
                        onMoveNode: { id, point in onEdit(.moveNode(id: id, to: point)) },
                        onAddNode: { point in onEdit(.addNode(at: point)) },
                        isMonitorMode: isMonitorMode,
                        nodeStatuses: activeRun.map(nodeStatuses) ?? [:],
                        onJumpToNode: onJumpToNode
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isMonitorMode, pipelineState.selection != .none {
                    Divider()
                    PipelineInspectorView(
                        document: document,
                        selection: pipelineState.selection,
                        onEdit: onEdit,
                        onDeleteSelection: {
                            switch pipelineState.selection {
                            case let .node(id): onEdit(.deleteNode(id: id))
                            case let .edge(index): onEdit(.deleteEdge(index: index))
                            case .none: break
                            }
                        },
                        onSetEntry: { onEdit(.setEntry($0)) }
                    )
                }
            }
        }
        .background(chromeTheme.surfaceBackground)
    }
}
