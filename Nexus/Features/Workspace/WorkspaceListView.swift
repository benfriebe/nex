import ComposableArchitecture
import SwiftUI

/// Sidebar list of all workspaces with selection and context menus.
struct WorkspaceListView: View {
    let store: StoreOf<AppReducer>

    var body: some View {
        WithPerceptionTracking {
            List(selection: Binding(
                get: { store.activeWorkspaceID },
                set: { id in
                    if let id { store.send(.setActiveWorkspace(id)) }
                }
            )) {
                ForEach(store.scope(state: \.workspaces, action: \.workspaces)) { workspaceStore in
                    workspaceRow(workspaceStore: workspaceStore)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Button(action: { store.send(.showNewWorkspaceSheet) }) {
                    Label("New Workspace", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        }
    }

    private func workspaceRow(workspaceStore: StoreOf<WorkspaceFeature>) -> some View {
        WithPerceptionTracking {
            let workspaceID = workspaceStore.state.id
            let index = store.workspaces.index(id: workspaceID).map {
                store.workspaces.distance(from: store.workspaces.startIndex, to: $0)
            } ?? 0
            WorkspaceRowView(
                name: workspaceStore.name,
                color: workspaceStore.color,
                paneCount: workspaceStore.panes.count,
                isActive: workspaceID == store.activeWorkspaceID,
                index: index
            )
            .tag(workspaceID)
            .contextMenu {
                Button("Rename...") {
                    // TODO: inline rename
                }
                Menu("Color") {
                    ForEach(WorkspaceColor.allCases) { color in
                        Button(color.displayName) {
                            workspaceStore.send(.setColor(color))
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    store.send(.deleteWorkspace(workspaceID))
                }
                .disabled(store.workspaces.count <= 1)
            }
        }
    }
}
