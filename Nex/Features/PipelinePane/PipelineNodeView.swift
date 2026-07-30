import SwiftUI

/// Live run status for one node, as surfaced on its canvas card in
/// monitor mode. `nil` (not passed) = edit mode, no overlay at all.
struct PipelineNodeRunDisplay: Equatable {
    var status: PipelineNodeRunStatus
    var attempt: Int
    var isCurrent: Bool
}

/// One node card on the pipeline canvas. Size is fixed
/// (`PipelineCanvasGeometry.nodeSize`) so geometry/hit-testing and
/// rendering agree on node bounds. `Equatable` (comparing only the
/// fields that affect rendering) so a status tick from `pipelineFanOutWatch`-
/// driven state re-renders exactly the one node it touches, not the whole
/// canvas — the Release-build single-node re-render isolation the design
/// doc calls for.
struct PipelineNodeView: View, Equatable {
    let node: PipelineNode
    let isEntry: Bool
    let isSelected: Bool
    /// True only in monitor mode — distinguishes "edit mode, no run
    /// concept at all" from "monitor mode, this node hasn't been
    /// reached yet" (both have `run == nil`, but only the latter dims).
    var isMonitorMode: Bool = false
    var run: PipelineNodeRunDisplay?
    @Environment(\.chromeTheme) private var chromeTheme

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node && lhs.isEntry == rhs.isEntry && lhs.isSelected == rhs.isSelected
            && lhs.isMonitorMode == rhs.isMonitorMode && lhs.run == rhs.run
    }

    private var statusColor: Color? {
        guard let run else { return nil }
        switch run.status {
        case .done, .partial: return .green
        case .failed, .timedOut: return .red
        case .stalled: return .orange
        case .awaitingHuman: return chromeTheme.statusWaiting
        case .running: return chromeTheme.accent
        case .spawning, .interrupted: return chromeTheme.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if isEntry {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(chromeTheme.accent)
                }
                Text(node.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chromeTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let run, run.attempt > 1 {
                    Text("×\(run.attempt)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(chromeTheme.textTertiary))
                }
            }
            Text(node.mode == .headless ? "headless" : "interactive")
                .font(.system(size: 10))
                .foregroundStyle(chromeTheme.textSecondary)
            Text(node.permissionMode.rawValue)
                .font(.system(size: 10))
                .foregroundStyle(chromeTheme.textTertiary)
                .lineLimit(1)
            if let run {
                HStack(spacing: 3) {
                    if let statusColor {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                    }
                    Text(run.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(statusColor ?? chromeTheme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(
            width: PipelineCanvasGeometry.nodeSize.width,
            height: PipelineCanvasGeometry.nodeSize.height,
            alignment: .topLeading
        )
        .background(chromeTheme.surfaceBackground)
        .opacity(isPending ? 0.5 : 1.0)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    run?.isCurrent == true ? chromeTheme.accent : (isSelected ? chromeTheme.selectionStroke : chromeTheme.divider),
                    lineWidth: run?.isCurrent == true ? 3 : (isSelected ? 2 : 1)
                )
        )
        .shadow(color: .black.opacity(run?.isCurrent == true ? 0.25 : 0.08), radius: run?.isCurrent == true ? 6 : 2, y: 1)
    }

    /// Pending = in monitor mode, the run hasn't reached this node yet
    /// at all (no NodeRun exists for it). Dimmed per the monitor-mode
    /// spec — never applies in edit mode.
    private var isPending: Bool { isMonitorMode && run == nil }
}
