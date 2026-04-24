import ComposableArchitecture
import SwiftUI

/// Sidebar list of all workspaces with selection and context menus.
struct WorkspaceListView: View {
    let store: StoreOf<AppReducer>
    @State private var draggedWorkspaceID: UUID?
    /// Group currently being dragged (drag on a group header). Mutually
    /// exclusive with `draggedWorkspaceID`; shares `dragCurrentY` and
    /// `dragGrabOffset`.
    @State private var draggedGroupID: UUID?
    @State private var dragCurrentY: CGFloat = 0
    @State private var dragGrabOffset: CGFloat = 0
    /// Current drop target under the cursor. Drives the indicator overlay.
    /// For same-container moves we ALSO live-apply via the reducer so the
    /// other rows shift smoothly under the drag — the indicator renders
    /// only for cross-container moves where the row is not live-reordered.
    @State private var currentDropTarget: DropTarget?
    @State private var rowHeights: [SidebarID: CGFloat] = [:]
    /// Measured height of the `GroupEmptyRow` placeholder. Kept in
    /// sync via `EmptyRowHeightKey` so drag math uses the real laid-
    /// out value (falls back to `groupEmptyRowHeight` until the first
    /// emission arrives). Prevents layout jumps when dragging into or
    /// past an empty group.
    @State private var measuredEmptyRowHeight: CGFloat?

    /// The collapsed group the spring-load timer is currently scheduled
    /// for (or has fired for). Reset when the cursor leaves the group
    /// or the drag ends — the persisted `isCollapsed` state never
    /// changes, so collapsing back is automatic.
    @State private var springLoadTargetID: UUID?
    @State private var springLoadTask: Task<Void, Never>?
    /// Group to render as if expanded during the drag, even though its
    /// persistent `isCollapsed` is still true. Set by the spring-load
    /// timer once the cursor has hovered long enough.
    @State private var springLoadedGroupID: UUID?

    /// Ordered list of workspaces being moved together as a unit, when
    /// the user grabs a row that's part of a multi-selection. Empty for
    /// single-workspace drags. Multi-drags live-apply only the grabbed
    /// row during the drag (1-row cursor-tracking gap) and consolidate
    /// the full selection atomically on release.
    @State private var multiDragIDs: [UUID] = []
    /// Non-grabbed members of `multiDragIDs` — collapsed to 0 height
    /// and removed from layout for the duration of the drag. Makes it
    /// obvious that the whole selection is moving rather than just the
    /// grabbed row, and keeps the list from looking like it's leaving
    /// the other selected rows behind in their original slots.
    @State private var hiddenMultiDragIDs: Set<UUID> = []

    /// Post-release "land into collapsed group" override. When dropping a
    /// row onto a collapsed group that stays collapsed, the default
    /// release (offset → 0 + entries-change fade) makes the row visually
    /// fly back to its top-level slot before fading — confusing, since
    /// the workspace actually went into the group. `landingPreview`
    /// pins the row's offset to the group header's Y so it animates
    /// "into" the group and fades there instead.
    private struct LandingPreview: Equatable {
        let workspaceID: UUID
        let offsetY: CGFloat
    }

    @State private var landingPreview: LandingPreview?

    /// Underlying `NSScrollView` hosting the sidebar content. Captured
    /// via `ScrollViewFinder` once the view is in a window. Provides
    /// the authoritative scroll offset + viewport height and is driven
    /// directly during auto-scroll for pixel-perfect control.
    @State private var hostScrollView: NSScrollView?
    /// Active auto-scroll loop during a drag near the viewport edges.
    @State private var autoScrollTask: Task<Void, Never>?
    /// Cursor Y in the scroll viewport (viewport-relative), captured on
    /// every `onChanged`. During auto-scroll the OS won't fire drag
    /// events (the mouse hasn't moved in screen space), so each tick
    /// recomputes `dragCurrentY = dragViewportY + scrollOffset` to keep
    /// the dragged row and drop indicator current as content scrolls
    /// underneath the stationary cursor.
    @State private var dragViewportY: CGFloat = 0

    /// Vertical padding inside the ScrollView's VStack. Drop zones are
    /// computed in the same coordinate space, so they shift by this
    /// amount from the VStack's (0,0) origin.
    private static let contentVerticalPadding: CGFloat = 4
    /// Approximate laid-out height of `GroupEmptyRow`; kept in sync
    /// with that view so drop-zone math matches the visual layout.
    /// Matches `WorkspaceRowView`'s minimum height (24pt color bar +
    /// 8pt×2 vertical padding) — without this equivalence, live-
    /// applying a drag into an empty group would jump the layout.
    private static let groupEmptyRowHeight: CGFloat = 40
    /// How long the cursor must hover over a collapsed group header
    /// before the group auto-expands for the remainder of the drag.
    /// Matches the default `group-spring-delay` in the Phase 4 plan.
    private static let springLoadDelayMillis: Int = 650
    /// Distance from the viewport top/bottom edge at which auto-scroll
    /// engages during a drag.
    private static let autoScrollEdgeThreshold: CGFloat = 40
    /// Point delta applied per auto-scroll tick. 3pt / 15ms ≈ 200pt/s.
    /// Small step + short interval keeps the scroll feeling smooth
    /// (~66fps) while matching the Phase 4 target speed.
    private static let autoScrollStep: CGFloat = 3
    /// Auto-scroll tick interval (milliseconds).
    private static let autoScrollIntervalMillis: Int = 15

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { outer in
                ScrollView {
                    let entries = currentRenderedEntries
                    VStack(spacing: 0) {
                        // Captures the underlying NSScrollView so auto-scroll
                        // can drive pixel-perfect scrolling and query
                        // documentVisibleRect for viewport detection.
                        ScrollViewFinder { sv in
                            if hostScrollView !== sv { hostScrollView = sv }
                        }
                        .frame(height: 0)

                        ForEach(entries) { entry in
                            entryView(for: entry)
                                .overlay(alignment: .leading) {
                                    if let color = groupChildGuideColor(for: entry) {
                                        // Thin vertical guide running the
                                        // length of the group's children.
                                        // Per-row overlays chain together
                                        // across the spacing-0 VStack into
                                        // one continuous line, aligned with
                                        // the folder icon in the header.
                                        Rectangle()
                                            .fill(color)
                                            .frame(width: 1.5)
                                            .padding(.leading, Self.groupGuideLeadingInset)
                                            .allowsHitTesting(false)
                                    }
                                }
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
                                Button("New Workspace") {
                                    store.send(.showNewWorkspaceSheet())
                                }
                                Button("New Group") {
                                    let placeholder = defaultGroupName(existing: store.groups)
                                    store.send(.createGroup(name: placeholder, autoRename: true))
                                }
                            }
                    }
                    .coordinateSpace(name: "workspaceList")
                    .padding(.vertical, 4)
                    // Keep row content clear of the overlay scroller that
                    // appears on the trailing edge during scrolling, so the
                    // ⌘N badge doesn't get clipped by it.
                    .padding(.trailing, 8)
                    .frame(minHeight: outer.size.height, alignment: .top)
                    .animation(
                        // Keyed on the rendered entry list (not just the
                        // visible workspace order) so collapsing an
                        // *empty* group animates too — the placeholder
                        // insert/remove isn't reflected in the workspace
                        // order, but it is in the entries.
                        .spring(response: 0.35, dampingFraction: 0.8),
                        value: entries
                    )
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
                .onPreferenceChange(EmptyRowHeightKey.self) { h in
                    if h > 0 { measuredEmptyRowHeight = h }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                selectionHeader
            }
            .safeAreaInset(edge: .bottom) {
                Menu {
                    Button("New Workspace") { store.send(.showNewWorkspaceSheet()) }
                    Button("New Group") {
                        let placeholder = defaultGroupName(existing: store.groups)
                        store.send(.createGroup(name: placeholder, autoRename: true))
                    }
                } label: {
                    Label("New Workspace", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                } primaryAction: {
                    store.send(.showNewWorkspaceSheet())
                }
                .menuStyle(.borderlessButton)
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
                    if confirmation.workspaceCount == 0 {
                        // Empty group: no workspaces to move or cascade.
                        // A single "Delete Group" is the only meaningful action.
                        Button("Delete Group", role: .destructive) {
                            store.send(.deleteGroup(id: confirmation.groupID, cascade: false))
                        }
                    } else {
                        Button("Move Workspaces to Top Level", role: .destructive) {
                            store.send(.deleteGroup(id: confirmation.groupID, cascade: false))
                        }
                        Button(
                            "Delete Group and \(confirmation.workspaceCount) Workspace\(confirmation.workspaceCount == 1 ? "" : "s")",
                            role: .destructive
                        ) {
                            store.send(.deleteGroup(id: confirmation.groupID, cascade: true))
                        }
                    }
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
            .sheet(isPresented: Binding(
                get: { store.groupCustomEmojiPrompt != nil },
                set: { if !$0 { store.send(.cancelGroupCustomEmoji) } }
            )) {
                if let prompt = store.groupCustomEmojiPrompt {
                    GroupCustomEmojiSheet(
                        groupName: prompt.groupName,
                        onConfirm: { emoji in
                            store.send(.confirmGroupCustomEmoji(emoji))
                        },
                        onCancel: { store.send(.cancelGroupCustomEmoji) }
                    )
                }
            }
        }
    }

    // MARK: - Entry rendering

    /// Horizontal position of the group guide line from the row's
    /// leading edge. Set to 18pt — aligned with the 4pt leading
    /// slot that carries the group header's folder icon and each
    /// root workspace's colour pill (slot spans 16–20pt; the guide
    /// sits against its leading side). The guide emanates down from
    /// the folder icon through the indent column of each child row.
    private static let groupGuideLeadingInset: CGFloat = 18

    /// Colour of the vertical guide line drawn behind child entries of
    /// an expanded group. Falls back to `.secondary` when the group
    /// has no colour, matching the outlined folder icon rendered in the
    /// header for uncoloured groups. `nil` for the group header itself
    /// and top-level workspaces.
    private func groupChildGuideColor(for entry: RenderedEntry) -> Color? {
        switch entry {
        case .groupHeader:
            return nil
        case .workspaceRow(let workspaceID, _):
            guard let gid = store.state.groupID(forWorkspace: workspaceID),
                  let group = store.groups[id: gid],
                  !group.isCollapsed
            else { return nil }
            return group.color?.color ?? Color.secondary
        case .groupEmpty(let groupID):
            guard let group = store.groups[id: groupID] else { return nil }
            return group.color?.color ?? Color.secondary
        }
    }

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
                groupHeaderEntry(groupID: groupID, group: group)
            }
        case .groupEmpty(let groupID):
            GroupEmptyRow()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: EmptyRowHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .id("empty-\(groupID.uuidString)")
                // Animate the placeholder's reorder (idle → phantom
                // position below the dragged row, and back) in step
                // with the surrounding workspace rows.
                .animation(
                    .spring(response: 0.35, dampingFraction: 0.8),
                    value: sidebarLayoutKey
                )
                .contextMenu {
                    Button("New Workspace") {
                        store.send(.showNewWorkspaceSheet(groupID: groupID))
                    }
                    if let group = store.groups[id: groupID] {
                        Divider()
                        groupContextMenu(groupID: groupID, group: group)
                    }
                }
        }
    }

    /// Group header with live drag + visual treatment. The DragGesture is
    /// only attached when the group is NOT being renamed — otherwise a
    /// click-drag inside the inline rename TextField would start a group
    /// reorder instead of selecting text / moving the caret.
    @ViewBuilder
    private func groupHeaderEntry(groupID: UUID, group: WorkspaceGroup) -> some View {
        let children = group.childOrder.compactMap { store.workspaces[id: $0] }
        let count = children.count
        let hasWaitingPanes = children.contains { ws in
            ws.panes.contains { $0.status == .waitingForInput }
        }
        let hasRunningPanes = children.contains { ws in
            ws.panes.contains { $0.status == .running }
        }
        let isRenamingThis = store.renamingGroupID == groupID
        let isDraggingThisGroup = draggedGroupID == groupID
        let row = GroupHeaderRow(
            name: group.name,
            color: group.color,
            icon: group.icon,
            isCollapsed: group.isCollapsed,
            workspaceCount: count,
            isRenaming: isRenamingThis,
            hasWaitingPanes: hasWaitingPanes,
            hasRunningPanes: hasRunningPanes,
            onToggleCollapse: {
                // If a different group is being renamed, clicking any row
                // should commit its name via focus loss.
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
        .offset(y: isDraggingThisGroup ? dragCurrentY - dragGrabOffset - groupStartY(groupID) : 0)
        .zIndex(isDraggingThisGroup ? 1 : 0)
        .opacity(isDraggingThisGroup ? 0.8 : 1)
        .scaleEffect(isDraggingThisGroup ? 1.03 : 1.0)
        .shadow(color: isDraggingThisGroup ? .black.opacity(0.3) : .clear, radius: 4, y: 2)
        .animation(isDraggingThisGroup ? .none : .spring(response: 0.35, dampingFraction: 0.8), value: store.topLevelOrder)

        if isRenamingThis {
            row.contextMenu {
                groupContextMenu(groupID: groupID, group: group)
            }
        } else {
            row
                .gesture(
                    DragGesture(minimumDistance: 5, coordinateSpace: .named("workspaceList"))
                        .onChanged { value in
                            guard allHeightsMeasured else { return }
                            // Cursor-tracking state updates must NOT animate
                            // (VStack has an unconditional `.animation` so
                            // every state change would otherwise spring).
                            var liveTxn = Transaction()
                            liveTxn.disablesAnimations = true
                            withTransaction(liveTxn) {
                                if draggedGroupID == nil {
                                    let startY = groupStartY(groupID)
                                    draggedGroupID = groupID
                                    dragGrabOffset = value.startLocation.y - startY
                                }
                                dragCurrentY = value.location.y
                                dragViewportY = value.location.y - (hostScrollView?.documentVisibleRect.origin.y ?? 0)
                            }
                            updateAutoScroll(cursorContentY: value.location.y)
                            let target = resolveCurrentTopLevelDropTarget(
                                cursorY: value.location.y,
                                draggedGroupID: groupID
                            )
                            if case .topLevel(let idx) = target {
                                // Views self-animate via their own
                                // `.animation(value:)` modifiers keyed
                                // on sidebarLayoutKey / topLevelOrder;
                                // wrapping in withAnimation here would
                                // fight the grabbed group header's
                                // `.animation(.none)` override.
                                store.send(.moveGroup(id: groupID, toIndex: idx))
                            }
                        }
                        .onEnded { _ in
                            cancelAutoScroll()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                draggedGroupID = nil
                                dragCurrentY = 0
                                dragViewportY = 0
                                dragGrabOffset = 0
                            }
                        }
                )
                .contextMenu {
                    groupContextMenu(groupID: groupID, group: group)
                }
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
        changeIconMenu(groupID: groupID)
        Button(group.isCollapsed ? "Expand" : "Collapse") {
            store.send(.toggleGroupCollapse(groupID))
        }
        Divider()
        Button("Delete Group...", role: .destructive) {
            store.send(.requestGroupDelete(groupID))
        }
    }

    /// Curated SF Symbol palette. Names paired with friendly labels
    /// because raw symbol names (e.g., `testtube.2`) aren't readable
    /// in a menu. Folder is first so the user can explicitly set it
    /// alongside the other options; `Reset to Folder` below clears
    /// the custom icon back to the default which renders the same
    /// glyph.
    private static let groupIconSymbolPalette: [(systemName: String, label: String)] = [
        ("folder", "Folder"),
        ("tray", "Tray"),
        ("archivebox", "Archive"),
        ("star", "Star"),
        ("flag", "Flag"),
        ("pin", "Pin"),
        ("bookmark", "Bookmark"),
        ("hammer", "Build"),
        ("testtube.2", "Tests"),
        ("terminal", "Terminal"),
        ("shippingbox", "Package"),
        ("book", "Docs"),
        ("sparkles", "AI")
    ]

    /// Curated emoji palette matching the plan-doc list.
    private static let groupIconEmojiPalette: [String] = [
        "📁", "📂", "⭐", "🔥", "💼", "🎯",
        "🧪", "🐛", "📝", "🚀", "☁️", "🎨"
    ]

    private func changeIconMenu(groupID: UUID) -> some View {
        Menu("Change Icon") {
            Menu("Symbol") {
                ForEach(Self.groupIconSymbolPalette, id: \.systemName) { entry in
                    Button {
                        store.send(.setGroupIcon(id: groupID, icon: .systemName(entry.systemName)))
                    } label: {
                        Label(entry.label, systemImage: entry.systemName)
                    }
                }
            }
            Menu("Emoji") {
                ForEach(Self.groupIconEmojiPalette, id: \.self) { emoji in
                    Button(emoji) {
                        store.send(.setGroupIcon(id: groupID, icon: .emoji(emoji)))
                    }
                }
            }
            Button("Custom Emoji...") {
                store.send(.requestGroupCustomEmoji(groupID))
            }
            Divider()
            Button("Reset to Folder") {
                store.send(.setGroupIcon(id: groupID, icon: nil))
            }
        }
    }

    private func workspaceRow(
        workspaceStore: StoreOf<WorkspaceFeature>,
        depth: Int
    ) -> some View {
        WithPerceptionTracking {
            let workspaceID = workspaceStore.state.id
            // Use the visible sidebar order so the ⌘N badge matches
            // the navigation action that activates the workspace. A
            // bulk top-level drag dispatches `.moveWorkspacesToGroup`
            // which doesn't mirror into `state.workspaces`, so the
            // old insertion-order index would go stale immediately
            // after a multi-select drag.
            let flatIndex = store.state.visibleWorkspaceOrder.firstIndex(of: workspaceID) ?? 0
            let isDragging = draggedWorkspaceID == workspaceID
            // True while the row is playing the "falling into group" drop
            // animation — styled smaller + more transparent so it reads
            // as being consumed by the group rather than flying away.
            let isLanding = landingPreview?.workspaceID == workspaceID

            let aggregateStatus = aggregateGitStatus(for: workspaceStore.state)
            // Show the dragged row nested when the current target is a
            // preview-only group drop (empty group `.intoGroup` or any
            // `.ontoGroupHeader`) so the visual matches where the
            // workspace will actually land on release. For live-applied
            // targets the state already reflects the new container, so
            // `depth` is authoritative.
            let previewNestedInGroup = isDragging && dragPreviewGroupID != nil
            let effectiveDepth = previewNestedInGroup ? max(depth, 1) : depth

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
                // Use a single interpolated value so the depth change
                // slides smoothly. 24pt matches the old layout's
                // 16pt Spacer + 8pt HStack spacing.
                leadingInset: effectiveDepth > 0 ? 24 : 0
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
            .overlay(alignment: .trailing) {
                if isDragging, multiDragIDs.count > 1 {
                    Text("+\(multiDragIDs.count - 1)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(.trailing, 12)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(isDragging || isLanding ? 1 : 0)
            .opacity(isLanding ? 0.15 : (isDragging ? 0.8 : 1))
            // Drag lift: centered 1.03. Cleared when landing so the
            // shrink below starts from identity.
            .scaleEffect(isDragging && !isLanding ? 1.03 : 1.0)
            // Landing shrink: scale in place (center anchor) so the row
            // doesn't drift sideways as it collapses into the group.
            .scaleEffect(isLanding ? 0.2 : 1.0)
            .shadow(color: isDragging && !isLanding ? .black.opacity(0.3) : .clear, radius: 4, y: 2)
            // Animate reorders for non-grabbed rows. The grabbed row
            // gets `.none` so its leadingInset and styling changes
            // don't spring against cursor tracking. `sidebarLayoutKey`
            // covers topLevelOrder + every group's childOrder.
            .animation(
                isDragging ? .none : .spring(response: 0.35, dampingFraction: 0.8),
                value: sidebarLayoutKey
            )
            // Depth (leadingInset) animates for everyone, including
            // the grabbed row — horizontal inset doesn't compete with
            // cursor tracking since `.offset` is applied after this
            // modifier and is therefore excluded from the animation.
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: effectiveDepth)
            // Cursor-tracking offset is applied AFTER the animation
            // modifiers so neither `sidebarLayoutKey` nor
            // `effectiveDepth` transitions cover it. If an animation
            // modifier covered this offset, its value change (the
            // diff in `workspaceStartY` across containers) would
            // spring-interpolate while the VStack's layout position
            // snaps — the grabbed row would bounce by ~half the
            // container-jump height at the animation midpoint. Keep
            // this last so the offset snaps straight to the new
            // cursor-tracking value every frame.
            .offset(y: rowOffsetY(workspaceID: workspaceID, isDragging: isDragging))
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("workspaceList"))
                    .onChanged { value in
                        guard allHeightsMeasured else { return }
                        // Cursor-tracking state updates must not animate
                        // (the VStack has an unconditional spring that
                        // would otherwise apply to the dragged row's
                        // offset and make it lag the cursor).
                        var liveTxn = Transaction()
                        liveTxn.disablesAnimations = true
                        withTransaction(liveTxn) {
                            if draggedWorkspaceID == nil {
                                let startY = workspaceStartY(workspaceID)
                                draggedWorkspaceID = workspaceID
                                dragGrabOffset = value.startLocation.y - startY
                                // If the grabbed row is part of a multi-
                                // selection (>1 items), capture the ordered
                                // list so the drop applies to all of them.
                                let sel = store.selectedWorkspaceIDs
                                if sel.count > 1, sel.contains(workspaceID) {
                                    let ordered = workspaceIDs(sortedBySidebar: sel)
                                    multiDragIDs = ordered
                                    hiddenMultiDragIDs = Set(ordered).subtracting([workspaceID])
                                } else {
                                    multiDragIDs = []
                                    hiddenMultiDragIDs = []
                                }
                            }
                            dragCurrentY = value.location.y
                            dragViewportY = value.location.y - (hostScrollView?.documentVisibleRect.origin.y ?? 0)
                        }
                        updateAutoScroll(cursorContentY: value.location.y)
                        // Visually treat every drag (single or multi) as a
                        // one-row move centred on the grabbed workspace.
                        // This keeps the in-list gap to a single row so
                        // it's obvious where the grabbed row is landing —
                        // a bulk N-row gap would hide the target. The
                        // full selection is consolidated atomically on
                        // release.
                        let target = resolveCurrentDropTarget(
                            cursorY: value.location.y,
                            draggedIDs: [workspaceID]
                        )
                        currentDropTarget = target

                        // Spring-load: schedule (or cancel) the auto-expand
                        // timer based on whether the cursor is hovering a
                        // collapsed group.
                        if let target, let gid = collapsedGroupUnderCursor(target) {
                            scheduleSpringLoad(for: gid)
                        } else if springLoadTask != nil || springLoadedGroupID != nil {
                            cancelSpringLoad()
                        }

                        // Live-apply every target that points at a
                        // specific slot (same- or cross-container) so
                        // neighbouring rows shift as the cursor moves.
                        // `.ontoGroupHeader` stays preview-only. Views
                        // self-animate via their `.animation(value:
                        // sidebarLayoutKey)` modifiers; the grabbed
                        // row overrides that to `.none` so its
                        // `.offset` (cursor tracking) isn't spring-
                        // interpolated against the VStack's reflow.
                        if let target, shouldLiveApplyDropTarget(target) {
                            applyDropTarget(target, workspaceID: workspaceID)
                        }
                    }
                    .onEnded { _ in
                        let singleTarget = currentDropTarget
                        let sourceID = workspaceID
                        let bulkIDs = multiDragIDs
                        // Only targets that aren't already live-applied
                        // need committing on release (currently just
                        // `.ontoGroupHeader`).
                        let singleNeedsRelease = singleTarget.map {
                            !shouldLiveApplyDropTarget($0)
                        } ?? false
                        // On release of a multi-drag, consolidate the full
                        // selection atomically. Prefer the post-bulk-remove
                        // walker result at the current cursor; fall back
                        // to the grabbed row's current position when the
                        // cursor sits inside a vacated slot (common after
                        // the single live-apply).
                        var bulkTarget: DropTarget?
                        if !bulkIDs.isEmpty {
                            bulkTarget = resolveCurrentDropTarget(
                                cursorY: dragCurrentY,
                                draggedIDs: Set(bulkIDs)
                            )
                            if bulkTarget == nil {
                                bulkTarget = bulkTargetAtGrabbedPosition(
                                    grabbedID: sourceID,
                                    bulkIDs: Set(bulkIDs)
                                )
                            }
                        }
                        // Cancel the pending spring-load timer. Keep
                        // `springLoadedGroupID` though — a spring-loaded
                        // group should stay visually expanded through
                        // the drop animation so the row lands in a
                        // visible slot; it collapses in the animation's
                        // completion below.
                        springLoadTask?.cancel()
                        springLoadTask = nil
                        springLoadTargetID = nil
                        let persistingSpringLoad = springLoadedGroupID
                        cancelAutoScroll()

                        // Special case: single-drag release onto a
                        // collapsed group header that will stay collapsed.
                        // Animate the row into the header's position so
                        // the workspace visually "falls into" the group,
                        // then commit the drop. Skipped when the group is
                        // currently spring-loaded (visibly expanded) —
                        // the normal animation already lands the row in
                        // a visible child slot before the group collapses.
                        if bulkIDs.isEmpty, singleNeedsRelease,
                           case .ontoGroupHeader(let gid) = singleTarget,
                           store.groups[id: gid]?.isCollapsed == true,
                           persistingSpringLoad != gid,
                           !store.settings.expandGroupOnWorkspaceDrop {
                            let landingY = groupStartY(gid) - workspaceStartY(sourceID)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                landingPreview = LandingPreview(workspaceID: sourceID, offsetY: landingY)
                                currentDropTarget = nil
                            } completion: {
                                // Row has "landed" at the header — commit
                                // the move. The row exits via the entries
                                // change; `landingPreview` keeps its
                                // offset pinned so the fade plays at the
                                // header rather than the old slot.
                                applyDropTarget(.ontoGroupHeader(groupID: gid), workspaceID: sourceID)
                                draggedWorkspaceID = nil
                                dragCurrentY = 0
                                dragViewportY = 0
                                dragGrabOffset = 0
                                multiDragIDs = []
                                hiddenMultiDragIDs = []
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(400))
                                    landingPreview = nil
                                }
                            }
                            return
                        }

                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            draggedWorkspaceID = nil
                            dragCurrentY = 0
                            dragViewportY = 0
                            dragGrabOffset = 0
                            currentDropTarget = nil
                            multiDragIDs = []
                            hiddenMultiDragIDs = []
                            // Commit the drop inside the animation
                            // transaction so the placeholder fade,
                            // row reorder, and leadingInset change
                            // all spring together.
                            if !bulkIDs.isEmpty {
                                if let bulkTarget {
                                    applyBulkDropTarget(bulkTarget, workspaceIDs: bulkIDs)
                                }
                            } else if singleNeedsRelease, let singleTarget {
                                applyDropTarget(singleTarget, workspaceID: sourceID)
                            }
                        } completion: {
                            // After the row has settled, collapse any
                            // spring-loaded group we kept open through
                            // the drop animation. Only relevant when the
                            // group is still persisted as collapsed —
                            // drops that expand the group (via
                            // expandGroupOnWorkspaceDrop) already cleared
                            // isCollapsed so there's nothing to do.
                            if persistingSpringLoad != nil {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    springLoadedGroupID = nil
                                }
                            }
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

    /// Treats a group as expanded if its persistent state says so OR
    /// the drag has spring-loaded it. The group currently being
    /// dragged by its header is forced collapsed for the duration of
    /// the drag so it moves as a single-row block (plan 4d). Persisted
    /// `isCollapsed` is not touched — it restores naturally on release.
    private func isEffectivelyExpanded(_ group: WorkspaceGroup) -> Bool {
        if group.id == draggedGroupID { return false }
        return !group.isCollapsed || springLoadedGroupID == group.id
    }

    /// Rendered sidebar entries as the view should draw them right now.
    /// Mirrors `AppReducer.State.renderedEntries` but respects the
    /// transient spring-load expansion so children appear under a
    /// hover-expanded collapsed group without persisting the change.
    /// During a multi-drag, non-grabbed selected workspaces are
    /// filtered out so the list collapses around the grabbed row
    /// instead of leaving the other selected rows visible in place.
    private var currentRenderedEntries: [RenderedEntry] {
        var entries: [RenderedEntry] = []
        for item in store.topLevelOrder {
            switch item {
            case .workspace(let wsID):
                guard store.workspaces[id: wsID] != nil else { continue }
                if hiddenMultiDragIDs.contains(wsID) { continue }
                entries.append(.workspaceRow(workspaceID: wsID, depth: 0))
            case .group(let gID):
                guard let group = store.groups[id: gID] else { continue }
                entries.append(.groupHeader(groupID: gID))
                if isEffectivelyExpanded(group) {
                    let children = group.childOrder.filter {
                        store.workspaces[id: $0] != nil && !hiddenMultiDragIDs.contains($0)
                    }
                    if children.isEmpty {
                        entries.append(.groupEmpty(groupID: gID))
                    } else {
                        for childID in children {
                            entries.append(.workspaceRow(workspaceID: childID, depth: 1))
                        }
                        // When a drag has live-applied its only member
                        // into this group, keep the placeholder visible
                        // below the dragged row. The placeholder shifts
                        // down like a dummy workspace getting pushed
                        // aside, and the group's total height stays
                        // constant through drag enter/leave so the list
                        // doesn't jump as the cursor sweeps over empty
                        // groups.
                        let nonDragged = children.filter { $0 != draggedWorkspaceID }
                        if nonDragged.isEmpty, draggedWorkspaceID != nil {
                            entries.append(.groupEmpty(groupID: gID))
                        }
                    }
                }
            }
        }
        return entries
    }

    /// Height used for empty-group placeholders in drag math. Prefers
    /// the runtime-measured value (exact match with what's on screen)
    /// and falls back to the constant until the first layout pass.
    private var effectiveEmptyRowHeight: CGFloat {
        measuredEmptyRowHeight ?? Self.groupEmptyRowHeight
    }

    /// Flat list of every sidebar entry — top-level items interleaved
    /// with each group's children. Changes whenever `topLevelOrder`
    /// OR any group's `childOrder` mutates, so using it as an
    /// `.animation(value:)` key reliably picks up every drag-induced
    /// layout change (including cross-container moves that leave the
    /// read-only `visibleWorkspaceOrder` unchanged because a workspace
    /// stays at the same flat index).
    private var sidebarLayoutKey: [SidebarID] {
        var result: [SidebarID] = []
        for item in store.topLevelOrder {
            result.append(item)
            if case .group(let gid) = item, let group = store.groups[id: gid] {
                for child in group.childOrder {
                    result.append(.workspace(child))
                }
            }
        }
        return result
    }

    /// `rowHeights` with hidden multi-drag rows forced to 0 so every
    /// drag-math calculation (zones, cursor Y → target, grabbed row's
    /// resting Y) matches the collapsed on-screen layout.
    private var effectiveRowHeights: [SidebarID: CGFloat] {
        guard !hiddenMultiDragIDs.isEmpty else { return rowHeights }
        var h = rowHeights
        for id in hiddenMultiDragIDs {
            h[.workspace(id)] = 0
        }
        return h
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
                if let group = store.groups[id: gid], isEffectivelyExpanded(group) {
                    for childID in group.childOrder where store.workspaces[id: childID] != nil {
                        if rowHeights[.workspace(childID)] == nil { return false }
                    }
                }
            }
        }
        return true
    }

    /// True when a group's only visible children are currently being
    /// dragged. Drives the phantom "No workspaces" placeholder shown
    /// below the dragged row so the group's slot stays reserved while
    /// the cursor hovers — prevents mid-drag list-height jumps when a
    /// workspace moves into an otherwise-empty group via live-apply.
    private func hasPhantomPlaceholder(_ group: WorkspaceGroup) -> Bool {
        guard draggedWorkspaceID != nil else { return false }
        let visibleChildren = group.childOrder.filter {
            store.workspaces[id: $0] != nil && !hiddenMultiDragIDs.contains($0)
        }
        guard !visibleChildren.isEmpty else { return false }
        return visibleChildren.allSatisfy { $0 == draggedWorkspaceID }
    }

    /// Total vertical space consumed by one top-level entry, including any
    /// expanded child workspaces or the empty-group placeholder.
    private func topLevelItemHeight(_ item: SidebarID) -> CGFloat {
        let heights = effectiveRowHeights
        switch item {
        case .workspace(let id):
            return heights[.workspace(id)] ?? 0
        case .group(let gid):
            var h = heights[.group(gid)] ?? 0
            guard let group = store.groups[id: gid], isEffectivelyExpanded(group) else { return h }
            let children = group.childOrder.filter { store.workspaces[id: $0] != nil }
            if children.isEmpty {
                h += effectiveEmptyRowHeight
            } else {
                for childID in children {
                    h += heights[.workspace(childID)] ?? 0
                }
                if hasPhantomPlaceholder(group) {
                    h += effectiveEmptyRowHeight
                }
            }
            return h
        }
    }

    /// Offset applied to a workspace row. During an active drag the
    /// grabbed row tracks the cursor; when a `landingPreview` is set
    /// (release onto a collapsed group that stays collapsed) the row is
    /// pinned to a fixed target so it animates toward the group header
    /// and fades there rather than snapping back to its old slot.
    private func rowOffsetY(workspaceID: UUID, isDragging: Bool) -> CGFloat {
        if let landing = landingPreview, landing.workspaceID == workspaceID {
            return landing.offsetY
        }
        return isDragging ? dragCurrentY - dragGrabOffset - workspaceStartY(workspaceID) : 0
    }

    /// Y of the resting top edge of the given workspace row in the drag
    /// coordinate space. Walks `topLevelOrder` and descends into expanded
    /// groups as needed. Returns `contentVerticalPadding` offset + cumulative
    /// row heights.
    private func workspaceStartY(_ id: UUID) -> CGFloat {
        let heights = effectiveRowHeights
        var y: CGFloat = Self.contentVerticalPadding
        for entry in store.topLevelOrder {
            switch entry {
            case .workspace(let wid):
                if wid == id { return y }
                y += heights[.workspace(wid)] ?? 0
            case .group(let gid):
                y += heights[.group(gid)] ?? 0
                guard let group = store.groups[id: gid], isEffectivelyExpanded(group) else { continue }
                let children = group.childOrder.filter { store.workspaces[id: $0] != nil }
                if children.isEmpty {
                    y += effectiveEmptyRowHeight
                } else {
                    for childID in children {
                        if childID == id { return y }
                        y += heights[.workspace(childID)] ?? 0
                    }
                    if hasPhantomPlaceholder(group) {
                        y += effectiveEmptyRowHeight
                    }
                }
            }
        }
        return y
    }

    /// Y of the group header's resting top edge in drag coordinate space.
    private func groupStartY(_ groupID: UUID) -> CGFloat {
        let heights = effectiveRowHeights
        var y: CGFloat = Self.contentVerticalPadding
        for entry in store.topLevelOrder {
            switch entry {
            case .workspace(let wid):
                y += heights[.workspace(wid)] ?? 0
            case .group(let gid):
                if gid == groupID { return y }
                y += heights[.group(gid)] ?? 0
                guard let group = store.groups[id: gid], isEffectivelyExpanded(group) else { continue }
                let children = group.childOrder.filter { store.workspaces[id: $0] != nil }
                if children.isEmpty {
                    y += effectiveEmptyRowHeight
                } else {
                    for childID in children {
                        y += heights[.workspace(childID)] ?? 0
                    }
                    if hasPhantomPlaceholder(group) {
                        y += effectiveEmptyRowHeight
                    }
                }
            }
        }
        return y
    }

    /// Resolve the DropTarget for an active group drag (only top-level
    /// positions are valid — groups never nest inside other groups).
    private func resolveCurrentTopLevelDropTarget(cursorY: CGFloat, draggedGroupID: UUID) -> DropTarget? {
        let spans = topLevelDropZones(
            topLevelOrder: store.topLevelOrder,
            groups: store.groups,
            workspaces: store.workspaces,
            rowHeights: effectiveRowHeights,
            draggedGroupID: draggedGroupID,
            springLoadedGroupID: springLoadedGroupID,
            startY: Self.contentVerticalPadding,
            emptyPlaceholderHeight: effectiveEmptyRowHeight
        )
        return resolveTopLevelDropTarget(spans: spans, cursorY: cursorY)
    }

    /// Resolve the DropTarget under the cursor during an active drag.
    /// During the drag we walk with `draggedIDs = [grabbedID]` so the
    /// indicator + live-apply track a single-row gap. On release we
    /// re-walk with the full selection skipped to get the post-bulk-
    /// remove index for the atomic consolidate-on-drop reducer.
    private func resolveCurrentDropTarget(cursorY: CGFloat, draggedIDs: Set<UUID>) -> DropTarget? {
        let zones = dropZones(
            topLevelOrder: store.topLevelOrder,
            groups: store.groups,
            workspaces: store.workspaces,
            rowHeights: effectiveRowHeights,
            draggedIDs: draggedIDs,
            springLoadedGroupID: springLoadedGroupID,
            startY: Self.contentVerticalPadding,
            emptyPlaceholderHeight: effectiveEmptyRowHeight
        )
        return resolveDropTarget(zones: zones, cursorY: cursorY)
    }

    /// Overlay rendered inside the VStack's coordinate space during a
    /// drag. All targets that point at a specific slot are live-
    /// reordered via the reducer, so the row movement itself is the
    /// indicator. Only `.ontoGroupHeader` (which means "append to this
    /// group") is preview-only and renders a subtle header tint.
    @ViewBuilder
    private var dropIndicatorOverlay: some View {
        if let draggedID = draggedWorkspaceID,
           let target = currentDropTarget,
           !shouldLiveApplyDropTarget(target) {
            // Match the drag-time walker: single-row semantics so the
            // indicator shows exactly where the grabbed row will land.
            let zones = dropZones(
                topLevelOrder: store.topLevelOrder,
                groups: store.groups,
                workspaces: store.workspaces,
                rowHeights: effectiveRowHeights,
                draggedIDs: [draggedID],
                springLoadedGroupID: springLoadedGroupID,
                startY: Self.contentVerticalPadding,
                emptyPlaceholderHeight: effectiveEmptyRowHeight
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

    /// Group id the cursor is currently over, if that group is persisted
    /// as collapsed — the candidate for spring-load. Returns nil when
    /// the cursor isn't on a collapsed group or its (spring-loaded) children.
    private func collapsedGroupUnderCursor(_ target: DropTarget) -> UUID? {
        let gid: UUID? = switch target {
        case .ontoGroupHeader(let id): id
        case .intoGroup(let id, _): id
        case .topLevel: nil
        }
        guard let gid, store.groups[id: gid]?.isCollapsed == true else { return nil }
        return gid
    }

    /// Starts the 650ms timer to expand `groupID`. Safe to call repeatedly
    /// while hovering the same group — reschedules only when the target
    /// actually changes.
    private func scheduleSpringLoad(for groupID: UUID) {
        guard springLoadTargetID != groupID else { return }
        cancelSpringLoad()
        springLoadTargetID = groupID
        let target = groupID
        springLoadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.springLoadDelayMillis))
            guard !Task.isCancelled else { return }
            // Only fire if the user is still targeting this group.
            guard springLoadTargetID == target else { return }
            withAnimation(.easeInOut(duration: 0.1)) {
                springLoadedGroupID = target
            }
        }
    }

    /// Cancels any pending timer and collapses back any transiently
    /// expanded group. Called when the cursor leaves the candidate
    /// group and when the drag ends.
    private func cancelSpringLoad() {
        springLoadTask?.cancel()
        springLoadTask = nil
        springLoadTargetID = nil
        springLoadedGroupID = nil
    }

    // MARK: - Auto-scroll

    /// Start a repeating scroll task in the given direction (-1 up, +1
    /// down). Drives the underlying NSScrollView by `autoScrollStep`
    /// points per tick for pixel-perfect continuous scroll. After each
    /// scroll the drag logic is re-driven — the OS won't fire drag
    /// events while the cursor is stationary in screen space, so we
    /// synthesise them here so the dragged row and drop indicator stay
    /// in sync as the content moves under the cursor.
    private func startAutoScroll(direction: Int) {
        guard direction != 0 else { cancelAutoScroll(); return }
        guard autoScrollTask == nil else { return }
        let stepSigned = direction < 0 ? -Self.autoScrollStep : Self.autoScrollStep
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let sv = hostScrollView else { break }
                let visible = sv.documentVisibleRect
                let contentHeight = sv.documentView?.bounds.height ?? 0
                // Account for contentInsets — SwiftUI maps
                // `.safeAreaInset` to NSScrollView.contentInsets, which
                // shifts the scrollable range: the minimum valid origin
                // is `-contentInsets.top` (so content can reach the
                // clipView top, not just the inset-less area), and the
                // max is extended by `contentInsets.bottom`.
                let minY = -sv.contentInsets.top
                let maxY = max(
                    minY,
                    contentHeight + sv.contentInsets.bottom - visible.height
                )
                let currentY = visible.origin.y
                let newY = max(minY, min(maxY, currentY + stepSigned))
                if abs(newY - currentY) < 0.5 { break }
                // setBoundsOrigin + reflect is the non-deprecated path
                // for precise pixel scroll on macOS.
                sv.contentView.setBoundsOrigin(NSPoint(x: visible.origin.x, y: newY))
                sv.reflectScrolledClipView(sv.contentView)
                // Re-drive the drag logic at the cursor's new content
                // position so the dragged row keeps following the cursor
                // and the drop target re-resolves as rows slide past it.
                pumpDragAfterScroll()
                try? await Task.sleep(for: .milliseconds(Self.autoScrollIntervalMillis))
            }
        }
    }

    /// Called from the auto-scroll tick to keep drag state fresh while
    /// the OS isn't emitting drag events (the mouse is stationary in
    /// screen space but the content has moved underneath it).
    private func pumpDragAfterScroll() {
        guard let sv = hostScrollView else { return }
        let newContentY = dragViewportY + sv.documentVisibleRect.origin.y
        dragCurrentY = newContentY
        if let workspaceID = draggedWorkspaceID {
            // Treat multi-drag as a single-row drag for drag-time
            // resolution so the cursor tracks a 1-row gap; bulk
            // consolidation runs on release.
            let target = resolveCurrentDropTarget(
                cursorY: newContentY,
                draggedIDs: [workspaceID]
            )
            currentDropTarget = target
            // Mirror the normal onChanged spring-load handling: auto-
            // scroll can slide a collapsed group under a stationary
            // cursor (arming the timer) or away from one (cancelling).
            if let target, let gid = collapsedGroupUnderCursor(target) {
                scheduleSpringLoad(for: gid)
            } else if springLoadTask != nil || springLoadedGroupID != nil {
                cancelSpringLoad()
            }
            if let target, shouldLiveApplyDropTarget(target) {
                applyDropTarget(target, workspaceID: workspaceID)
            }
        } else if let groupID = draggedGroupID {
            let target = resolveCurrentTopLevelDropTarget(
                cursorY: newContentY,
                draggedGroupID: groupID
            )
            if case .topLevel(let idx) = target {
                store.send(.moveGroup(id: groupID, toIndex: idx))
            }
        }
    }

    private func cancelAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    /// Evaluate whether the cursor is in the top/bottom auto-scroll zone
    /// and start or cancel the auto-scroll loop accordingly. `cursorContentY`
    /// is in the `workspaceList` (content) coordinate space; viewport
    /// metrics come from the underlying NSScrollView.
    private func updateAutoScroll(cursorContentY: CGFloat) {
        guard let sv = hostScrollView else { return }
        let visible = sv.documentVisibleRect
        guard visible.height > 0 else { return }
        let viewportY = cursorContentY - visible.origin.y
        if viewportY < Self.autoScrollEdgeThreshold {
            startAutoScroll(direction: -1)
        } else if viewportY > visible.height - Self.autoScrollEdgeThreshold {
            startAutoScroll(direction: 1)
        } else {
            cancelAutoScroll()
        }
    }

    /// Whether this drop target should be applied to state as the
    /// cursor moves (so neighbouring rows shift out of the way), or
    /// only previewed via the indicator overlay and committed on
    /// release.
    ///
    /// `.topLevel` and `.intoGroup` point to a specific landing slot
    /// — live-applying makes the drop feel responsive. Cross-container
    /// cases are live-applied too so dragging into a group makes its
    /// existing children move aside as the cursor passes over them.
    ///
    /// `.ontoGroupHeader` means "append to this group"; the cursor
    /// often transits the header briefly on the way to a precise
    /// child slot, so live-apply would flicker the workspace in and
    /// out every time. Preview-only.
    private func shouldLiveApplyDropTarget(_ target: DropTarget) -> Bool {
        switch target {
        case .topLevel, .intoGroup:
            true
        case .ontoGroupHeader:
            false
        }
    }

    /// Group the dragged workspace is previewing a drop into via a
    /// preview-only target (`.ontoGroupHeader`) so the dragged row can
    /// render with a nested inset while state still says it's at its
    /// pre-drag container.
    private var dragPreviewGroupID: UUID? {
        if case .ontoGroupHeader(let gid) = currentDropTarget {
            return gid
        }
        return nil
    }

    /// The bulk drop target that consolidates the selection at the
    /// grabbed row's current position. Used as a fallback on release
    /// when the cursor sits in a vacated slot (the walker skips all
    /// selected rows, so cursor-in-gap resolves to nil). Converts the
    /// grabbed's current container + index into a post-bulk-remove
    /// index so the atomic reducer inserts the whole block starting
    /// where the cursor-tracking row was left.
    private func bulkTargetAtGrabbedPosition(grabbedID: UUID, bulkIDs: Set<UUID>) -> DropTarget? {
        if let topIdx = store.topLevelOrder.firstIndex(of: .workspace(grabbedID)) {
            var postRemoveIdx = 0
            for i in 0 ..< topIdx {
                if case .workspace(let wsID) = store.topLevelOrder[i],
                   bulkIDs.contains(wsID) {
                    continue
                }
                postRemoveIdx += 1
            }
            return .topLevel(index: postRemoveIdx)
        }
        if let gid = store.state.groupID(forWorkspace: grabbedID),
           let group = store.groups[id: gid],
           let childIdx = group.childOrder.firstIndex(of: grabbedID) {
            var postRemoveIdx = 0
            for i in 0 ..< childIdx {
                if !bulkIDs.contains(group.childOrder[i]) {
                    postRemoveIdx += 1
                }
            }
            return .intoGroup(groupID: gid, index: postRemoveIdx)
        }
        return nil
    }

    /// Order an arbitrary set of workspace IDs by their current sidebar
    /// walk order. Missing IDs are dropped.
    private func workspaceIDs(sortedBySidebar ids: Set<UUID>) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        return store.state.visibleWorkspaceOrder.filter { ids.contains($0) }
    }

    /// Apply a resolved DropTarget for a group of workspaces. Dispatches
    /// the atomic `.moveWorkspacesToGroup` action which removes all
    /// sources in one pass before inserting them in order — avoids the
    /// index drift that sequential single-workspace moves create when
    /// sources and target overlap.
    ///
    /// `target` indices are produced by the drop-zone walker with the
    /// full set of source IDs skipped, so they are already post-bulk-
    /// remove and feed straight into the reducer.
    private func applyBulkDropTarget(_ target: DropTarget, workspaceIDs ids: [UUID]) {
        switch target {
        case .topLevel(let base):
            store.send(.moveWorkspacesToGroup(ids: ids, groupID: nil, index: base))
        case .intoGroup(let gid, let base):
            store.send(.moveWorkspacesToGroup(ids: ids, groupID: gid, index: base))
        case .ontoGroupHeader(let gid):
            store.send(.moveWorkspacesToGroup(ids: ids, groupID: gid, index: nil))
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

/// Measured height of `GroupEmptyRow`. All empty rows render the same
/// size, so the reducer just keeps the largest non-zero value seen.
/// Used instead of the hardcoded constant so drag math tracks the
/// actual laid-out height — prevents a layout jump when a drag live-
/// applies a workspace into an empty group (placeholder vanishes, real
/// row takes its place at a potentially different height).
private struct EmptyRowHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Zero-height probe that walks up the AppKit hierarchy to find the
/// NSScrollView hosting its SwiftUI parent. Reports it to the SwiftUI
/// layer via `onFound` so auto-scroll can query viewport metrics and
/// drive the scroll position directly (pixel-perfect, smooth). All
/// callbacks are dispatched async — calling `onFound` synchronously
/// from `updateNSView` would modify SwiftUI state during a view update.
private struct ScrollViewFinder: NSViewRepresentable {
    let onFound: (NSScrollView) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = ProbeView()
        view.onFound = onFound
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let probe = nsView as? ProbeView else { return }
        probe.onFound = onFound
    }

    private final class ProbeView: NSView {
        var onFound: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.reportIfAvailable()
            }
        }

        func reportIfAvailable() {
            guard let sv = enclosingScrollView else { return }
            onFound?(sv)
        }
    }
}
