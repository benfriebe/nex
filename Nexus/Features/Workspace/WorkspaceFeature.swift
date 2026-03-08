import ComposableArchitecture
import Foundation

@Reducer
struct WorkspaceFeature {
    @ObservableState
    struct State: Equatable, Identifiable, Sendable {
        let id: UUID
        var name: String
        var color: WorkspaceColor
        var panes: IdentifiedArrayOf<Pane>
        var layout: PaneLayout
        var focusedPaneID: UUID?
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
            self.color = color
            self.createdAt = createdAt
            self.lastAccessedAt = createdAt

            let paneID = UUID()
            let pane = Pane(id: paneID)
            self.panes = [pane]
            self.layout = .leaf(paneID)
            self.focusedPaneID = paneID
        }

        /// Restore from persisted state (no default pane creation).
        init(
            id: UUID,
            name: String,
            color: WorkspaceColor,
            panes: IdentifiedArrayOf<Pane>,
            layout: PaneLayout,
            focusedPaneID: UUID?,
            createdAt: Date,
            lastAccessedAt: Date
        ) {
            self.id = id
            self.name = name
            self.color = color
            self.panes = panes
            self.layout = layout
            self.focusedPaneID = focusedPaneID
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
        }
    }

    enum Action: Equatable, Sendable {
        case rename(String)
        case setColor(WorkspaceColor)
        case createPane
        case splitPane(direction: PaneLayout.SplitDirection, sourcePaneID: UUID?)
        case closePane(UUID)
        case focusPane(UUID)
        case focusNextPane
        case focusPreviousPane
        case updateSplitRatio(firstChildPaneID: UUID, ratio: Double)
        case paneTitleChanged(paneID: UUID, title: String)
        case paneDirectoryChanged(paneID: UUID, directory: String)
        case paneProcessTerminated(paneID: UUID)
    }

    @Dependency(\.surfaceManager) var surfaceManager
    @Dependency(\.ghosttyConfig) var ghosttyConfig
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .rename(let newName):
                state.name = newName
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

            case .closePane(let paneID):
                state.panes.remove(id: paneID)
                let newLayout = state.layout.removing(paneID: paneID)
                state.layout = newLayout

                // Update focus
                if state.focusedPaneID == paneID {
                    state.focusedPaneID = newLayout.allPaneIDs.first
                }

                return .run { _ in
                    await surfaceManager.destroySurface(paneID: paneID)
                }

            case .focusPane(let paneID):
                state.focusedPaneID = paneID
                return .none

            case .focusNextPane:
                guard let current = state.focusedPaneID else { return .none }
                state.focusedPaneID = state.layout.nextPaneID(after: current)
                return .none

            case .focusPreviousPane:
                guard let current = state.focusedPaneID else { return .none }
                state.focusedPaneID = state.layout.previousPaneID(before: current)
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
                return .none

            case .paneProcessTerminated(let paneID):
                // Close the pane when its shell exits
                return .send(.closePane(paneID))
            }
        }
    }
}
