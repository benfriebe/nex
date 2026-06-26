import SwiftUI

/// Pill-style label chip with an optional remove (✕) button. When a preset
/// tint is set the capsule is filled with the exact colour (GitHub-style)
/// and the text auto-contrasts black/white; with no tint it falls back to
/// the neutral free-form style. Used by the Settings preview.
struct LabelChip: View {
    let text: String
    /// Resolved preset tint for this label, or nil for the neutral
    /// free-form style (the label string matched no configured preset).
    var tint: Color?
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
                .fill(tint ?? Color.secondary.opacity(0.18))
        )
        .overlay {
            if tint == nil {
                Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            }
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0.contrastingText) } ?? AnyShapeStyle(.primary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Label: \(text)")
    }
}

/// Compact read-only chip used inside workspace rows. Smaller padding +
/// font than `LabelChip` so several fit on one line under the row
/// metadata without crowding the agent status dot. Solid colour fill with
/// auto-contrasting text when tinted; neutral otherwise.
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
                    .fill(tint ?? Color.secondary.opacity(0.18))
            )
            .foregroundStyle(tint.map { AnyShapeStyle($0.contrastingText) } ?? AnyShapeStyle(.secondary))
    }
}
