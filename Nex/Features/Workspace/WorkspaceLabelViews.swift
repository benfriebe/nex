import SwiftUI

/// Pill-style label chip with an optional remove (✕) button. Used by
/// the workspace inspector (with onRemove) and by the workspace row
/// (read-only, onRemove == nil).
struct LabelChip: View {
    let text: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove label \(text)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.18))
        )
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Label: \(text)")
    }
}

/// Compact read-only chip used inside workspace rows. Smaller padding +
/// font than `LabelChip` so several fit on one line under the row
/// metadata without crowding the agent status dot.
struct RowLabelChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
            )
            .foregroundStyle(.secondary)
    }
}

/// Wrap-on-overflow horizontal flow layout. Lays children left-to-right
/// and wraps to the next line when the proposed width is exceeded. Used
/// for chip clouds (labels in the inspector). Keeps each row's height
/// at the tallest child in that row.
struct LabelFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + row.height + (acc > 0 ? spacing : 0)
        }
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let maxWidth = proposal.width ?? bounds.width
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for entry in row.entries {
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: entry.size.width, height: entry.size.height)
                )
                x += entry.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var entries: [Entry] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct Entry {
        let index: Int
        let size: CGSize
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let lastIndex = rows.count - 1
            let needsNewRow = !rows[lastIndex].entries.isEmpty
                && rows[lastIndex].width + spacing + size.width > maxWidth
            if needsNewRow {
                rows.append(Row())
            }
            let i = rows.count - 1
            let entry = Entry(index: index, size: size)
            if rows[i].entries.isEmpty {
                rows[i].width = size.width
            } else {
                rows[i].width += spacing + size.width
            }
            rows[i].height = max(rows[i].height, size.height)
            rows[i].entries.append(entry)
        }
        return rows
    }
}
