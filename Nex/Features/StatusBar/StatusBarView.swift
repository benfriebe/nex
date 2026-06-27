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
    /// View-layer system-stats poller; never dispatches into TCA.
    @State private var statsSampler = SystemStatsSampler()
    @State private var systemStats = SystemStats.zero
    /// Rolling per-metric history for the sparklines + hover graphs.
    @State private var history: [SystemStatKind: [Double]] = [:]

    /// ~2 minutes of history at the 2s sample cadence.
    private static let historyLength = 60

    /// Resolved sparkline colour: the user's custom hex, else the adaptive
    /// chrome default.
    private var sparklineColor: Color {
        if !store.settings.sparklineColorHex.isEmpty,
           let custom = Color(chromeHex: store.settings.sparklineColorHex) {
            return custom
        }
        return theme.textSecondary
    }

    /// Metrics to show: the user's enabled set, in canonical order, gated by
    /// the master toggle.
    private var enabledStatKinds: [SystemStatKind] {
        guard store.settings.showSystemStats else { return [] }
        return SystemStatKind.allCases.filter { store.settings.enabledSystemStats.contains($0.rawValue) }
    }

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
            .onAppear { if store.settings.showSystemStats { recordSample() } }
            // 2s cadence: cheap host_statistics calls, smoother than 1s. The
            // gate skips work entirely when the footer stats are disabled.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                if store.settings.showSystemStats { recordSample() }
            }
        }
    }

    /// Sample all metrics and append each scalar to its capped history ring, so
    /// a metric's sparkline is already populated when the user enables it.
    private func recordSample() {
        let snapshot = statsSampler.sample()
        systemStats = snapshot
        for kind in SystemStatKind.allCases {
            var series = history[kind] ?? []
            series.append(kind.scalar(snapshot))
            if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
            history[kind] = series
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
            let kinds = enabledStatKinds
            if !kinds.isEmpty {
                ForEach(kinds) { kind in
                    SystemStatGauge(
                        kind: kind,
                        stats: systemStats,
                        history: history[kind] ?? [],
                        showGraph: store.settings.showSystemStatGraphs,
                        graphColor: sparklineColor,
                        graphWidth: CGFloat(store.settings.sparklineWidth),
                        graphStyle: SparklineStyle(rawValue: store.settings.sparklineStyle) ?? .line
                    )
                }
                separator
            }
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
