import SwiftUI

/// Pill-style label chip. When a preset style is set the capsule is filled
/// with the exact colour (GitHub-style) with the resolved text colour; with
/// no style it falls back to the neutral free-form style. Used by the
/// Settings → Labels preview.
struct LabelChip: View {
    let text: String
    /// Resolved preset colours for this label, or nil for the neutral
    /// free-form style (the label string matched no configured preset).
    var style: ResolvedLabelStyle?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(style?.background ?? Color.secondary.opacity(0.18))
            )
            .overlay {
                if style == nil {
                    Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                }
            }
            .foregroundStyle(style.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.primary))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Label: \(text)")
    }
}

/// Compact read-only chip used inside workspace rows. Smaller padding +
/// font than `LabelChip` so several fit on one line under the row
/// metadata without crowding the agent status dot. Solid colour fill with
/// the resolved text colour when styled; neutral otherwise.
struct RowLabelChip: View {
    let text: String
    /// Resolved preset colours for this label, or nil for the neutral
    /// free-form style (no configured preset matched the label string).
    var style: ResolvedLabelStyle?

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(style?.background ?? Color.secondary.opacity(0.18))
            )
            .foregroundStyle(style.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.secondary))
    }
}
