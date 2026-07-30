import SwiftUI

/// Top bar shown when a pipeline pane is in `.monitor(runID)` mode:
/// run name, elapsed time, a done/total node-attempt tally, and the
/// Cancel / Back-to-Edit actions. Structural editing is unavailable in
/// this mode — only position drags on the canvas below remain live.
struct PipelineRunHUD: View {
    let run: PipelineRun
    let onCancel: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onResume: () -> Void
    let onBackToEdit: () -> Void

    @Environment(\.chromeTheme) private var chromeTheme

    private var elapsedText: String {
        let end = run.completedAt ?? Date()
        let seconds = max(0, Int(end.timeIntervalSince(run.createdAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var doneCount: Int {
        run.nodeRuns.count { $0.status == .done || $0.status == .partial }
    }

    private var statusColor: Color {
        switch run.status {
        case .completed: chromeTheme.statusRunning
        case .failed, .cancelled: .red
        case .awaitingApproval, .paused: chromeTheme.statusWaiting
        case .launching, .running: chromeTheme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(run.definitionSnapshot.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chromeTheme.textPrimary)
                Text(run.status.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                Text("· \(elapsedText)")
                    .font(.system(size: 11))
                    .foregroundStyle(chromeTheme.textSecondary)
                Text("· \(doneCount)/\(run.nodeRuns.map(\.nodeID).uniqued().count) nodes")
                    .font(.system(size: 11))
                    .foregroundStyle(chromeTheme.textSecondary)

                Spacer()

                if run.status == .awaitingApproval {
                    Button("Deny", action: onDeny)
                        .font(.system(size: 11))
                    Button("Approve", action: onApprove)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chromeTheme.accent)
                } else if run.status == .paused {
                    Button("Resume", action: onResume)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chromeTheme.accent)
                }
                if !run.status.isTerminal {
                    Button("Cancel", action: onCancel)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                if run.status.isTerminal {
                    Button("Back to Edit", action: onBackToEdit)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.plain)

            if let detail = run.statusDetail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(chromeTheme.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(chromeTheme.headerBackground)
    }
}

extension Sequence where Element: Hashable {
    /// Order-preserving de-dup — used for the HUD's "done/total nodes"
    /// tally (distinct node ids, not attempts).
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
