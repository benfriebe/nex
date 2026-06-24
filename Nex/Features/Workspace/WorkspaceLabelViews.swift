import SwiftUI

/// Pill-style label chip with an optional remove (✕) button. Used by
/// the workspace inspector (with onRemove) and by the workspace row
/// (read-only, onRemove == nil).
struct LabelChip: View {
    let text: String
    /// Resolved preset tint for this label, or nil for the neutral
    /// free-form style (the label string matched no configured preset).
    var tint: Color?
    var onRemove: (() -> Void)?

    private var fill: Color {
        tint.map { $0.opacity(0.22) } ?? Color.secondary.opacity(0.18)
    }

    private var stroke: Color {
        tint.map { $0.opacity(0.5) } ?? Color.secondary.opacity(0.25)
    }

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
                .fill(fill)
        )
        .overlay(
            Capsule()
                .stroke(stroke, lineWidth: 0.5)
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
    /// Resolved preset tint for this label, or nil for the neutral
    /// free-form style (no configured preset matched the label string).
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(tint.map { $0.opacity(0.22) } ?? Color.secondary.opacity(0.18))
            )
            .foregroundStyle(tint != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
}
