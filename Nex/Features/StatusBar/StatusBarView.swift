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
        // Spacing-separated (no dot separators) — the gaps carry the grouping.
        HStack(spacing: 14) {
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
            }
            StatusCountItem(store: store, kind: .running, color: theme.statusRunning, value: summary.running)
            StatusCountItem(store: store, kind: .waiting, color: theme.statusWaiting, value: summary.waiting)
            StatusCountItem(store: store, kind: .done, color: theme.statusDone, value: summary.done)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The three agent states surfaced in the footer's right-hand counts.
enum AgentStatusKind: Equatable {
    case running, waiting, done

    var label: String {
        switch self {
        case .running: "running"
        case .waiting: "waiting"
        case .done: "done"
        }
    }

    var title: String {
        switch self {
        case .running: "Running agents"
        case .waiting: "Awaiting input"
        case .done: "Completed"
        }
    }
}

/// One running/waiting pane shown in the hover popover + click menu.
struct AgentPaneRef: Identifiable {
    let id: UUID
    let workspaceID: UUID
    let workspaceName: String
    let workspaceColor: WorkspaceColor
    let paneTitle: String
    let startedAt: Date?
}

/// A footer count (dot · number · label). When there are panes in this state
/// (running / waiting), a click opens a popover listing them; selecting one
/// switches to its workspace and focuses it. `.done` is a session counter with
/// no live panes, and a 0-count item is inert (plain, non-interactive).
struct StatusCountItem: View {
    let store: StoreOf<AppReducer>
    let kind: AgentStatusKind
    let color: Color
    let value: Int
    @Environment(\.chromeTheme) private var theme
    @State private var showingDetail = false

    var body: some View {
        // Any non-zero count opens a detail popover; 0-count items stay plain
        // (un-dimmed, non-clickable). Running/waiting rows navigate to the live
        // pane; done lists the recently-finished agents (nothing to navigate
        // to), so its rows are read-only.
        if value > 0 {
            Button { showingDetail = true } label: { countLabel }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .popover(isPresented: $showingDetail, arrowEdge: .top) {
                    AgentStatusDetailPopover(
                        kind: kind,
                        color: color,
                        count: value,
                        panes: panes,
                        completed: completed,
                        onSelect: kind == .done ? nil : { ref in
                            navigate(to: ref)
                            showingDetail = false
                        }
                    )
                    .environment(\.chromeTheme, theme)
                }
        } else {
            countLabel
        }
    }

    private var countLabel: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            // Fixed-width count so the label (and everything after) doesn't
            // shift when the number goes single → double digit.
            Text("\(value)")
                .monospacedDigit()
                .frame(width: 14, alignment: .trailing)
            Text(kind.label)
        }
        // Plain button can tint its label; restate the footer's neutral tone.
        .foregroundStyle(theme.textSecondary)
    }

    private func navigate(to ref: AgentPaneRef) {
        store.send(.setActiveWorkspace(ref.workspaceID))
        // Defer focus until the popover has dismissed and the main window has
        // restored its prior first responder — otherwise that restoration
        // re-emits focus for the previously-focused surface and reverts the
        // selection when the target pane is in the already-active workspace.
        DispatchQueue.main.async {
            store.send(.workspaces(.element(id: ref.workspaceID, action: .focusPane(ref.id))))
        }
    }

    /// Recently-finished agents for the `.done` popover (newest first), else [].
    private var completed: [CompletedAgent] {
        kind == .done ? store.completedAgents : []
    }

    /// Panes currently in this state (empty for `.done`). Read lazily when the
    /// popover opens.
    private var panes: [AgentPaneRef] {
        guard kind != .done else { return [] }
        let target: PaneStatus = kind == .running ? .running : .waitingForInput
        return store.workspaces.flatMap { workspace in
            workspace.panes
                .filter { $0.status == target }
                .map { pane in
                    AgentPaneRef(
                        id: pane.id,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        workspaceColor: workspace.color,
                        paneTitle: pane.title ?? pane.label ?? "Shell",
                        startedAt: pane.agentStartedAt
                    )
                }
        }
    }
}

/// Popover for a footer agent count: a titled list of the panes in that state
/// (workspace · pane · live elapsed for running). When `onSelect` is provided
/// each row is a button that jumps to that pane. `.done` shows the session
/// total instead (nothing to navigate to).
struct AgentStatusDetailPopover: View {
    let kind: AgentStatusKind
    let color: Color
    let count: Int
    let panes: [AgentPaneRef]
    var completed: [CompletedAgent] = []
    var onSelect: ((AgentPaneRef) -> Void)?
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(.bottom, 2)

            if kind == .done {
                Text("\(count) completed this session")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                if !completed.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(completed.prefix(12).enumerated()), id: \.offset) { _, agent in
                            completedRow(agent)
                        }
                    }
                    if count > completed.count {
                        Text("+ \(count - completed.count) earlier")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            } else if panes.isEmpty {
                Text("None.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(panes) { row($0) }
                }
            }
        }
        .padding(12)
        .frame(width: 252, alignment: .leading)
        .background(theme.surfaceBackground)
        // No focus ring on the popover / its row buttons (the macOS focus
        // effect otherwise draws an accent-tinted ring when the popover is key).
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func row(_ ref: AgentPaneRef) -> some View {
        if let onSelect {
            Button { onSelect(ref) } label: { rowContent(ref) }
                .buttonStyle(.plain)
        } else {
            rowContent(ref)
        }
    }

    private func rowContent(_ ref: AgentPaneRef) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ref.workspaceColor.color).frame(width: 7, height: 7)
            Text(ref.workspaceName).foregroundStyle(theme.textSecondary)
            Text("·").foregroundStyle(theme.textTertiary)
            Text(ref.paneTitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 10)
            if kind == .running, let started = ref.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(chromeElapsedLabel(from: started, to: context.date))
                        .monospacedDigit()
                        .foregroundStyle(theme.activeAgent)
                }
            }
        }
        .font(.system(size: 12))
        // Whole row (incl. the trailing gap) is the hit target.
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    /// Read-only row for a finished agent: workspace · pane · completion time.
    private func completedRow(_ agent: CompletedAgent) -> some View {
        HStack(spacing: 6) {
            Circle().fill(agent.workspaceColor.color).frame(width: 7, height: 7)
            Text(agent.workspaceName).foregroundStyle(theme.textSecondary)
            Text("·").foregroundStyle(theme.textTertiary)
            Text(agent.paneTitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 10)
            Text(agent.completedAt, style: .time)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
    }
}
