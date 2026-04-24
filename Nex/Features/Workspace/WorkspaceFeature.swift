import ComposableArchitecture
import Foundation

struct ClosedPaneSnapshot: Equatable {
    var workingDirectory: String
    var label: String?
    var type: PaneType
    var filePath: String?
    var scratchpadContent: String?
    var claudeSessionID: String?
    var markdownFontSize: Double = 14
}

@Reducer
struct WorkspaceFeature {
    @ObservableState
    struct State: Equatable, Identifiable {
        let id: UUID
        var name: String
        var slug: String
        var color: WorkspaceColor
        var panes: IdentifiedArrayOf<Pane>
        var layout: PaneLayout
        var focusedPaneID: UUID?
        var repoAssociations: IdentifiedArrayOf<RepoAssociation> = []
        var recentlyClosedPanes: [ClosedPaneSnapshot] = []
        /// Panes that are off-layout but whose ghostty surfaces/PTYs must
        /// stay alive (currently: sources parked by `nex open --here`).
        /// Not persisted — surfaces can't be restored across app
        /// restarts. A `Pane` lives in exactly one of `panes` or
        /// `parkedPanes` at any time.
        var parkedPanes: IdentifiedArrayOf<Pane> = []
        var zoomedPaneID: UUID?
        var savedLayout: PaneLayout?
        var searchingPaneID: UUID?
        var searchNeedle: String = ""
        var searchTotal: Int?
        var searchSelected: Int?
        var currentLayoutIndex: Int?
        var createdAt: Date
        var lastAccessedAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            color: WorkspaceColor = .blue,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            slug = Self.makeSlug(from: name, id: id)
            self.color = color
            self.createdAt = createdAt
            lastAccessedAt = createdAt

            let paneID = UUID()
            let pane = Pane(id: paneID)
            panes = [pane]
            layout = .leaf(paneID)
            focusedPaneID = paneID
        }

        /// Restore from persisted state (no default pane creation).
        init(
            id: UUID,
            name: String,
            slug: String,
            color: WorkspaceColor,
            panes: IdentifiedArrayOf<Pane>,
            layout: PaneLayout,
            focusedPaneID: UUID?,
            repoAssociations: IdentifiedArrayOf<RepoAssociation> = [],
            createdAt: Date,
            lastAccessedAt: Date
        ) {
            self.id = id
            self.name = name
            self.slug = slug
            self.color = color
            self.panes = panes
            self.layout = layout
            self.focusedPaneID = focusedPaneID
            self.repoAssociations = repoAssociations
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
        }

        /// Read a pane wherever it lives — visible layout or the
        /// parked lane (sources hidden by `nex open --here`). Surface
        /// and agent lifecycle events can target parked panes; user
        /// commands (send/split/close) intentionally only look at
        /// `panes`.
        func pane(id paneID: UUID) -> Pane? {
            panes[id: paneID] ?? parkedPanes[id: paneID]
        }

        /// Mutate a pane wherever it lives (visible or parked). If the
        /// pane isn't found the closure is not invoked.
        mutating func mutatePane(id paneID: UUID, _ body: (inout Pane) -> Void) {
            if var pane = panes[id: paneID] {
                body(&pane)
                panes[id: paneID] = pane
            } else if var pane = parkedPanes[id: paneID] {
                body(&pane)
                parkedPanes[id: paneID] = pane
            }
        }

        /// Generate a filesystem-safe slug from a display name.
        /// Appends a short ID suffix to guarantee uniqueness.
        static func makeSlug(from name: String, id: UUID) -> String {
            let base = name
                .lowercased()
                .replacing(/[^a-z0-9]+/, with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let suffix = id.uuidString.prefix(8).lowercased()
            return base.isEmpty ? suffix : "\(base)-\(suffix)"
        }
    }

    enum Action: Equatable {
        case rename(String)
        case setColor(WorkspaceColor)
        case createPane
        case splitPaneAtPath(String, label: String? = nil, direction: PaneLayout.SplitDirection = .horizontal)
        case splitPane(direction: PaneLayout.SplitDirection, sourcePaneID: UUID?, label: String? = nil)
        case closePane(UUID)
        case focusPane(UUID)
        case focusNextPane
        case focusPreviousPane
        case updateSplitRatio(splitPath: String, ratio: Double)
        case paneTitleChanged(paneID: UUID, title: String)
        case paneDirectoryChanged(paneID: UUID, directory: String)
        case paneProcessTerminated(paneID: UUID)
        case movePane(paneID: UUID, targetPaneID: UUID, zone: PaneLayout.DropZone)
        case agentStarted(paneID: UUID)
        case agentStopped(paneID: UUID)
        case agentError(paneID: UUID)
        case sessionStarted(paneID: UUID, sessionID: String)
        case clearPaneStatus(UUID)
        case paneBranchChanged(paneID: UUID, branch: String?)
        case openMarkdownFile(filePath: String, reusePaneID: UUID? = nil)
        case toggleMarkdownEdit(UUID)
        case increaseMarkdownFontSize(UUID)
        case decreaseMarkdownFontSize(UUID)
        case createScratchpad
        case scratchpadContentChanged(paneID: UUID, content: String)
        case addRepoAssociation(RepoAssociation)
        case removeRepoAssociation(UUID)
        case reopenClosedPane
        case cycleLayout
        case selectLayout(PredefinedLayout)
        case movePaneInDirection(PaneLayout.Direction)
        case toggleZoomPane
        case toggleSearch
        case ghosttySearchStarted(paneID: UUID, needle: String)
        case ghosttySearchEnded(paneID: UUID)
        case searchNeedleChanged(String)
        case searchNavigateNext
        case searchNavigatePrevious
        case searchClose
        case searchTotalUpdated(paneID: UUID, total: Int)
        case searchSelectedUpdated(paneID: UUID, selected: Int)
    }

    private enum SearchDebounceID: Hashable { case debounce }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.ghosttyConfig) var ghosttyConfig
    @Dependency(\.gitService) var gitService
    @Dependency(\.editorService) var editorService
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .rename(let newName):
                state.name = newName
                state.slug = State.makeSlug(from: newName, id: state.id)
                return .none

            case .setColor(let color):
                state.color = color
                return .none

            case .createPane:
                let newPaneID = uuid()
                let newPane = Pane(id: newPaneID)
                state.panes.append(newPane)
                state.layout = .leaf(newPaneID)
                state.focusedPaneID = newPaneID
                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                }

            case .splitPaneAtPath(let path, let label, let direction):
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }
                guard let sourceID = state.focusedPaneID else { return .none }

                let newPaneID = uuid()
                let newPane = Pane(id: newPaneID, workingDirectory: path)

                let (newLayout, _) = state.layout.splitting(
                    paneID: sourceID,
                    direction: direction,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                if let label { state.panes[id: newPaneID]?.label = label }
                state.focusedPaneID = newPaneID
                state.currentLayoutIndex = nil

                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                }

            case .splitPane(let direction, let sourcePaneID, let label):
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }
                let sourceID = sourcePaneID ?? state.focusedPaneID
                guard let sourceID else { return .none }
                guard let sourcPane = state.panes[id: sourceID] else { return .none }

                let newPaneID = uuid()
                let newPane = Pane(
                    id: newPaneID,
                    workingDirectory: sourcPane.workingDirectory
                )

                let (newLayout, _) = state.layout.splitting(
                    paneID: sourceID,
                    direction: direction,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                if let label { state.panes[id: newPaneID]?.label = label }
                state.focusedPaneID = newPaneID
                state.currentLayoutIndex = nil

                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                }

            case .openMarkdownFile(let filePath, let reusePaneID):
                let newPaneID = uuid()
                let dir = (filePath as NSString).deletingLastPathComponent
                let fileName = (filePath as NSString).lastPathComponent
                let newPane = Pane(
                    id: newPaneID,
                    label: fileName,
                    type: .markdown,
                    title: fileName,
                    workingDirectory: dir,
                    filePath: filePath,
                    createdAt: now,
                    lastActivityAt: now
                )

                let branchEffect: Effect<Action> = .run { send in
                    let branch = try? await gitService.getCurrentBranch(dir)
                    await send(.paneBranchChanged(paneID: newPaneID, branch: branch))
                }

                if let reusePaneID, let oldPane = state.panes[id: reusePaneID] {
                    // `--here`: park the originating pane so its PTY
                    // stays alive off-layout. Closing the new markdown
                    // pane will unpark it and restore the terminal.
                    // Mirrors closePane's search/zoom cleanup.
                    if state.searchingPaneID == reusePaneID {
                        state.searchingPaneID = nil
                        state.searchNeedle = ""
                        state.searchTotal = nil
                        state.searchSelected = nil
                    }
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    var linkedPane = newPane
                    linkedPane.parkedSourcePaneID = reusePaneID
                    state.layout = state.layout.replacing(paneID: reusePaneID, with: .leaf(newPaneID))
                    state.panes.remove(id: reusePaneID)
                    state.parkedPanes.append(oldPane)
                    state.panes.append(linkedPane)
                    state.focusedPaneID = newPaneID
                    state.currentLayoutIndex = nil
                    return branchEffect
                }

                if let sourceID = state.focusedPaneID {
                    let (newLayout, _) = state.layout.splitting(
                        paneID: sourceID,
                        direction: .horizontal,
                        newPaneID: newPaneID
                    )
                    state.layout = newLayout
                } else {
                    state.layout = .leaf(newPaneID)
                }
                state.panes.append(newPane)
                state.focusedPaneID = newPaneID
                state.currentLayoutIndex = nil
                return branchEffect

            case .createScratchpad:
                let newPaneID = uuid()
                let newPane = Pane(
                    id: newPaneID,
                    type: .scratchpad,
                    title: "Scratchpad",
                    isEditing: true,
                    createdAt: now,
                    lastActivityAt: now
                )

                if let sourceID = state.focusedPaneID {
                    if let saved = state.savedLayout {
                        state.layout = saved
                        state.zoomedPaneID = nil
                        state.savedLayout = nil
                    }
                    let (newLayout, _) = state.layout.splitting(
                        paneID: sourceID,
                        direction: .horizontal,
                        newPaneID: newPaneID
                    )
                    state.layout = newLayout
                } else {
                    state.layout = .leaf(newPaneID)
                }
                state.panes.append(newPane)
                state.focusedPaneID = newPaneID
                state.currentLayoutIndex = nil
                return .none

            case .scratchpadContentChanged(let paneID, let content):
                state.panes[id: paneID]?.scratchpadContent = content
                return .none

            case .closePane(let paneID):
                // Dismiss search if the pane being closed is the one being searched
                if state.searchingPaneID == paneID {
                    state.searchingPaneID = nil
                    state.searchNeedle = ""
                    state.searchTotal = nil
                    state.searchSelected = nil
                }
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }

                // Unpark: if the closing pane was created via `nex open
                // --here` and its source is still parked, restore the
                // source terminal instead of closing. The markdown
                // pane's own surface (if it entered external-editor
                // mode) still needs torn down.
                if let closingPane = state.panes[id: paneID],
                   let sourceID = closingPane.parkedSourcePaneID,
                   let parkedPane = state.parkedPanes[id: sourceID] {
                    let markdownHasSurface = closingPane.type == .markdown
                        && closingPane.isUsingExternalEditor
                    state.parkedPanes.remove(id: sourceID)
                    state.panes.remove(id: paneID)
                    state.panes.append(parkedPane)
                    state.layout = state.layout.replacing(
                        paneID: paneID, with: .leaf(sourceID)
                    )
                    state.focusedPaneID = sourceID
                    state.currentLayoutIndex = nil
                    if markdownHasSurface {
                        return .run { _ in
                            await surfaceManager.destroySurface(paneID: paneID)
                        }
                    }
                    return .none
                }

                let paneType = state.panes[id: paneID]?.type ?? .shell
                // A markdown pane hosts a ghostty surface only while editing
                // via an external editor. We must destroy that surface on
                // close too or the PTY and editor process leak behind the
                // scenes, alongside stale SurfaceManager bookkeeping.
                let hasBackingSurface = paneType == .shell
                    || (state.panes[id: paneID]?.isUsingExternalEditor ?? false)
                if let pane = state.panes[id: paneID] {
                    state.recentlyClosedPanes.append(
                        ClosedPaneSnapshot(
                            workingDirectory: pane.workingDirectory,
                            label: pane.label,
                            type: pane.type,
                            filePath: pane.filePath,
                            scratchpadContent: pane.scratchpadContent,
                            claudeSessionID: pane.claudeSessionID,
                            markdownFontSize: pane.markdownFontSize
                        )
                    )
                    if state.recentlyClosedPanes.count > 10 {
                        state.recentlyClosedPanes.removeFirst()
                    }
                }
                state.panes.remove(id: paneID)
                let newLayout = state.layout.removing(paneID: paneID)
                state.layout = newLayout
                state.currentLayoutIndex = nil

                // Update focus
                if state.focusedPaneID == paneID {
                    state.focusedPaneID = newLayout.allPaneIDs.first
                }

                if hasBackingSurface {
                    return .run { _ in
                        await surfaceManager.destroySurface(paneID: paneID)
                    }
                }
                return .none

            case .focusPane(let paneID):
                state.focusedPaneID = paneID
                return .none

            case .focusNextPane:
                guard let current = state.focusedPaneID,
                      let next = state.layout.nextPaneID(after: current) else { return .none }
                state.focusedPaneID = next
                return .none

            case .focusPreviousPane:
                guard let current = state.focusedPaneID,
                      let prev = state.layout.previousPaneID(before: current) else { return .none }
                state.focusedPaneID = prev
                return .none

            case .updateSplitRatio(let splitPath, let ratio):
                state.layout = state.layout.updatingSplitRatio(
                    atPath: splitPath,
                    to: ratio
                )
                state.currentLayoutIndex = nil
                return .none

            case .paneTitleChanged(let paneID, let title):
                let timestamp = now
                state.mutatePane(id: paneID) {
                    $0.title = title
                    $0.lastActivityAt = timestamp
                }
                return .none

            case .paneDirectoryChanged(let paneID, let directory):
                let timestamp = now
                state.mutatePane(id: paneID) {
                    $0.workingDirectory = directory
                    $0.lastActivityAt = timestamp
                }
                return .run { send in
                    let branch = try? await gitService.getCurrentBranch(directory)
                    await send(.paneBranchChanged(paneID: paneID, branch: branch))
                }

            case .paneProcessTerminated(let paneID):
                // If a parked pane's process died (SIGHUP, etc.), evict
                // it from the parked lane and clear references from
                // any markdown panes that were going to restore it.
                // The standard closePane path would be a no-op here
                // (parked panes aren't in state.panes or state.layout).
                if state.parkedPanes[id: paneID] != nil {
                    state.parkedPanes.remove(id: paneID)
                    for pane in state.panes where pane.parkedSourcePaneID == paneID {
                        state.panes[id: pane.id]?.parkedSourcePaneID = nil
                    }
                    return .run { _ in
                        await surfaceManager.destroySurface(paneID: paneID)
                    }
                }
                // If this was a markdown pane whose external editor just exited,
                // flip back to view mode instead of closing the pane. The
                // MarkdownPaneView file watcher will reload any on-disk changes.
                if let pane = state.panes[id: paneID],
                   pane.type == .markdown,
                   pane.isUsingExternalEditor {
                    state.panes[id: paneID]?.isEditing = false
                    state.panes[id: paneID]?.externalEditorCommand = nil
                    return .run { _ in
                        await surfaceManager.destroySurface(paneID: paneID)
                    }
                }
                // Close the pane when its shell exits
                return .send(.closePane(paneID))

            case .movePane(let paneID, let targetPaneID, let zone):
                guard state.panes[id: paneID] != nil,
                      state.panes[id: targetPaneID] != nil else { return .none }
                state.layout = state.layout.movingPane(
                    paneID, toAdjacentOf: targetPaneID, zone: zone
                )
                state.focusedPaneID = paneID
                state.currentLayoutIndex = nil
                return .none

            case .movePaneInDirection(let direction):
                guard state.zoomedPaneID == nil else { return .none }
                guard let focusedID = state.focusedPaneID else { return .none }
                guard let neighborID = state.layout.neighborPaneID(
                    of: focusedID, inDirection: direction
                ) else { return .none }
                state.layout = state.layout.swappingLeaves(focusedID, neighborID)
                state.currentLayoutIndex = nil
                return .none

            case .agentStarted(let paneID):
                state.mutatePane(id: paneID) { $0.status = .running }
                return .none

            case .agentStopped(let paneID):
                state.mutatePane(id: paneID) { $0.status = .waitingForInput }
                return .none

            case .agentError(let paneID):
                state.mutatePane(id: paneID) { $0.status = .waitingForInput }
                return .none

            case .sessionStarted(let paneID, let sessionID):
                state.mutatePane(id: paneID) { $0.claudeSessionID = sessionID }
                return .none

            case .clearPaneStatus(let paneID):
                // Only clear waitingForInput — don't clobber .running if the agent
                // already started again before the 600ms focus timer fired.
                if state.pane(id: paneID)?.status == .waitingForInput {
                    state.mutatePane(id: paneID) { $0.status = .idle }
                }
                return .none

            case .paneBranchChanged(let paneID, let branch):
                state.mutatePane(id: paneID) { $0.gitBranch = branch }
                return .none

            case .toggleMarkdownEdit(let paneID):
                guard let pane = state.panes[id: paneID], pane.type == .markdown else {
                    return .none
                }

                if pane.isEditing {
                    let wasExternal = pane.isUsingExternalEditor
                    state.panes[id: paneID]?.isEditing = false
                    state.panes[id: paneID]?.externalEditorCommand = nil
                    if wasExternal {
                        return .run { _ in
                            await surfaceManager.destroySurface(paneID: paneID)
                        }
                    }
                    return .none
                }

                // If we can resolve the user's $EDITOR, host it inside a
                // ghostty surface bound to this pane; otherwise fall back to
                // the built-in NSTextView editor.
                if let filePath = pane.filePath,
                   let command = editorService.buildCommand(filePath) {
                    state.panes[id: paneID]?.isEditing = true
                    state.panes[id: paneID]?.externalEditorCommand = command
                    let opacity = ghosttyConfig.backgroundOpacity
                    let cwd = pane.workingDirectory
                    return .run { _ in
                        await surfaceManager.createSurface(
                            paneID: paneID,
                            workingDirectory: cwd,
                            backgroundOpacity: opacity,
                            command: command
                        )
                    }
                }

                state.panes[id: paneID]?.isEditing = true
                state.panes[id: paneID]?.externalEditorCommand = nil
                return .none

            case .increaseMarkdownFontSize(let paneID):
                guard let pane = state.panes[id: paneID],
                      pane.type == .markdown,
                      !pane.isEditing
                else { return .none }
                let next = min(pane.markdownFontSize + 1, 32)
                state.panes[id: paneID]?.markdownFontSize = next
                return .none

            case .decreaseMarkdownFontSize(let paneID):
                guard let pane = state.panes[id: paneID],
                      pane.type == .markdown,
                      !pane.isEditing
                else { return .none }
                let next = max(pane.markdownFontSize - 1, 8)
                state.panes[id: paneID]?.markdownFontSize = next
                return .none

            case .addRepoAssociation(let assoc):
                state.repoAssociations.append(assoc)
                return .none

            case .removeRepoAssociation(let id):
                state.repoAssociations.remove(id: id)
                return .none

            case .cycleLayout:
                guard state.panes.count > 1 else { return .none }

                // Un-zoom if zoomed
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }

                let layouts = PredefinedLayout.allCases
                let nextIndex = if let current = state.currentLayoutIndex {
                    (current + 1) % layouts.count
                } else {
                    0
                }

                // Reorder so focused pane is first (becomes "main" in main-* layouts)
                let currentIDs = state.layout.allPaneIDs
                var reordered = currentIDs
                if let focusedID = state.focusedPaneID,
                   let idx = reordered.firstIndex(of: focusedID), idx != 0 {
                    reordered.remove(at: idx)
                    reordered.insert(focusedID, at: 0)
                }

                state.layout = layouts[nextIndex].buildLayout(for: reordered)
                state.currentLayoutIndex = nextIndex
                return .none

            case .selectLayout(let predefinedLayout):
                guard state.panes.count > 1 else { return .none }

                // Un-zoom if zoomed
                if let saved = state.savedLayout {
                    state.layout = saved
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                }

                let layouts = PredefinedLayout.allCases
                guard let index = layouts.firstIndex(of: predefinedLayout) else { return .none }

                let currentIDs = state.layout.allPaneIDs
                var reordered = currentIDs
                if let focusedID = state.focusedPaneID,
                   let idx = reordered.firstIndex(of: focusedID), idx != 0 {
                    reordered.remove(at: idx)
                    reordered.insert(focusedID, at: 0)
                }

                state.layout = predefinedLayout.buildLayout(for: reordered)
                state.currentLayoutIndex = index
                return .none

            case .toggleZoomPane:
                if state.zoomedPaneID != nil {
                    // Un-zoom: restore saved layout
                    if let saved = state.savedLayout {
                        state.layout = saved
                    }
                    state.zoomedPaneID = nil
                    state.savedLayout = nil
                } else if let focusedID = state.focusedPaneID,
                          state.panes.count > 1 {
                    // Zoom: save layout and show only focused pane
                    state.savedLayout = state.layout
                    state.zoomedPaneID = focusedID
                    state.layout = .leaf(focusedID)
                }
                return .none

            case .toggleSearch:
                guard let focusedID = state.focusedPaneID,
                      state.panes[id: focusedID]?.type == .shell else { return .none }
                if state.searchingPaneID != nil {
                    return .send(.searchClose)
                }
                state.searchingPaneID = focusedID
                state.searchNeedle = ""
                state.searchTotal = nil
                state.searchSelected = nil
                return .none

            case .ghosttySearchStarted(let paneID, let needle):
                guard state.panes[id: paneID]?.type == .shell else { return .none }
                state.searchingPaneID = paneID
                state.searchNeedle = needle
                state.searchTotal = nil
                state.searchSelected = nil
                return .none

            case .ghosttySearchEnded(let paneID):
                guard state.searchingPaneID == paneID else { return .none }
                state.searchingPaneID = nil
                state.searchNeedle = ""
                state.searchTotal = nil
                state.searchSelected = nil
                return .none

            case .searchNeedleChanged(let needle):
                state.searchNeedle = needle
                state.searchSelected = nil
                guard let paneID = state.searchingPaneID else { return .none }
                let mgr = surfaceManager
                if needle.isEmpty {
                    return .run { _ in
                        await mgr.performBindingAction(on: paneID, action: "search:")
                    }
                }
                // Debounce short queries to avoid expensive partial searches
                if needle.count < 3 {
                    return .run { _ in
                        try await Task.sleep(for: .milliseconds(300))
                        await mgr.performBindingAction(on: paneID, action: "search:\(needle)")
                    }
                    .cancellable(id: SearchDebounceID.debounce, cancelInFlight: true)
                }
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "search:\(needle)")
                }
                .cancellable(id: SearchDebounceID.debounce, cancelInFlight: true)

            case .searchNavigateNext:
                guard let paneID = state.searchingPaneID else { return .none }
                let mgr = surfaceManager
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "navigate_search:next")
                }

            case .searchNavigatePrevious:
                guard let paneID = state.searchingPaneID else { return .none }
                let mgr = surfaceManager
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "navigate_search:previous")
                }

            case .searchClose:
                guard let paneID = state.searchingPaneID else { return .none }
                state.searchingPaneID = nil
                state.searchNeedle = ""
                state.searchTotal = nil
                state.searchSelected = nil
                let mgr = surfaceManager
                return .run { _ in
                    await mgr.performBindingAction(on: paneID, action: "end_search")
                }

            case .searchTotalUpdated(let paneID, let total):
                guard state.searchingPaneID == paneID else { return .none }
                state.searchTotal = total
                return .none

            case .searchSelectedUpdated(let paneID, let selected):
                guard state.searchingPaneID == paneID else { return .none }
                state.searchSelected = selected
                return .none

            case .reopenClosedPane:
                guard let snapshot = state.recentlyClosedPanes.popLast() else { return .none }
                guard let focusedID = state.focusedPaneID else { return .none }

                let newPaneID = uuid()
                let newPane = Pane(
                    id: newPaneID,
                    label: snapshot.label,
                    type: snapshot.type,
                    workingDirectory: snapshot.workingDirectory,
                    filePath: snapshot.filePath,
                    isEditing: snapshot.type == .scratchpad,
                    scratchpadContent: snapshot.scratchpadContent,
                    markdownFontSize: snapshot.markdownFontSize
                )

                let (newLayout, _) = state.layout.splitting(
                    paneID: focusedID,
                    direction: .horizontal,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                state.focusedPaneID = newPaneID
                state.currentLayoutIndex = nil

                // Markdown and scratchpad panes don't need a surface
                if snapshot.type == .markdown || snapshot.type == .scratchpad {
                    return .none
                }

                let opacity = ghosttyConfig.backgroundOpacity
                let sessionID = snapshot.claudeSessionID
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                    if let sessionID {
                        try? await Task.sleep(for: .seconds(2))
                        await surfaceManager.sendCommand(
                            to: newPaneID,
                            command: "claude --resume \(sessionID)"
                        )
                    }
                }
            }
        }
    }
}

extension IdentifiedArrayOf where Element == WorkspaceFeature.State {
    /// Returns a random `WorkspaceColor` for a newly created workspace, avoiding
    /// the colour of the trailing workspace so an appended workspace is visually
    /// distinct from its neighbour in the sidebar. See benfriebe/nex#26.
    func nextRandomColor() -> WorkspaceColor {
        let excluded = last?.color
        return WorkspaceColor.allCases
            .filter { $0 != excluded }
            .randomElement() ?? .blue
    }
}
