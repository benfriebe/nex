import AppKit
import SwiftUI

/// Panel that appears in a web pane while a batch-annotate session
/// is in progress. Lists every captured `BatchInspectItem` with an
/// editable comment field; the user can remove individual entries or
/// send the whole batch to the configured destination.
struct WebBatchInspectPanel: View {
    let items: [BatchInspectItem]
    /// Other panes available as paste targets. Surfaced in the
    /// footer's destination picker.
    let availableTargets: [InspectTargetOption]
    /// Item with the bidirectional focus highlight. Set by either a
    /// row tap or a page-side marker click.
    let focusedItemID: UUID?
    let onCommentChanged: (UUID, String) -> Void
    let onRemoveItem: (UUID) -> Void
    /// Fired on row click → triggers panel-originated focus (also
    /// scrolls + pulses the page-side badge).
    let onRowTapped: (UUID) -> Void
    /// Send with the currently-selected destination. nil reserved for
    /// a future "Local queue" picker entry; currently the picker only
    /// offers pane targets and Send is disabled until one is selected.
    let onSend: (UUID?) -> Void
    let onCancel: () -> Void
    /// Last destination this pane was sent to in the current app
    /// session, or `nil` on the first batch. Seeds the picker.
    var initialSelection: BatchTargetMemory?

    @Environment(\.chromeTheme) private var chromeTheme
    @State private var selection: TargetSelection = .unselected

    /// `.unselected` blocks Send so the user can't accidentally
    /// dispatch a batch to nowhere. Items still survive cancel via the
    /// CLI's `nex web inspect-result` queue.
    private enum TargetSelection: Equatable {
        case unselected
        case pane(UUID)
    }

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
        .background(chromeTheme.surfaceBackground)
        .overlay(alignment: .top) { Divider() }
        .onAppear { seedSelection() }
        // The WKWebView underneath sets `cursor:crosshair` while the
        // picker is armed. Without an explicit override, NSCursor
        // would keep crosshair as the user moves into the SwiftUI
        // panel (AppKit only resets when a fresh cursor-rect view
        // claims the rect). Force arrow whenever the mouse is over
        // the panel surface.
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }

    /// Seed the picker from the per-pane "last destination" memory.
    /// First batch of a session stays `.unselected` so the user has
    /// to pick deliberately; Send is disabled until they do.
    private func seedSelection() {
        switch initialSelection {
        case .none, .local:
            selection = .unselected
        case .pane(let id) where availableTargets.contains(where: { $0.id == id }):
            selection = .pane(id)
        case .pane:
            // Remembered pane no longer exists — fall back rather
            // than holding a dead id.
            selection = .unselected
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Element pickup")
                .font(.system(size: 11, weight: .semibold))
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
            destinationPicker
            Button("Send \(items.count)") {
                if case .pane(let id) = selection { onSend(id) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(items.isEmpty || selection == .unselected)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // If the chosen pane disappears mid-batch (closed by the
        // user), fall back to unselected so they have to reconfirm
        // instead of silently rerouting to whatever the picker shows.
        .onChange(of: availableTargets) { _, newTargets in
            if case .pane(let id) = selection,
               !newTargets.contains(where: { $0.id == id }) {
                selection = .unselected
            }
        }
    }

    /// Destination dropdown shown next to the Send button. Rendered
    /// as a bordered button (rather than `.menuStyle(.borderlessButton)`
    /// which collapses Text labels to icon-only on macOS) so the
    /// current pick reads as a button with a label inside.
    private var destinationPicker: some View {
        Menu {
            if availableTargets.isEmpty {
                Text("No other panes open in this workspace")
                    .font(.caption)
            } else {
                ForEach(availableTargets) { target in
                    Button {
                        selection = .pane(target.id)
                    } label: {
                        HStack {
                            Text(target.label)
                            if selection == .pane(target.id) {
                                Spacer(); Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentTargetLabel)
                    .foregroundStyle(selection == .unselected ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 140, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(chromeTheme.headerBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        selection == .unselected
                            ? Color.accentColor.opacity(0.6)
                            : Color.secondary.opacity(0.35),
                        lineWidth: selection == .unselected ? 1.0 : 0.5
                    )
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where to send this batch")
    }

    private var currentTargetLabel: String {
        switch selection {
        case .unselected: "Select destination…"
        case .pane(let id):
            availableTargets.first(where: { $0.id == id })?.label ?? "Select destination…"
        }
    }
}
