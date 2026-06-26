import SwiftUI

/// A tiny line chart of recent values. Bounded (percentage) metrics scale to a
/// fixed 0…100; the rest auto-scale to the window's max so a flat trace still
/// reads. Drawn with `Canvas` so it stays cheap at footer size.
struct Sparkline: View {
    let values: [Double]
    let isPercentage: Bool
    var color: Color
    var filled: Bool = false

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let maxV = isPercentage ? 100.0 : max(values.max() ?? 1, 0.0001)
            let range = max(maxV, 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                let norm = min(1, max(0, values[i] / range))
                let y = size.height - CGFloat(norm) * (size.height - 1) - 0.5
                return CGPoint(x: CGFloat(i) * stepX, y: y)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1 ..< values.count {
                line.addLine(to: point(i))
            }
            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.15)))
            }
            ctx.stroke(line, with: .color(color), lineWidth: 1)
        }
    }
}

/// One footer stat: icon + value, with an optional inline sparkline, and a
/// hover popover that shows the detail breakdown plus a larger graph over time.
struct SystemStatGauge: View {
    let kind: SystemStatKind
    let stats: SystemStats
    let history: [Double]
    let showGraph: Bool
    var graphColor: Color
    var graphWidth: CGFloat
    @Environment(\.chromeTheme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: kind.systemImage).font(.system(size: 9))
            Text(kind.compactLabel(stats)).monospacedDigit()
            if showGraph, history.count >= 2 {
                Sparkline(values: history, isPercentage: kind.isPercentage, color: graphColor)
                    .frame(width: graphWidth, height: 11)
            }
        }
        .foregroundStyle(theme.textTertiary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .popover(isPresented: $hovering, arrowEdge: .top) {
            StatDetailPopover(kind: kind, stats: stats, history: history, graphColor: graphColor)
                .environment(\.chromeTheme, theme)
        }
    }
}

/// Hover popover: name, the verbose breakdown, a filled history graph, and
/// now/min/max/avg over the retained window.
struct StatDetailPopover: View {
    let kind: SystemStatKind
    let stats: SystemStats
    let history: [Double]
    var graphColor: Color
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                Text(kind.displayName).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(theme.textPrimary)

            Text(kind.detailLabel(stats))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)

            Sparkline(values: history, isPercentage: kind.isPercentage, color: graphColor, filled: true)
                .frame(width: 196, height: 52)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.textPrimary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.divider, lineWidth: 1))

            HStack(spacing: 14) {
                summaryItem("now", history.last ?? 0)
                summaryItem("min", history.min() ?? 0)
                summaryItem("max", history.max() ?? 0)
                summaryItem("avg", history.isEmpty ? 0 : history.reduce(0, +) / Double(history.count))
            }
            .foregroundStyle(theme.textSecondary)

            Text("last \(history.count) samples · ~\(history.count * 2)s")
                .font(.system(size: 9))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(theme.surfaceBackground)
    }

    private func summaryItem(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundStyle(theme.textTertiary)
            Text(formatted(value)).font(.system(size: 11)).monospacedDigit()
        }
    }

    private func formatted(_ value: Double) -> String {
        switch kind {
        case .cpu, .memory, .diskSpace: "\(Int(value.rounded()))%"
        case .load: String(format: "%.2f", value)
        case .network, .diskIO: SystemStatsFormat.rate(value)
        }
    }
}
