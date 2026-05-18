import SwiftUI

/// Panel that appears in a web pane while a batch-annotate session
/// is in progress. Lists every captured `BatchInspectItem` with an
/// editable comment field; the user can remove individual entries or
/// send the whole batch to the configured destination.
struct WebBatchInspectPanel: View {
    let items: [BatchInspectItem]
    /// Display label for the destination pane, or "(local queue)"
    /// when the batch is set to drop into the inspect-result queue
    /// rather than paste anywhere.
    let destinationLabel: String
    /// Item with the bidirectional focus highlight. Set by either a
    /// row tap or a page-side marker click.
    let focusedItemID: UUID?
    let onCommentChanged: (UUID, String) -> Void
    let onRemoveItem: (UUID) -> Void
    /// Fired on row click → triggers panel-originated focus (also
    /// scrolls + pulses the page-side badge).
    let onRowTapped: (UUID) -> Void
    let onSend: () -> Void
    let onCancel: () -> Void

    /// Approximate height of one row (chip + selector + comment
    /// field + padding + inter-row spacing). Used to size the
    /// items area so it grows naturally up to `visibleRowCap` rows
    /// then starts scrolling.
    private static let rowHeight: CGFloat = 64
    private static let visibleRowCap = 3
    private static let listVerticalPadding: CGFloat = 12

    /// Tracks which comment field currently has keyboard focus, so
    /// stepping into one also fires the page-side highlight.
    @FocusState private var focusedCommentID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if items.isEmpty {
                emptyHint
            } else {
                itemsList
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Batch annotate")
                .font(.system(size: 11, weight: .semibold))
            Text("→ \(destinationLabel)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Items area. Grows naturally up to `visibleRowCap` rows tall;
    /// over the cap the inner ScrollView takes over and we clamp the
    /// height so the panel never dominates the pane.
    private var itemsList: some View {
        let visibleRows = min(items.count, Self.visibleRowCap)
        let height = CGFloat(visibleRows) * Self.rowHeight + Self.listVerticalPadding
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        row(item, index: idx)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: height)
            .onChange(of: focusedItemID) { _, newValue in
                guard let newValue else { return }
                // Scroll the row into view…
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
                // …and put keyboard focus into its comment field so
                // the user can type immediately after each new pick.
                if focusedCommentID != newValue {
                    focusedCommentID = newValue
                }
            }
        }
    }

    private var emptyHint: some View {
        Text("Click elements in the page to add them. Esc cancels.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    private func row(_ item: BatchInspectItem, index: Int) -> some View {
        let isFocused = item.id == focusedItemID
        return HStack(alignment: .top, spacing: 6) {
            // Numbered chip matching the page badge.
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.result.tag.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Text(item.result.selector)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onRowTapped(item.id) }

                TextField(
                    "Comment (optional)",
                    text: Binding(
                        get: { item.comment },
                        set: { onCommentChanged(item.id, $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($focusedCommentID, equals: item.id)
                .onChange(of: focusedCommentID) { _, newValue in
                    // Fire the page-side highlight when this field
                    // gains focus (tab key, click, etc.). Other fields
                    // losing focus also pass through here with their
                    // own item.id, which we filter out below.
                    if newValue == item.id {
                        onRowTapped(item.id)
                    }
                }
            }

            Button(action: { onRemoveItem(item.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this item")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isFocused ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
            Spacer()
            Button("Send \(items.count)") {
                onSend()
            }
            .buttonStyle(.borderedProminent)
            .disabled(items.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
