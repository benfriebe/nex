import ComposableArchitecture
import SwiftUI

/// Fuzzy search picker for selecting a repo from the global registry.
struct RepoPickerView: View {
    /// Focusable controls in tab order. The repo list is a single Tab stop:
    /// once focused, Up/Down arrows move the highlight and Return/Space
    /// selects. This keeps Tab predictable regardless of list length and the
    /// macOS "Keyboard navigation" system setting (#64).
    private enum Field: Hashable {
        case search
        case list
        case cancel
    }

    let repos: IdentifiedArrayOf<Repo>
    let alreadyAssociatedRepoIDs: Set<UUID>
    let onSelect: (Repo) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var highlightedRepoID: UUID?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 12) {
            Text("Add Repository")
                .font(.headline)

            TextField("Search repos...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .search)
                .onKeyPress(keys: [.tab]) { handleTab($0) }
                .onChange(of: searchText) { _, _ in
                    clampHighlight()
                }
                .onSubmit { _ = selectHighlighted() }

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
            }
        }
        .padding(16)
        .frame(width: 360, height: 300)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .search
                highlightedRepoID = filteredRepos.first?.id
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
            .onKeyPress(.upArrow) { moveHighlight(by: -1, proxy: proxy) }
            .onKeyPress(.downArrow) { moveHighlight(by: 1, proxy: proxy) }
            .onKeyPress(.return) { selectHighlighted() }
            .onKeyPress(.space) { selectHighlighted() }
            .onKeyPress(keys: [.tab]) { handleTab($0) }
        }
    }

    @ViewBuilder
    private func row(for repo: Repo) -> some View {
        let isAlready = alreadyAssociatedRepoIDs.contains(repo.id)
        let isHighlighted = focusedField == .list && highlightedRepoID == repo.id
        HStack {
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
                .fill(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
        .opacity(isAlready ? 0.5 : 1.0)
        .onTapGesture {
            if !isAlready { onSelect(repo) }
        }
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

    private var visibleFields: [Field] {
        var fields: [Field] = [.search]
        if !filteredRepos.isEmpty {
            fields.append(.list)
        }
        fields.append(.cancel)
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
        if next == .list, highlightedRepoID == nil {
            highlightedRepoID = filteredRepos.first?.id
        }
        return .handled
    }

    private func moveHighlight(by delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = filteredRepos
        guard !rows.isEmpty else { return .ignored }
        let currentIdx = rows.firstIndex(where: { $0.id == highlightedRepoID }) ?? 0
        let newIdx = min(max(currentIdx + delta, 0), rows.count - 1)
        let newID = rows[newIdx].id
        highlightedRepoID = newID
        withAnimation(.linear(duration: 0.1)) {
            proxy.scrollTo(newID, anchor: .center)
        }
        return .handled
    }

    private func selectHighlighted() -> KeyPress.Result {
        guard let id = highlightedRepoID,
              let repo = filteredRepos[id: id],
              !alreadyAssociatedRepoIDs.contains(id) else { return .ignored }
        onSelect(repo)
        return .handled
    }

    private func clampHighlight() {
        if let current = highlightedRepoID, filteredRepos[id: current] != nil {
            return
        }
        highlightedRepoID = filteredRepos.first?.id
    }
}
