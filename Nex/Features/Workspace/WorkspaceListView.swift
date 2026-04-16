import ComposableArchitecture
import SwiftUI

/// Sidebar list of all workspaces with selection and context menus.
struct WorkspaceListView: View {
    let store: StoreOf<AppReducer>
    @State private var draggedWorkspaceID: UUID?
    @State private var dragCurrentY: CGFloat = 0
    @State private var dragGrabOffset: CGFloat = 0
    @State private var rowHeights: [UUID: CGFloat] = [:]

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.scope(state: \.workspaces, action: \.workspaces)) { workspaceStore in
                        workspaceRow(workspaceStore: workspaceStore)
                    }
                }
                .coordinateSpace(name: "workspaceList")
                .padding(.vertical, 4)
            }
            .onPreferenceChange(RowHeightsKey.self) { heights in
                // Merge so a partial layout pass does not discard previously
                // measured rows, then drop any ids no longer in the list.
                let validIDs = Set(store.workspaces.ids)
                var merged = rowHeights.filter { validIDs.contains($0.key) }
                for (id, h) in heights where validIDs.contains(id) {
                    merged[id] = h
                }
                rowHeights = merged
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                selectionHeader
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: { store.send(.showNewWorkspaceSheet) }) {
                    Label("New Workspace", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
            .confirmationDialog(
                bulkDeleteTitle,
                isPresented: Binding(
                    get: { store.bulkDeleteConfirmationIDs != nil },
                    set: { if !$0 { store.send(.cancelBulkDelete) } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { store.send(.confirmBulkDelete) }
                Button("Cancel", role: .cancel) { store.send(.cancelBulkDelete) }
            } message: {
                Text("This cannot be undone. Panes and surfaces in these workspaces will be closed.")
            }
        }
    }

    @ViewBuilder
    private var selectionHeader: some View {
        let count = store.selectedWorkspaceIDs.count
        if count > 0 {
            HStack(spacing: 8) {
                Text("\(count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if count < store.workspaces.count {
                    Button("Select All") { store.send(.selectAllWorkspaces) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                Button("Clear") { store.send(.clearWorkspaceSelection) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12))
        }
    }

    private var bulkDeleteTitle: String {
        let count = store.bulkDeleteConfirmationIDs?.count ?? 0
        return "Delete \(count) workspace\(count == 1 ? "" : "s")?"
    }

    @ViewBuilder
    private func contextMenuContents(
        workspaceID: UUID,
        workspaceStore: StoreOf<WorkspaceFeature>
    ) -> some View {
        let selection = store.selectedWorkspaceIDs
        let isBulkTarget = selection.contains(workspaceID) && selection.count > 1
        if isBulkTarget {
            Text("\(selection.count) workspaces selected")
            Menu("Color All Selected") {
                ForEach(WorkspaceColor.allCases) { color in
                    Button(color.displayName) {
                        store.send(.setBulkColor(color))
                    }
                }
            }
            Button("Delete \(selection.count) Workspaces...", role: .destructive) {
                store.send(.requestBulkDelete)
            }
            .disabled(selection.count >= store.workspaces.count)
            Divider()
        }
        Button("Rename...") {
            store.send(.setRenamingWorkspaceID(workspaceID))
        }
        Menu("Color") {
            ForEach(WorkspaceColor.allCases) { color in
                Button(color.displayName) {
                    workspaceStore.send(.setColor(color))
                }
            }
        }
        Divider()
        Button("Select All Workspaces") { store.send(.selectAllWorkspaces) }
            .disabled(store.selectedWorkspaceIDs.count >= store.workspaces.count)
        if !store.selectedWorkspaceIDs.isEmpty {
            Button("Deselect All") { store.send(.clearWorkspaceSelection) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            store.send(.deleteWorkspace(workspaceID))
        }
        .disabled(store.workspaces.count <= 1)
    }

    private func workspaceRow(workspaceStore: StoreOf<WorkspaceFeature>) -> some View {
        WithPerceptionTracking {
            let workspaceID = workspaceStore.state.id
            let index = store.workspaces.index(id: workspaceID) ?? 0
            let isDragging = draggedWorkspaceID == workspaceID

            let aggregateStatus = aggregateGitStatus(for: workspaceStore.state)

            WorkspaceRowView(
                name: workspaceStore.name,
                color: workspaceStore.color,
                paneCount: workspaceStore.panes.count,
                repoCount: workspaceStore.repoAssociations.count,
                gitStatus: aggregateStatus,
                isActive: workspaceID == store.activeWorkspaceID,
                index: index,
                waitingPaneCount: workspaceStore.panes.count(where: { $0.status == .waitingForInput }),
                hasRunningPanes: workspaceStore.panes.contains { $0.status == .running },
                isSelected: store.selectedWorkspaceIDs.contains(workspaceID)
            )
            .padding(.horizontal, 8)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowHeightsKey.self,
                        value: [workspaceID: geo.size.height]
                    )
                }
            )
            .offset(y: isDragging ? dragVisualOffset(at: index) : 0)
            .zIndex(isDragging ? 1 : 0)
            .opacity(isDragging ? 0.8 : 1)
            .scaleEffect(isDragging ? 1.03 : 1.0)
            .shadow(color: isDragging ? .black.opacity(0.3) : .clear, radius: 4, y: 2)
            .animation(isDragging ? .none : .easeInOut(duration: 0.15), value: store.workspaces.ids)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("workspaceList"))
                    .onChanged { value in
                        guard allHeightsMeasured else { return }
                        if draggedWorkspaceID == nil {
                            draggedWorkspaceID = workspaceID
                            dragGrabOffset = value.startLocation.y - restMinY(at: index)
                        }
                        dragCurrentY = value.location.y

                        let currentIdx = store.workspaces.index(id: workspaceID) ?? 0
                        if let targetIdx = targetIndex(forCursorY: value.location.y),
                           targetIdx != currentIdx {
                            store.send(.moveWorkspace(id: workspaceID, toIndex: targetIdx))
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            draggedWorkspaceID = nil
                            dragCurrentY = 0
                            dragGrabOffset = 0
                        }
                    }
            )
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) {
                    store.send(.toggleWorkspaceSelection(workspaceID))
                } else if flags.contains(.shift) {
                    store.send(.rangeSelectWorkspace(workspaceID))
                } else {
                    store.send(.clearWorkspaceSelection)
                    store.send(.setActiveWorkspace(workspaceID))
                }
            }
            .contextMenu {
                contextMenuContents(workspaceID: workspaceID, workspaceStore: workspaceStore)
            }
        }
    }

    private var allHeightsMeasured: Bool {
        store.workspaces.ids.allSatisfy { rowHeights[$0] != nil }
    }

    private func dragVisualOffset(at currentIndex: Int) -> CGFloat {
        guard allHeightsMeasured else { return 0 }
        return dragCurrentY - dragGrabOffset - restMinY(at: currentIndex)
    }

    /// Cumulative top edge for a row at `index` in the current display order,
    /// derived from measured per-row heights (stable per id, so no lag when the
    /// store reorders mid-drag).
    private func restMinY(at index: Int) -> CGFloat {
        let ids = store.workspaces.ids
        var y: CGFloat = 0
        for i in 0..<min(index, ids.count) {
            y += rowHeights[ids[i]] ?? 0
        }
        return y
    }

    /// Find the index whose vertical midpoint the cursor has crossed past.
    /// Returns nil if any row's height has not yet been measured, so callers
    /// don't reorder based on a partial layout.
    private func targetIndex(forCursorY cursorY: CGFloat) -> Int? {
        let ids = store.workspaces.ids
        guard !ids.isEmpty, allHeightsMeasured else { return nil }
        var y: CGFloat = 0
        for (i, id) in ids.enumerated() {
            let h = rowHeights[id] ?? 0
            if cursorY < y + h / 2 {
                return i
            }
            y += h
        }
        return ids.count - 1
    }

    /// Aggregate git status: dirty if any association is dirty, clean if all clean, unknown otherwise.
    private func aggregateGitStatus(for workspace: WorkspaceFeature.State) -> RepoGitStatus {
        let statuses = workspace.repoAssociations.map { assoc in
            store.gitStatuses[assoc.id] ?? .unknown
        }
        if statuses.isEmpty { return .unknown }
        if statuses.contains(where: { if case .dirty = $0 { true } else { false } }) {
            let totalChanged = statuses.reduce(0) { total, status in
                if case .dirty(let count) = status { return total + count }
                return total
            }
            return .dirty(changedFiles: totalChanged)
        }
        if statuses.allSatisfy({ $0 == .clean }) {
            return .clean
        }
        return .unknown
    }
}

private struct RowHeightsKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
