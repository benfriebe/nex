import ComposableArchitecture
import Foundation

struct ClosedPaneSnapshot: Equatable {
    var workingDirectory: String
    var label: String?
    var type: PaneType
    var filePath: String?
    var claudeSessionID: String?
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
        case splitPaneAtPath(String)
        case splitPane(direction: PaneLayout.SplitDirection, sourcePaneID: UUID?)
        case closePane(UUID)
        case focusPane(UUID)
        case focusNextPane
        case focusPreviousPane
        case updateSplitRatio(firstChildPaneID: UUID, ratio: Double)
        case paneTitleChanged(paneID: UUID, title: String)
        case paneDirectoryChanged(paneID: UUID, directory: String)
        case paneProcessTerminated(paneID: UUID)
        case movePane(paneID: UUID, targetPaneID: UUID, zone: PaneLayout.DropZone)
        case agentStatusChanged(paneID: UUID, event: AgentEvent)
        case clearPaneStatus(UUID)
        case paneBranchChanged(paneID: UUID, branch: String?)
        case openMarkdownFile(filePath: String)
        case addRepoAssociation(RepoAssociation)
        case removeRepoAssociation(UUID)
        case reopenClosedPane
    }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.ghosttyConfig) var ghosttyConfig
    @Dependency(\.gitService) var gitService
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

            case .splitPaneAtPath(let path):
                guard let sourceID = state.focusedPaneID else { return .none }

                let newPaneID = uuid()
                let newPane = Pane(id: newPaneID, workingDirectory: path)

                let (newLayout, _) = state.layout.splitting(
                    paneID: sourceID,
                    direction: .horizontal,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                state.focusedPaneID = newPaneID

                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                }

            case .splitPane(let direction, let sourcePaneID):
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
                state.focusedPaneID = newPaneID

                let opacity = ghosttyConfig.backgroundOpacity
                return .run { _ in
                    await surfaceManager.createSurface(
                        paneID: newPaneID,
                        workingDirectory: newPane.workingDirectory,
                        backgroundOpacity: opacity
                    )
                }

            case .openMarkdownFile(let filePath):
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
                return .none

            case .closePane(let paneID):
                let paneType = state.panes[id: paneID]?.type ?? .shell
                if let pane = state.panes[id: paneID] {
                    state.recentlyClosedPanes.append(
                        ClosedPaneSnapshot(
                            workingDirectory: pane.workingDirectory,
                            label: pane.label,
                            type: pane.type,
                            filePath: pane.filePath,
                            claudeSessionID: pane.claudeSessionID
                        )
                    )
                    if state.recentlyClosedPanes.count > 10 {
                        state.recentlyClosedPanes.removeFirst()
                    }
                }
                state.panes.remove(id: paneID)
                let newLayout = state.layout.removing(paneID: paneID)
                state.layout = newLayout

                // Update focus
                if state.focusedPaneID == paneID {
                    state.focusedPaneID = newLayout.allPaneIDs.first
                }

                if paneType == .shell {
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

            case .updateSplitRatio(let firstChildPaneID, let ratio):
                state.layout = state.layout.updatingSplitRatio(
                    firstChildPaneID: firstChildPaneID,
                    to: ratio
                )
                return .none

            case .paneTitleChanged(let paneID, let title):
                state.panes[id: paneID]?.title = title
                state.panes[id: paneID]?.lastActivityAt = now
                return .none

            case .paneDirectoryChanged(let paneID, let directory):
                state.panes[id: paneID]?.workingDirectory = directory
                state.panes[id: paneID]?.lastActivityAt = now
                return .run { send in
                    let branch = try? await gitService.getCurrentBranch(directory)
                    await send(.paneBranchChanged(paneID: paneID, branch: branch))
                }

            case .paneProcessTerminated(let paneID):
                // Close the pane when its shell exits
                return .send(.closePane(paneID))

            case .movePane(let paneID, let targetPaneID, let zone):
                guard state.panes[id: paneID] != nil,
                      state.panes[id: targetPaneID] != nil else { return .none }
                state.layout = state.layout.movingPane(
                    paneID, toAdjacentOf: targetPaneID, zone: zone
                )
                state.focusedPaneID = paneID
                return .none

            case .agentStatusChanged(let paneID, let event):
                switch event {
                case .started:
                    state.panes[id: paneID]?.status = .running
                case .stopped, .error, .notification:
                    state.panes[id: paneID]?.status = .waitingForInput
                case .sessionStarted(let sessionID):
                    state.panes[id: paneID]?.claudeSessionID = sessionID
                }
                return .none

            case .clearPaneStatus(let paneID):
                // Only clear waitingForInput — don't clobber .running if the agent
                // already started again before the 600ms focus timer fired.
                if state.panes[id: paneID]?.status == .waitingForInput {
                    state.panes[id: paneID]?.status = .idle
                }
                return .none

            case .paneBranchChanged(let paneID, let branch):
                state.panes[id: paneID]?.gitBranch = branch
                return .none

            case .addRepoAssociation(let assoc):
                state.repoAssociations.append(assoc)
                return .none

            case .removeRepoAssociation(let id):
                state.repoAssociations.remove(id: id)
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
                    filePath: snapshot.filePath
                )

                let (newLayout, _) = state.layout.splitting(
                    paneID: focusedID,
                    direction: .horizontal,
                    newPaneID: newPaneID
                )
                state.layout = newLayout
                state.panes.append(newPane)
                state.focusedPaneID = newPaneID

                // Markdown panes don't need a surface
                if snapshot.type == .markdown {
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
