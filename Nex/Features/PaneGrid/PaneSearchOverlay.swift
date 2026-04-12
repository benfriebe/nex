import SwiftUI

/// Floating search bar overlay for terminal pane scrollback search.
/// Positioned at the top-right corner of the pane.
struct PaneSearchOverlay: View {
    let needle: String
    let total: Int?
    let selected: Int?
    let onNeedleChanged: (String) -> Void
    let onNavigateNext: () -> Void
    let onNavigatePrevious: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var localNeedle: String = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("Search", text: $localNeedle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 160)
                .padding(.leading, 8)
                .padding(.trailing, localNeedle.isEmpty ? 0 : matchCountWidth)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(5)
                .focused($isFieldFocused)
                .overlay(alignment: .trailing) {
                    matchCountLabel
                        .padding(.trailing, 6)
                }
                .onKeyPress { keyPress in
                    if keyPress.key == .return, keyPress.modifiers.contains(.shift) {
                        onNavigatePrevious()
                        return .handled
                    }
                    return .ignored
                }
                .onSubmit {
                    onNavigateNext()
                }
                .onChange(of: localNeedle) { _, newValue in
                    onNeedleChanged(newValue)
                }

            Button(action: onNavigateNext) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(localNeedle.isEmpty ? 0.3 : 0.7)
            .disabled(localNeedle.isEmpty)

            Button(action: onNavigatePrevious) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(localNeedle.isEmpty ? 0.3 : 0.7)
            .disabled(localNeedle.isEmpty)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.7)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .onAppear {
            localNeedle = needle
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private var matchCountWidth: CGFloat {
        guard !localNeedle.isEmpty, let total else { return 0 }
        let text = if let selected {
            "\(selected + 1)/\(total)"
        } else {
            "-/\(total)"
        }
        // Approximate width: ~7pt per character at 10pt monospaced + padding
        return CGFloat(text.count) * 7 + 8
    }

    @ViewBuilder
    private var matchCountLabel: some View {
        if !localNeedle.isEmpty {
            if let selected, let total {
                Text("\(selected + 1)/\(total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            } else if let total {
                Text("-/\(total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }
}
