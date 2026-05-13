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
                        onToggleZoom: {
                            store.send(.workspaces(.element(id: activeID, action: .toggleZoomPane)))
                        },
                        onToggleMarkdownEdit: { paneID in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .toggleMarkdownEdit(paneID)
                            )))
                        },
                        onScratchpadContentChanged: { paneID, content in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .scratchpadContentChanged(paneID: paneID, content: content)
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
                        },
                        searchingPaneID: workspace.searchingPaneID,
                        searchNeedle: workspace.searchNeedle,
                        searchTotal: workspace.searchTotal,
                        searchSelected: workspace.searchSelected,
                        onSearchNeedleChanged: { needle in
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .searchNeedleChanged(needle)
                            )))
                        },
                        onSearchNavigateNext: {
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .searchNavigateNext
                            )))
                        },
                        onSearchNavigatePrevious: {
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .searchNavigatePrevious
                            )))
                        },
                        onSearchClose: {
                            store.send(.workspaces(.element(
                                id: activeID,
                                action: .searchClose
                            )))
                        },
                        focusFollowsMouse: store.focusFollowsMouse,
                        focusFollowsMouseDelay: store.focusFollowsMouseDelay,
                        otherWorkspaces: store.workspaces
                            .filter { $0.id != activeID }
                            .map { (id: $0.id, name: $0.name) },
                        onRenamePane: { paneID in
                            store.send(.setRenamingPaneID(paneID))
                        },
                        onMovePaneToWorkspace: { paneID, targetWSID in
                            store.send(.socketMessage(
                                .paneMoveToWorkspace(
                                    paneID: paneID,
                                    toWorkspace: targetWSID.uuidString,
                                    create: false
                                ),
                                reply: nil
                            ))
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
                            store.send(.showNewWorkspaceSheet())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if store.isInspectorVisible {
                    WorkspaceInspectorView(store: store)
                }
            }
            .environment(
                \.sidebarTextEditingActive,
                store.renamingGroupID != nil || store.renamingWorkspaceID != nil
            )
            .overlay {
                if store.isCommandPaletteVisible {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            store.send(.dismissCommandPalette)
                        }
                        .overlay(alignment: .top) {
                            CommandPaletteView(
                                query: store.commandPaletteQuery,
                                items: store.commandPaletteItems,
                                selectedIndex: store.commandPaletteSelectedIndex,
                                onQueryChanged: { store.send(.commandPaletteQueryChanged($0)) },
                                onSelectIndex: { store.send(.commandPaletteSelectIndex($0)) },
                                onSelectNext: { store.send(.commandPaletteSelectNext) },
                                onSelectPrevious: { store.send(.commandPaletteSelectPrevious) },
                                onConfirm: { store.send(.commandPaletteConfirm) },
                                onDismiss: { store.send(.dismissCommandPalette) }
                            )
                            .padding(.top, 40)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: store.isCommandPaletteVisible)
            .animation(.default, value: store.isSidebarVisible)
            .animation(.default, value: store.isInspectorVisible)
            .sheet(isPresented: Binding(
                get: { store.isNewWorkspaceSheetPresented },
                set: { if !$0 { store.send(.dismissNewWorkspaceSheet) } }
            )) {
                NewWorkspaceSheet(store: store)
            }
            .sheet(isPresented: Binding(
                get: { store.renamingWorkspaceID != nil },
                set: { if !$0 { store.send(.setRenamingWorkspaceID(nil)) } }
            )) {
                if let id = store.renamingWorkspaceID,
                   let ws = store.workspaces[id: id] {
                    RenameWorkspaceSheet(
                        currentName: ws.name,
                        onRename: { newName in
                            store.send(.workspaces(.element(id: id, action: .rename(newName))))
                            store.send(.setRenamingWorkspaceID(nil))
                        },
                        onDismiss: {
                            store.send(.setRenamingWorkspaceID(nil))
                        }
                    )
                }
            }
            .sheet(isPresented: Binding(
                get: { store.renamingPaneID != nil },
                set: { if !$0 { store.send(.setRenamingPaneID(nil)) } }
            )) {
                if let paneID = store.renamingPaneID,
                   let pane = store.workspaces.flatMap(\.panes).first(where: { $0.id == paneID }) {
                    RenamePaneSheet(
                        currentName: pane.label ?? "",
                        onRename: { newName in
                            store.send(.socketMessage(
                                .paneName(paneID: paneID, name: newName),
                                reply: nil
                            ))
                            store.send(.setRenamingPaneID(nil))
                        },
                        onDismiss: {
                            store.send(.setRenamingPaneID(nil))
                        }
                    )
                }
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
                // Two posting sites use this notification:
                //   1) close_surface_cb — posts paneID (it has direct access to SurfaceView's userdata)
                //   2) SHOW_CHILD_EXITED action — posts the raw ghostty_surface_t
                //      and we look up the paneID via SurfaceManager.
                let paneID: UUID? = {
                    if let direct = notification.userInfo?["paneID"] as? UUID { return direct }
                    guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t else { return nil }
                    return surfaceManager.paneID(for: surface)
                }()
                guard let paneID else { return }
                store.send(.surfaceProcessExited(paneID: paneID))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.openFileNotification)) { notification in
                guard let path = notification.userInfo?["path"] as? String else { return }
                let paneID: UUID? = {
                    guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t else { return nil }
                    return surfaceManager.paneID(for: surface)
                }()
                store.send(.openFileAtPath(path, fromPaneID: paneID))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.searchStartNotification)) { notification in
                guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
                      let needle = notification.userInfo?["needle"] as? String,
                      let paneID = surfaceManager.paneID(for: surface) else { return }
                store.send(.ghosttySearchStarted(paneID: paneID, needle: needle))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.searchEndNotification)) { notification in
                guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
                      let paneID = surfaceManager.paneID(for: surface) else { return }
                store.send(.ghosttySearchEnded(paneID: paneID))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.searchTotalNotification)) { notification in
                guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
                      let total = notification.userInfo?["total"] as? Int,
                      let paneID = surfaceManager.paneID(for: surface) else { return }
                store.send(.searchTotalUpdated(paneID: paneID, total: total))
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyApp.searchSelectedNotification)) { notification in
                guard let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
                      let selected = notification.userInfo?["selected"] as? Int,
                      let paneID = surfaceManager.paneID(for: surface) else { return }
                store.send(.searchSelectedUpdated(paneID: paneID, selected: selected))
            }
            .onReceive(NotificationCenter.default.publisher(for: .markdownFindResult)) { notification in
                guard let paneID = notification.userInfo?["paneID"] as? UUID,
                      let total = notification.userInfo?["total"] as? Int,
                      let current = notification.userInfo?["current"] as? Int else { return }
                store.send(.searchTotalUpdated(paneID: paneID, total: total))
                // current is -1 when there are no matches; only forward a real index.
                if current >= 0 {
                    store.send(.searchSelectedUpdated(paneID: paneID, selected: current))
                }
            }
            .onAppear {
                // The xcodebuild test host instantiates ContentView; skip the
                // socket listener so `xcodebuild test` never touches
                // /tmp/nex.sock or binds a TCP port.
                guard !NexApp.isTestMode else { return }

                // Start socket server and wire messages to AppReducer
                socketServer.onMessage = { message, reply in
                    Task { @MainActor in
                        store.send(.socketMessage(message, reply: reply))
                    }
                }
                socketServer.start()

                // Start TCP listener if configured (for dev containers / SSH tunnels)
                let config = ConfigParser.parseGeneralSettings(
                    fromFile: KeybindingService.configPath
                )
                if config.tcpPort > 0 {
                    socketServer.startTCP(port: config.tcpPort)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "md" else { return }
                    Task { @MainActor in
                        store.send(.openFileAtPath(url.path, fromPaneID: nil))
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
