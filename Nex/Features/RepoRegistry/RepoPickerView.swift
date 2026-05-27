import ComposableArchitecture
import SwiftUI

/// Fuzzy search picker for selecting one or more repos from the
/// global registry. Selection is decoupled from confirmation: clicks
/// build a selection, an explicit Confirm button (Return) commits it.
///
/// `.multiple` mode behaves like a checkbox list — each click toggles
/// the row's selection independently. Shift-click extends from the
/// anchor without dropping the previous selection.
///   - plain click   : toggle the clicked row in/out of the selection
///   - shift-click   : add the range from the anchor to the clicked row
///   - double-click  : select only this row and confirm immediately
///
/// `.single` mode keeps the standard radio-button behaviour: each
/// click replaces the selection with the clicked row.
struct RepoPickerView: View {
    enum SelectionMode: Hashable {
        case single
        case multiple
    }

    private enum Field: Hashable {
        case search
        case list
        case cancel
        case confirm
    }

    let repos: IdentifiedArrayOf<Repo>
    let alreadyAssociatedRepoIDs: Set<UUID>
    let selectionMode: SelectionMode
    let confirmLabel: String
    let onConfirm: ([Repo]) -> Void
    let onCancel: () -> Void

    init(
        repos: IdentifiedArrayOf<Repo>,
        alreadyAssociatedRepoIDs: Set<UUID>,
        selectionMode: SelectionMode = .single,
        confirmLabel: String = "Add",
        onConfirm: @escaping ([Repo]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.repos = repos
        self.alreadyAssociatedRepoIDs = alreadyAssociatedRepoIDs
        self.selectionMode = selectionMode
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    @State private var searchText = ""
    @State private var selectedRepoIDs: Set<UUID> = []
    /// Last interacted-with row. Drives keyboard nav and shift-click ranges.
    @State private var anchorRepoID: UUID?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 12) {
            Text(selectionMode == .multiple ? "Add Repositories" : "Add Repository")
                .font(.headline)

            TextField("Search repos...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .search)
                .onKeyPress(keys: [.tab]) { handleTab($0) }
                .onChange(of: searchText) { _, _ in
                    clampAnchor()
                }
                .onSubmit { _ = confirmIfPossible() }

            if filteredRepos.isEmpty {
                VStack(spacing: 4) {
                    Text("No matching repositories")
                        .foregroundStyle(.secondary)
                    Text("Register repos in Settings > Repositories first.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxHeight: .infinity)
            } else {
                repoList
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($focusedField, equals: .cancel)
                    .onKeyPress(keys: [.tab]) { handleTab($0) }
                Spacer()
                Button(confirmLabel) { _ = confirmIfPossible() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
                    .focused($focusedField, equals: .confirm)
                    .onKeyPress(keys: [.tab]) { handleTab($0) }
            }
        }
        .padding(16)
        .frame(width: 360, height: 340)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .search
                anchorRepoID = firstSelectableID
            }
        }
    }

    private var repoList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredRepos) { repo in
                        row(for: repo)
                            .id(repo.id)
                    }
                }
                .padding(4)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .focusable()
            .focused($focusedField, equals: .list)
            .onKeyPress(keys: [.upArrow]) { handleArrow($0, delta: -1, proxy: proxy) }
            .onKeyPress(keys: [.downArrow]) { handleArrow($0, delta: 1, proxy: proxy) }
            .onKeyPress(.return) { confirmIfPossible() }
            .onKeyPress(.space) { toggleAnchor() }
            .onKeyPress(keys: [.tab]) { handleTab($0) }
        }
    }

    @ViewBuilder
    private func row(for repo: Repo) -> some View {
        let isAlready = alreadyAssociatedRepoIDs.contains(repo.id)
        let isSelected = selectedRepoIDs.contains(repo.id)
        let isAnchor = anchorRepoID == repo.id && focusedField == .list
        HStack(spacing: 6) {
            if selectionMode == .multiple {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.system(size: 13, weight: .medium))
                Text(repo.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isAlready {
                Text("Added")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground(isSelected: isSelected, isAnchor: isAnchor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isAnchor && !isSelected ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .opacity(isAlready ? 0.5 : 1.0)
        .onTapGesture(count: 2) {
            guard !isAlready else { return }
            selectedRepoIDs = [repo.id]
            anchorRepoID = repo.id
            _ = confirmIfPossible()
        }
        .onTapGesture {
            guard !isAlready else { return }
            handleClick(repo: repo)
        }
    }

    private func rowBackground(isSelected: Bool, isAnchor: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(focusedField == .list ? 0.4 : 0.25)
        }
        if isAnchor {
            return Color.accentColor.opacity(0.1)
        }
        return .clear
    }

    private func handleClick(repo: Repo) {
        let isShift = NSEvent.modifierFlags.contains(.shift)
        anchorIntoList()

        switch selectionMode {
        case .single:
            selectedRepoIDs = [repo.id]
            anchorRepoID = repo.id
        case .multiple:
            // Checkbox semantics: each click toggles the row's
            // selection independently. Shift-click adds the range
            // from the anchor to the clicked row without removing
            // the previous selection.
            if isShift, let anchor = anchorRepoID, anchor != repo.id {
                selectedRepoIDs.formUnion(rangeIDs(from: anchor, to: repo.id))
            } else {
                if selectedRepoIDs.contains(repo.id) {
                    selectedRepoIDs.remove(repo.id)
                } else {
                    selectedRepoIDs.insert(repo.id)
                }
            }
            anchorRepoID = repo.id
        }
    }

    /// IDs of all selectable rows between `from` and `to`, inclusive,
    /// in the order they appear in `filteredRepos`. Already-associated
    /// rows are skipped. Used by shift-click range selection.
    private func rangeIDs(from: UUID, to: UUID) -> Set<UUID> {
        let rows = filteredRepos
        guard let i = rows.firstIndex(where: { $0.id == from }),
              let j = rows.firstIndex(where: { $0.id == to }) else {
            return [to]
        }
        let lo = min(i, j)
        let hi = max(i, j)
        return Set(rows[lo...hi].map(\.id).filter { !alreadyAssociatedRepoIDs.contains($0) })
    }

    private var filteredRepos: IdentifiedArrayOf<Repo> {
        if searchText.isEmpty {
            return repos
        }
        let query = searchText.lowercased()
        return repos.filter {
            $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    private var firstSelectableID: UUID? {
        filteredRepos.first { !alreadyAssociatedRepoIDs.contains($0.id) }?.id
            ?? filteredRepos.first?.id
    }

    private var canConfirm: Bool {
        !selectedRepoIDs.isEmpty
            && selectedRepoIDs.contains { !alreadyAssociatedRepoIDs.contains($0) }
    }

    private var visibleFields: [Field] {
        var fields: [Field] = [.search]
        if !filteredRepos.isEmpty {
            fields.append(.list)
        }
        fields.append(.cancel)
        if canConfirm {
            fields.append(.confirm)
        }
        return fields
    }

    private func handleTab(_ press: KeyPress) -> KeyPress.Result {
        advanceFocus(by: press.modifiers.contains(.shift) ? -1 : 1)
    }

    private func advanceFocus(by delta: Int) -> KeyPress.Result {
        let fields = visibleFields
        guard let current = focusedField,
              let idx = fields.firstIndex(of: current) else { return .ignored }
        let count = fields.count
        let next = fields[(idx + delta + count) % count]
        focusedField = next
        if next == .list, anchorRepoID == nil {
            anchorRepoID = firstSelectableID
        }
        return .handled
    }

    private func handleArrow(_ press: KeyPress, delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let extend = selectionMode == .multiple && press.modifiers.contains(.shift)
        return moveAnchor(by: delta, extend: extend, proxy: proxy)
    }

    @discardableResult
    private func moveAnchor(by delta: Int, extend: Bool, proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = filteredRepos
        guard !rows.isEmpty else { return .ignored }
        let currentIdx = rows.firstIndex(where: { $0.id == anchorRepoID }) ?? 0
        let newIdx = min(max(currentIdx + delta, 0), rows.count - 1)
        let newID = rows[newIdx].id
        anchorRepoID = newID
        switch selectionMode {
        case .single:
            // Selection follows the anchor in single mode so the row
            // the keyboard cursor lands on is what Return confirms.
            if !alreadyAssociatedRepoIDs.contains(newID) {
                selectedRepoIDs = [newID]
            }
        case .multiple:
            // Checkbox semantics: plain arrows move the cursor but do
            // not change selection (use Space to toggle). Shift-arrows
            // extend the selection from the previous anchor.
            if extend {
                let lo = min(currentIdx, newIdx)
                let hi = max(currentIdx, newIdx)
                let span = rows[lo...hi].map(\.id).filter { !alreadyAssociatedRepoIDs.contains($0) }
                selectedRepoIDs.formUnion(span)
            }
        }
        withAnimation(.linear(duration: 0.1)) {
            proxy.scrollTo(newID, anchor: .center)
        }
        return .handled
    }

    private func toggleAnchor() -> KeyPress.Result {
        guard let id = anchorRepoID,
              !alreadyAssociatedRepoIDs.contains(id) else { return .ignored }
        switch selectionMode {
        case .single:
            selectedRepoIDs = [id]
        case .multiple:
            if selectedRepoIDs.contains(id) {
                selectedRepoIDs.remove(id)
            } else {
                selectedRepoIDs.insert(id)
            }
        }
        return .handled
    }

    @discardableResult
    private func confirmIfPossible() -> KeyPress.Result {
        guard canConfirm else { return .ignored }
        let chosen = filteredRepos
            .filter { selectedRepoIDs.contains($0.id) && !alreadyAssociatedRepoIDs.contains($0.id) }
        guard !chosen.isEmpty else { return .ignored }
        onConfirm(Array(chosen))
        return .handled
    }

    /// Mouse clicks on a `.focusable()` SwiftUI control don't always
    /// promote it to focused (especially when another field had
    /// keyboard focus). Force it so selection styles render at full
    /// opacity and Return/Space land on the list, not the prior field.
    private func anchorIntoList() {
        if focusedField != .list {
            focusedField = .list
        }
    }

    private func clampAnchor() {
        if let current = anchorRepoID, filteredRepos[id: current] != nil {
            // Trim any selected rows that vanished from the filter.
            selectedRepoIDs = selectedRepoIDs.filter { filteredRepos[id: $0] != nil }
            return
        }
        anchorRepoID = firstSelectableID
        selectedRepoIDs = selectedRepoIDs.filter { filteredRepos[id: $0] != nil }
    }
}
