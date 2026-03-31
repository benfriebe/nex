import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

/// Root view: HStack with workspace sidebar + pane grid detail + optional inspector.
struct ContentView: View {
    let store: StoreOf<AppReducer>
    @Environment(\.surfaceManager) private var surfaceManager
    @Environment(\.socketServer) private var socketServer
    @State private var sidebarWidth: CGFloat = 220
    @State private var statusClearTask: Task<Void, Never>?

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
                        isZoomed: workspace.zoomedPaneID != nil && workspace.panes.count > 1,
                        onToggleMarkdownEdit: { paneID in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .toggleMarkdownEdit(paneID)
                            )))
                        },
                        onUpdateRatio: { splitPath, ratio in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .updateSplitRatio(splitPath: splitPath, ratio: ratio)
                            )))
                        },
                        onMovePane: { paneID, targetPaneID, zone in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .movePane(paneID: paneID, targetPaneID: targetPaneID, zone: zone)
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

                if store.isInspectorVisible {
                    WorkspaceInspectorView(store: store)
                }
            }
            .animation(.default, value: store.isSidebarVisible)
            .animation(.default, value: store.isInspectorVisible)
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
                      workspace.panes[id: paneID] != nil else { return }
                if workspace.focusedPaneID != paneID {
                    store.send(.workspaces(.element(id: activeID, action: .focusPane(paneID))))
                }
                scheduleClearStatus(paneID: paneID, workspaceID: activeID)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                NSApp.dockTile.badgeLabel = nil
                store.send(.updateExternalIndicators)
                guard let activeID = store.activeWorkspaceID,
                      let workspace = store.workspaces[id: activeID],
                      let focusedID = workspace.focusedPaneID else { return }
                scheduleClearStatus(paneID: focusedID, workspaceID: activeID)
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.surfaceTitleNotification)) { notification in
                guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
                      let title = notification.userInfo?["title"] as? String,
                      let paneID = surfaceManager.paneID(for: surface) else { return }
                // Route through AppReducer for cross-workspace support
                store.send(.surfaceTitleChanged(paneID: paneID, title: title))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.surfacePwdNotification)) { notification in
                guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
                      let pwd = notification.userInfo?["pwd"] as? String,
                      let paneID = surfaceManager.paneID(for: surface) else { return }
                // Route through AppReducer for cross-workspace support
                store.send(.surfaceDirectoryChanged(paneID: paneID, directory: pwd))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.desktopNotification)) { notification in
                guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
                      let title = notification.userInfo?["title"] as? String,
                      let body = notification.userInfo?["body"] as? String,
                      let paneID = surfaceManager.paneID(for: surface) else { return }
                store.send(.desktopNotification(paneID: paneID, title: title, body: body))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.surfaceCloseNotification)) { notification in
                guard let paneID = notification.userInfo?["paneID"] as? UUID else { return }
                store.send(.surfaceProcessExited(paneID: paneID))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.openFileNotification)) { notification in
                guard let path = notification.userInfo?["path"] as? String else { return }
                store.send(.openFileAtPath(path))
            }
            .onAppear {
                // Start socket server and wire messages to AppReducer
                socketServer.onMessage = { message in
                    Task { @MainActor in
                        store.send(.socketMessage(message))
                    }
                }
                socketServer.start()
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "md" else { return }
                    Task { @MainActor in
                        store.send(.openFileAtPath(url.path))
                    }
                }
                return true
            }
        }
    }

    private func scheduleClearStatus(paneID: UUID, workspaceID: UUID) {
        guard let workspace = store.workspaces[id: workspaceID],
              workspace.panes[id: paneID]?.status != .idle else { return }
        statusClearTask?.cancel()
        statusClearTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.send(.workspaces(.element(id: workspaceID, action: .clearPaneStatus(paneID))))
        }
    }

    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 0)
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
