import ComposableArchitecture
import SwiftUI

/// Root view: HStack with workspace sidebar + pane grid detail.
struct ContentView: View {
    let store: StoreOf<AppReducer>
    @State private var sidebarWidth: CGFloat = 220

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    WorkspaceListView(store: store)
                        .frame(width: sidebarWidth)
                        .background(Color(nsColor: .controlBackgroundColor))

                    sidebarResizeHandle
                }

                if let activeID = store.activeWorkspaceID,
                   let workspace = store.workspaces[id: activeID] {
                    PaneGridView(
                        layout: workspace.layout,
                        panes: workspace.panes,
                        focusedPaneID: workspace.focusedPaneID,
                        onCreatePane: {
                            store.send(.workspaces(.element(id: activeID, action: .createPane)))
                        },
                        onSplitPane: { paneID, direction in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .splitPane(direction: direction, sourcePaneID: paneID)
                            )))
                        },
                        onClosePane: { paneID in
                            store.send(.workspaces(.element(id: activeID, action: .closePane(paneID))))
                        },
                        onFocusPane: { paneID in
                            store.send(.workspaces(.element(id: activeID, action: .focusPane(paneID))))
                        },
                        onUpdateRatio: { firstChildPaneID, ratio in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .updateSplitRatio(firstChildPaneID: firstChildPaneID, ratio: ratio)
                            )))
                        }
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundStyle(.quaternary)
                        Text("No workspace selected")
                            .foregroundStyle(.secondary)
                        Button("Create Workspace") {
                            store.send(.showNewWorkspaceSheet)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.default, value: store.isSidebarVisible)
            .sheet(isPresented: Binding(
                get: { store.isNewWorkspaceSheetPresented },
                set: { if !$0 { store.send(.dismissNewWorkspaceSheet) } }
            )) {
                NewWorkspaceSheet(store: store)
            }
            .onReceive(NotificationCenter.default.publisher(for: SurfaceView.paneFocusedNotification)) { notification in
                guard let paneID = notification.userInfo?["paneID"] as? UUID,
                      let activeID = store.activeWorkspaceID,
                      let workspace = store.workspaces[id: activeID],
                      workspace.focusedPaneID != paneID,
                      workspace.panes[id: paneID] != nil else { return }
                store.send(.workspaces(.element(id: activeID, action: .focusPane(paneID))))
            }
        }
    }

    private var sidebarResizeHandle: some View {
        Color(nsColor: .controlBackgroundColor)
            .frame(width: 1)
            .overlay(Color(nsColor: .separatorColor).opacity(0.5))
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        sidebarWidth = min(max(sidebarWidth + value.translation.width, 180), 300)
                    }
            )
    }
}
