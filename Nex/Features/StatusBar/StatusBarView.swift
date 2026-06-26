import ComposableArchitecture
import SwiftUI

/// Cross-workspace agent counts shown in the bottom status bar.
struct ChromeStatusSummary: Equatable {
    var running = 0
    var waiting = 0
    var done = 0
}

/// Bottom status bar: focused-pane context (cwd · branch · agent · elapsed)
/// on the left, global agent counts + a clock on the right.
///
/// A distinct child view that reads the store directly inside
/// `WithPerceptionTracking`, so its counts and elapsed time update in
/// Release builds (where the outer tracking is a no-op). The 1-second tick
/// is a view-layer `TimelineView` and never dispatches a reducer action,
/// so it can't thrash persistence/effects.
///
/// The mockup's centre `ACCEPT-EDITS` mode pill is intentionally absent:
/// that is Claude Code's own permission mode, which Nex cannot read.
struct StatusBarView: View {
    let store: StoreOf<AppReducer>
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        WithPerceptionTracking {
            let summary = store.chromeStatusSummary
            let pane = store.activeWorkspace?.focusedPane
            HStack(spacing: 10) {
                leftSection(pane)
                Spacer(minLength: 8)
                rightSection(summary)
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(theme.footerBackground)
            .overlay(alignment: .top) { theme.divider.frame(height: 1) }
        }
    }

    @ViewBuilder
    private func leftSection(_ pane: Pane?) -> some View {
        if let pane {
            HStack(spacing: 8) {
                Text(chromeHomeAbbreviated(pane.workingDirectory))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let branch = pane.gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch)
                    }
                    .foregroundStyle(theme.textTertiary)
                }

                if pane.agentSessionID != nil {
                    agentSection(pane)
                }
            }
            // Guard against a pathologically long branch/agent label pushing
            // the right-hand counts off-screen on a narrow window.
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func agentSection(_ pane: Pane) -> some View {
        switch pane.status {
        case .running:
            HStack(spacing: 4) {
                Text("claude").foregroundStyle(theme.activeAgent)
                // Elapsed only when we have a start time (nil after a
                // relaunch-restored `.running` pane until the agent
                // re-emits a start).
                if let started = pane.agentStartedAt {
                    Text("·").foregroundStyle(theme.textTertiary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(chromeElapsedLabel(from: started, to: context.date))
                            .monospacedDigit()
                            .foregroundStyle(theme.activeAgent)
                    }
                }
            }
        case .waitingForInput:
            Text("awaiting input").foregroundStyle(theme.statusWaiting)
        case .idle:
            EmptyView()
        }
    }

    private func rightSection(_ summary: ChromeStatusSummary) -> some View {
        HStack(spacing: 8) {
            countItem(color: theme.statusRunning, value: summary.running, label: "running")
            separator
            countItem(color: theme.statusWaiting, value: summary.waiting, label: "waiting")
            separator
            countItem(color: theme.statusDone, value: summary.done, label: "done")
            separator
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func countItem(color: Color, value: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value) \(label)")
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(theme.textTertiary)
    }
}
