import ComposableArchitecture
import SwiftUI

/// Sidebar list of all workspaces with selection and context menus.
struct WorkspaceListView: View {
    let store: StoreOf<AppReducer>
    @State private var draggedWorkspaceID: UUID?
    @State private var dragCurrentY: CGFloat = 0
    @State private var dragGrabOffset: CGFloat = 0
    /// Current drop target under the cursor. Drives the indicator overlay.
    /// For same-container moves we ALSO live-apply via the reducer so the
    /// other rows shift smoothly under the drag — the indicator renders
    /// only for cross-container moves where the row is not live-reordered.
    @State private var currentDropTarget: DropTarget?
    @State private var rowHeights: [SidebarID: CGFloat] = [:]

    /// Vertical padding inside the ScrollView's VStack. Drop zones are
    /// computed in the same coordinate space, so they shift by this
    /// amount from the VStack's (0,0) origin.
    private static let contentVerticalPadding: CGFloat = 4
    /// Approximate laid-out height of `GroupEmptyRow`; must match
    /// `topLevelItemHeight` and the empty-row layout.
    private static let groupEmptyRowHeight: CGFloat = 28

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { outer in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.state.renderedEntries) { entry in
                            entryView(for: entry)
                        }
                        // Trailing flexible spacer that fills remaining
                        // viewport height. Absorbs right-clicks ("New Group"
                        // context menu) below the last row and left-clicks
                        // that should exit an active group rename via the
                        // focus-loss commit path.
                        Color.clear
                            .frame(minHeight: 40, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if store.renamingGroupID != nil {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                }
                            }
                            .contextMenu {
                                Button("New Group") {
                                    let placeholder = defaultGroupName(existing: store.groups)
                                    store.send(.createGroup(name: placeholder, autoRename: true))
                                }
                            }
                    }
                    .coordinateSpace(name: "workspaceList")
                    .padding(.vertical, 4)
                    .frame(minHeight: outer.size.height, alignment: .top)
                    .animation(.easeInOut(duration: 0.1), value: store.state.renderedEntries)
                    .overlay(alignment: .topLeading) {
                        dropIndicatorOverlay
                    }
                }
                .onPreferenceChange(RowHeightsKey.self) { heights in
                    let validIDs = validSidebarIDs
                    var merged = rowHeights.filter { validIDs.contains($0.key) }
                    for (id, h) in heights where validIDs.contains(id) {
                        merged[id] = h
                    }
                    rowHeights = merged
                }
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
            .confirmationDialog(
                groupDeleteTitle,
                isPresented: Binding(
                    get: { store.groupDeleteConfirmation != nil },
                    set: { if !$0 { store.send(.cancelGroupDelete) } }
                ),
                titleVisibility: .visible
            ) {
                if let confirmation = store.groupDeleteConfirmation {
                    Button("Move Workspaces to Top Level", role: .destructive) {
                        store.send(.deleteGroup(id: confirmation.groupID, cascade: false))
                    }
                    Button(
                        "Delete Group and \(confirmation.workspaceCount) Workspace\(confirmation.workspaceCount == 1 ? "" : "s")",
                        role: .destructive
                    ) {
                        store.send(.deleteGroup(id: confirmation.groupID, cascade: true))
                    }
                    .disabled(confirmation.workspaceCount == 0)
                    Button("Cancel", role: .cancel) { store.send(.cancelGroupDelete) }
                }
            } message: {
                if let confirmation = store.groupDeleteConfirmation, confirmation.workspaceCount > 0 {
                    Text("Choose whether to also delete the \(confirmation.workspaceCount) workspace\(confirmation.workspaceCount == 1 ? "" : "s") inside this group. Moving them to the top level is the safer option.")
                } else {
                    Text("This group is empty and will be removed.")
                }
            }
            .sheet(isPresented: Binding(
                get: { store.groupBulkCreatePrompt != nil },
                set: { if !$0 { store.send(.cancelBulkCreateGroup) } }
            )) {
                if let prompt = store.groupBulkCreatePrompt {
                    NewGroupSheet(
                        workspaceCount: prompt.workspaceIDs.count,
                        defaultName: defaultGroupName(existing: store.groups),
                        onCreate: { name, color in
                            store.send(.confirmBulkCreateGroup(name: name, color: color))
                        },
                        onCancel: { store.send(.cancelBulkCreateGroup) }
                    )
                }
            }
        }
    }

    // MARK: - Entry rendering

    @ViewBuilder
    private func entryView(for entry: RenderedEntry) -> some View {
        switch entry {
        case .workspaceRow(let workspaceID, let depth):
            if let workspaceStore = store.scope(
                state: \.workspaces[id: workspaceID],
                action: \.workspaces[id: workspaceID]
            ) {
                workspaceRow(workspaceStore: workspaceStore, depth: depth)
            }
        case .groupHeader(let groupID):
            if let group = store.groups[id: groupID] {
                let count = group.childOrder.compactMap { store.workspaces[id: $0] }.count
                GroupHeaderRow(
                    name: group.name,
                    color: group.color,
                    isCollapsed: group.isCollapsed,
                    workspaceCount: count,
                    isRenaming: store.renamingGroupID == groupID,
                    onToggleCollapse: {
                        // If a different group is being renamed, clicking any
                        // row should commit its name via focus loss.
                        if let rid = store.renamingGroupID, rid != groupID {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                        store.send(.toggleGroupCollapse(groupID))
                    },
                    onCommitRename: { newName in
                        store.send(.renameGroup(id: groupID, name: newName))
                    },
                    onCancelRename: { store.send(.setRenamingGroupID(nil)) }
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: RowHeightsKey.self,
                            value: [.group(groupID): geo.size.height]
                        )
                    }
                )
                .contextMenu {
                    groupContextMenu(groupID: groupID, group: group)
                }
            }
        case .groupEmpty(let groupID):
            GroupEmptyRow()
                .background(
                    GeometryReader { _ in
                        // Empty rows don't participate in drag; no preference needed
                        Color.clear
                    }
                )
                .id("empty-\(groupID.uuidString)")
        }
    }

    private var validSidebarIDs: Set<SidebarID> {
        var ids = Set<SidebarID>()
        for ws in store.workspaces {
            ids.insert(.workspace(ws.id))
        }
        for grp in store.groups {
            ids.insert(.group(grp.id))
        }
        return ids
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

    private var groupDeleteTitle: String {
        if let name = store.groupDeleteConfirmation?.groupName {
            return "Delete \"\(name)\"?"
        }
        return "Delete group?"
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
            Button("Group Selected Workspaces...") {
                store.send(.requestBulkCreateGroup)
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
        moveToGroupMenu(workspaceID: workspaceID)
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

    /// "Move to Group ▸" submenu attached to a workspace row's context menu.
    @ViewBuilder
    private func moveToGroupMenu(workspaceID: UUID) -> some View {
        let currentGroupID = store.state.groupID(forWorkspace: workspaceID)
        Menu("Move to Group") {
            if currentGroupID != nil {
                Button("Remove from Group") {
                    store.send(.moveWorkspaceToGroup(
                        workspaceID: workspaceID, groupID: nil, index: nil
                    ))
                }
                Divider()
            }
            if !store.groups.isEmpty {
                ForEach(store.groups) { group in
                    Button(group.name) {
                        store.send(.moveWorkspaceToGroup(
                            workspaceID: workspaceID,
                            groupID: group.id,
                            index: nil
                        ))
                    }
                    .disabled(group.id == currentGroupID)
                }
                Divider()
            }
            Button("New Group...") {
                let placeholder = defaultGroupName(existing: store.groups)
                store.send(.createGroup(
                    name: placeholder,
                    color: nil,
                    insertAfter: nil,
                    initialWorkspaceIDs: [workspaceID],
                    autoRename: true
                ))
            }
        }
    }

    /// Context menu shown on a group header. Handles rename, color, collapse,
    /// and delete (which routes through the confirmation alert).
    @ViewBuilder
    private func groupContextMenu(groupID: UUID, group: WorkspaceGroup) -> some View {
        Button("Rename...") {
            store.send(.beginRenameGroup(groupID))
        }
        Menu("Color") {
            Button("None") {
                store.send(.setGroupColor(id: groupID, color: nil))
            }
            Divider()
            ForEach(WorkspaceColor.allCases) { color in
                Button(color.displayName) {
                    store.send(.setGroupColor(id: groupID, color: color))
                }
            }
        }
        Button(group.isCollapsed ? "Expand" : "Collapse") {
            store.send(.toggleGroupCollapse(groupID))
        }
        Divider()
        Button("Delete Group...", role: .destructive) {
            store.send(.requestGroupDelete(groupID))
        }
    }

    private func workspaceRow(
        workspaceStore: StoreOf<WorkspaceFeature>,
        depth: Int
    ) -> some View {
        WithPerceptionTracking {
            let workspaceID = workspaceStore.state.id
            let flatIndex = store.workspaces.index(id: workspaceID) ?? 0
            let isDragging = draggedWorkspaceID == workspaceID

            let aggregateStatus = aggregateGitStatus(for: workspaceStore.state)

            WorkspaceRowView(
                name: workspaceStore.name,
                color: workspaceStore.color,
                paneCount: workspaceStore.panes.count,
                repoCount: workspaceStore.repoAssociations.count,
                gitStatus: aggregateStatus,
                isActive: workspaceID == store.activeWorkspaceID,
                index: flatIndex,
                waitingPaneCount: workspaceStore.panes.count(where: { $0.status == .waitingForInput }),
                hasRunningPanes: workspaceStore.panes.contains { $0.status == .running },
                isSelected: store.selectedWorkspaceIDs.contains(workspaceID),
                leadingInset: depth > 0 ? 16 : 0
            )
            .padding(.horizontal, 8)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowHeightsKey.self,
                        value: [.workspace(workspaceID): geo.size.height]
                    )
                }
            )
            .offset(y: isDragging ? dragCurrentY - dragGrabOffset - workspaceStartY(workspaceID) : 0)
            .zIndex(isDragging ? 1 : 0)
            .opacity(isDragging ? 0.8 : 1)
            .scaleEffect(isDragging ? 1.03 : 1.0)
            .shadow(color: isDragging ? .black.opacity(0.3) : .clear, radius: 4, y: 2)
            .animation(isDragging ? .none : .easeInOut(duration: 0.15), value: store.topLevelOrder)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("workspaceList"))
                    .onChanged { value in
                        guard allHeightsMeasured else { return }
                        if draggedWorkspaceID == nil {
                            let startY = workspaceStartY(workspaceID)
                            draggedWorkspaceID = workspaceID
                            dragGrabOffset = value.startLocation.y - startY
                        }
                        dragCurrentY = value.location.y
                        let target = resolveCurrentDropTarget(
                            cursorY: value.location.y,
                            draggedID: workspaceID
                        )
                        currentDropTarget = target
                        // Live-apply only same-container moves (top-level
                        // reorder or within-same-group reorder). Cross-
                        // container moves wait for release so the dragged
                        // row doesn't teleport into a group mid-drag —
                        // the indicator line/tint shows intent instead.
                        if let target,
                           isSameContainerMove(target: target, sourceID: workspaceID)
                        {
                            applyDropTarget(target, workspaceID: workspaceID)
                        }
                    }
                    .onEnded { _ in
                        let target = currentDropTarget
                        let sourceID = workspaceID
                        let isCrossContainer = target.map {
                            !isSameContainerMove(target: $0, sourceID: sourceID)
                        } ?? false
                        withAnimation(.easeInOut(duration: 0.15)) {
                            draggedWorkspaceID = nil
                            dragCurrentY = 0
                            dragGrabOffset = 0
                            currentDropTarget = nil
                        }
                        if let target, isCrossContainer {
                            applyDropTarget(target, workspaceID: sourceID)
                        }
                    }
            )
            .onTapGesture {
                // Clicking any row while a group rename is in progress should
                // commit the rename via focus loss.
                if store.renamingGroupID != nil {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
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
        // Every top-level workspace must be measured, plus every group header.
        // Child workspaces inside expanded groups also need measurement so
        // group-block heights are accurate.
        for item in store.topLevelOrder {
            switch item {
            case .workspace(let id):
                if rowHeights[.workspace(id)] == nil { return false }
            case .group(let gid):
                if rowHeights[.group(gid)] == nil { return false }
                if let group = store.groups[id: gid], !group.isCollapsed {
                    for childID in group.childOrder where store.workspaces[id: childID] != nil {
                        if rowHeights[.workspace(childID)] == nil { return false }
                    }
                }
            }
        }
        return true
    }

    /// Total vertical space consumed by one top-level entry, including any
    /// expanded child workspaces or the empty-group placeholder.
    private func topLevelItemHeight(_ item: SidebarID) -> CGFloat {
        switch item {
        case .workspace(let id):
            return rowHeights[.workspace(id)] ?? 0
        case .group(let gid):
            var h = rowHeights[.group(gid)] ?? 0
            guard let group = store.groups[id: gid], !group.isCollapsed else { return h }
            let children = group.childOrder.filter { store.workspaces[id: $0] != nil }
            if children.isEmpty {
                // GroupEmptyRow is not measured; its approximate laid-out height.
                h += Self.groupEmptyRowHeight
            } else {
                for childID in children {
                    h += rowHeights[.workspace(childID)] ?? 0
                }
            }
            return h
        }
    }

    /// Y of the resting top edge of the given workspace row in the drag
    /// coordinate space. Walks `topLevelOrder` and descends into expanded
    /// groups as needed. Returns `contentVerticalPadding` offset + cumulative
    /// row heights.
    private func workspaceStartY(_ id: UUID) -> CGFloat {
        var y: CGFloat = Self.contentVerticalPadding
        for entry in store.topLevelOrder {
            switch entry {
            case .workspace(let wid):
                if wid == id { return y }
                y += rowHeights[.workspace(wid)] ?? 0
            case .group(let gid):
                y += rowHeights[.group(gid)] ?? 0
                guard let group = store.groups[id: gid], !group.isCollapsed else { continue }
                let children = group.childOrder.filter { store.workspaces[id: $0] != nil }
                if children.isEmpty {
                    y += Self.groupEmptyRowHeight
                } else {
                    for childID in children {
                        if childID == id { return y }
                        y += rowHeights[.workspace(childID)] ?? 0
                    }
                }
            }
        }
        return y
    }

    /// Resolve the DropTarget under the cursor during an active drag.
    private func resolveCurrentDropTarget(cursorY: CGFloat, draggedID: UUID) -> DropTarget? {
        let zones = dropZones(
            topLevelOrder: store.topLevelOrder,
            groups: store.groups,
            workspaces: store.workspaces,
            rowHeights: rowHeights,
            draggedID: draggedID,
            startY: Self.contentVerticalPadding,
            emptyPlaceholderHeight: Self.groupEmptyRowHeight
        )
        return resolveDropTarget(zones: zones, cursorY: cursorY)
    }

    /// Overlay rendered inside the VStack's coordinate space during a
    /// drag. Shows a 2pt accent line for between-rows drops and a
    /// subtle tint on the group header for onto-group drops.
    ///
    /// Same-container moves are live-reordered via the reducer, so the
    /// neighbouring rows animate into place; the indicator would be
    /// redundant and is suppressed. Cross-container moves (e.g.
    /// dragging a top-level workspace into a group) are previewed, so
    /// the indicator shows the intended landing spot.
    @ViewBuilder
    private var dropIndicatorOverlay: some View {
        if let draggedID = draggedWorkspaceID,
           let target = currentDropTarget,
           !isSameContainerMove(target: target, sourceID: draggedID)
        {
            let zones = dropZones(
                topLevelOrder: store.topLevelOrder,
                groups: store.groups,
                workspaces: store.workspaces,
                rowHeights: rowHeights,
                draggedID: draggedID,
                startY: Self.contentVerticalPadding,
                emptyPlaceholderHeight: Self.groupEmptyRowHeight
            )

            switch target {
            case .topLevel, .intoGroup:
                if let y = dropIndicatorLineY(for: target, zones: zones) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: y - 1)
                        .allowsHitTesting(false)
                }
            case .ontoGroupHeader(let gid):
                if let (yTop, yBottom) = groupHeaderYRange(groupID: gid, zones: zones) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(height: yBottom - yTop)
                        .offset(y: yTop)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Y coordinate (in drag coordinate space) where the between-rows
    /// drop line should render. Nil for `.ontoGroupHeader` targets,
    /// which render as a tint instead.
    private func dropIndicatorLineY(for target: DropTarget, zones: [DropZone]) -> CGFloat? {
        switch target {
        case .topLevel(let index):
            // Find the zone whose post-remove top-level index equals `index`
            // (drop appears at its top edge).
            for zone in zones {
                switch zone.kind {
                case .topLevelWorkspace(_, let postIdx) where postIdx == index:
                    return zone.yTop
                case .groupHeader(_, let postIdx) where postIdx == index:
                    return zone.yTop
                default:
                    continue
                }
            }
            // `index` past the last entry — drop at end; use bottom of the
            // last top-level zone.
            var lastY: CGFloat?
            for zone in zones {
                switch zone.kind {
                case .topLevelWorkspace, .groupHeader:
                    lastY = zone.yBottom
                default:
                    continue
                }
            }
            return lastY

        case .intoGroup(let gid, let index):
            var lastChildBottom: CGFloat?
            for zone in zones {
                switch zone.kind {
                case .groupChild(let zGid, _, let childIdx) where zGid == gid:
                    if childIdx == index { return zone.yTop }
                    lastChildBottom = zone.yBottom
                case .groupEmpty(let zGid) where zGid == gid:
                    return zone.yTop
                default:
                    continue
                }
            }
            return lastChildBottom

        case .ontoGroupHeader:
            return nil
        }
    }

    private func groupHeaderYRange(groupID: UUID, zones: [DropZone]) -> (CGFloat, CGFloat)? {
        for zone in zones {
            if case .groupHeader(let g, _) = zone.kind, g == groupID {
                return (zone.yTop, zone.yBottom)
            }
        }
        return nil
    }

    /// True when applying `target` keeps the workspace in its current
    /// container (top-level, or the same group). Same-container moves
    /// get live-applied during drag so neighbouring rows animate; cross-
    /// container moves are deferred until release.
    private func isSameContainerMove(target: DropTarget, sourceID: UUID) -> Bool {
        let sourceGroupID = store.state.groupID(forWorkspace: sourceID)
        switch target {
        case .topLevel:
            return sourceGroupID == nil
        case .intoGroup(let gid, _):
            return sourceGroupID == gid
        case .ontoGroupHeader:
            return false
        }
    }

    /// Apply a resolved DropTarget via the appropriate reducer action.
    /// Uses `.moveWorkspace` for same-top-level reorders (preserves the
    /// `state.workspaces` visual-order mirror that row badges rely on);
    /// falls through to `.moveWorkspaceToGroup` for every case that
    /// touches a group.
    private func applyDropTarget(_ target: DropTarget, workspaceID: UUID) {
        let sourceGroupID = store.state.groupID(forWorkspace: workspaceID)
        switch target {
        case .topLevel(let index):
            if sourceGroupID == nil {
                store.send(.moveWorkspace(id: workspaceID, toIndex: index))
            } else {
                store.send(.moveWorkspaceToGroup(
                    workspaceID: workspaceID, groupID: nil, index: index
                ))
            }
        case .intoGroup(let groupID, let index):
            store.send(.moveWorkspaceToGroup(
                workspaceID: workspaceID, groupID: groupID, index: index
            ))
        case .ontoGroupHeader(let groupID):
            store.send(.moveWorkspaceToGroup(
                workspaceID: workspaceID, groupID: groupID, index: nil
            ))
        }
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
    nonisolated(unsafe) static var defaultValue: [SidebarID: CGFloat] = [:]
    static func reduce(value: inout [SidebarID: CGFloat], nextValue: () -> [SidebarID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
