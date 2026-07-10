import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

struct PersistenceTests {
    @Test func roundTripSaveAndLoad() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        // Create test state
        let paneID = UUID()
        let pane = Pane(
            id: paneID,
            label: "test",
            type: .shell,
            workingDirectory: "/tmp",
            createdAt: Date(timeIntervalSince1970: 1000),
            lastActivityAt: Date(timeIntervalSince1970: 2000)
        )

        let wsID = UUID()
        let workspace = WorkspaceFeature.State(
            id: wsID,
            name: "Test Workspace",
            slug: "test-workspace-\(wsID.uuidString.prefix(8).lowercased())",
            color: .green,
            panes: [pane],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 2000)
        )

        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(workspace)

        // Save (bypass debounce by calling directly)
        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: wsID)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        // Wait for debounce
        try await Task.sleep(for: .seconds(1))

        // Load
        let result = await persistence.load()

        #expect(result.workspaces.count == 1)
        #expect(result.activeWorkspaceID == wsID)

        let loadedWS = result.workspaces.first!
        #expect(loadedWS.id == wsID)
        #expect(loadedWS.name == "Test Workspace")
        #expect(loadedWS.color == .green)
        #expect(loadedWS.panes.count == 1)
        #expect(loadedWS.panes.first!.workingDirectory == "/tmp")
        #expect(loadedWS.layout == .leaf(paneID))
        #expect(loadedWS.focusedPaneID == paneID)
    }

    @Test func profileNameRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let paneID1 = UUID()
        let paneID2 = UUID()
        let wsWithProfileID = UUID()
        let wsWithoutProfileID = UUID()
        let withProfile = WorkspaceFeature.State(
            id: wsWithProfileID,
            name: "Work",
            slug: "work-\(wsWithProfileID.uuidString.prefix(8).lowercased())",
            color: .blue,
            panes: [Pane(id: paneID1)],
            layout: .leaf(paneID1),
            focusedPaneID: paneID1,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000),
            profileName: "work"
        )
        let withoutProfile = WorkspaceFeature.State(
            id: wsWithoutProfileID,
            name: "Plain",
            slug: "plain-\(wsWithoutProfileID.uuidString.prefix(8).lowercased())",
            color: .green,
            panes: [Pane(id: paneID2)],
            layout: .leaf(paneID2),
            focusedPaneID: paneID2,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000)
        )

        let state = AppReducer.State(
            workspaces: [withProfile, withoutProfile],
            activeWorkspaceID: wsWithProfileID
        )
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.workspaces.count == 2)
        #expect(result.workspaces.first(where: { $0.id == wsWithProfileID })?.profileName == "work")
        #expect(result.workspaces.first(where: { $0.id == wsWithoutProfileID })?.profileName == nil)
    }

    @Test func agentSessionIDRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let paneID = UUID()
        let pane = Pane(
            id: paneID,
            type: .shell,
            workingDirectory: "/tmp",
            status: .running,
            agentSessionID: "75a91227-c977-4c75-8921-ba01e070dd21",
            createdAt: Date(timeIntervalSince1970: 1000),
            lastActivityAt: Date(timeIntervalSince1970: 2000)
        )

        let wsID = UUID()
        let workspace = WorkspaceFeature.State(
            id: wsID,
            name: "Session Test",
            slug: "session-test-\(wsID.uuidString.prefix(8).lowercased())",
            color: .blue,
            panes: [pane],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 2000)
        )

        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(workspace)

        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: wsID)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        let loadedPane = result.workspaces.first!.panes.first!
        #expect(loadedPane.agentSessionID == "75a91227-c977-4c75-8921-ba01e070dd21")
        #expect(loadedPane.status == .running)
    }

    @Test func scratchpadContentRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let paneID = UUID()
        let pane = Pane(
            id: paneID,
            type: .scratchpad,
            workingDirectory: "/tmp",
            isEditing: true,
            scratchpadContent: "my notes here",
            createdAt: Date(timeIntervalSince1970: 1000),
            lastActivityAt: Date(timeIntervalSince1970: 2000)
        )

        let wsID = UUID()
        let workspace = WorkspaceFeature.State(
            id: wsID,
            name: "Scratch Test",
            slug: "scratch-test-\(wsID.uuidString.prefix(8).lowercased())",
            color: .purple,
            panes: [pane],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 2000)
        )

        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(workspace)

        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: wsID)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        let loadedPane = result.workspaces.first!.panes.first!
        #expect(loadedPane.type == .scratchpad)
        #expect(loadedPane.scratchpadContent == "my notes here")
        #expect(loadedPane.isEditing == true)
    }

    @Test func loadEmptyDatabaseReturnsEmpty() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let result = await persistence.load()
        #expect(result.workspaces.isEmpty)
        #expect(result.activeWorkspaceID == nil)
        #expect(result.repoRegistry.isEmpty)
    }

    @Test func multipleWorkspacesPersistOrder() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let ws1 = WorkspaceFeature.State(name: "First", color: .red)
        let ws2 = WorkspaceFeature.State(name: "Second", color: .blue)
        let ws3 = WorkspaceFeature.State(name: "Third", color: .green)

        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(ws1)
        workspaces.append(ws2)
        workspaces.append(ws3)

        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: ws2.id)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.workspaces.count == 3)
        #expect(result.workspaces[0].name == "First")
        #expect(result.workspaces[1].name == "Second")
        #expect(result.workspaces[2].name == "Third")
        #expect(result.activeWorkspaceID == ws2.id)
    }

    @Test func repoRegistryRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let repoID = UUID()
        let repo = Repo(
            id: repoID,
            path: "/Users/test/code/my-repo",
            name: "my-repo",
            remoteURL: "https://github.com/user/my-repo.git",
            lastAccessedAt: Date(timeIntervalSince1970: 3000)
        )

        var repos = IdentifiedArrayOf<Repo>()
        repos.append(repo)

        let ws = WorkspaceFeature.State(name: "Test", color: .blue)
        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(ws)

        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: ws.id, repoRegistry: repos)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.repoRegistry.count == 1)
        #expect(result.repoRegistry.first?.id == repoID)
        #expect(result.repoRegistry.first?.path == "/Users/test/code/my-repo")
        #expect(result.repoRegistry.first?.name == "my-repo")
        #expect(result.repoRegistry.first?.remoteURL == "https://github.com/user/my-repo.git")
    }

    @Test func webPanePublicRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let paneID = UUID()
        let pane = Pane(
            id: paneID,
            type: .web,
            workingDirectory: NSHomeDirectory(),
            createdAt: Date(timeIntervalSince1970: 1000),
            lastActivityAt: Date(timeIntervalSince1970: 2000)
        )
        let tabID = UUID()
        let webState = WebPaneState(
            tabs: [WebTab(id: tabID, url: "https://example.com", title: "Example")],
            activeTabID: tabID,
            isPrivate: false
        )

        let wsID = UUID()
        let workspace = WorkspaceFeature.State(
            id: wsID,
            name: "Web Test",
            slug: "web-test-\(wsID.uuidString.prefix(8).lowercased())",
            color: .blue,
            panes: [pane],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 2000),
            webPanes: [paneID: webState]
        )

        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(workspace)
        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: wsID)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        let loadedWS = result.workspaces.first!
        let loadedWeb = loadedWS.webPanes[paneID]
        #expect(loadedWeb != nil)
        #expect(loadedWeb?.isPrivate == false)
        #expect(loadedWeb?.tabs.count == 1)
        #expect(loadedWeb?.tabs.first?.url == "https://example.com")
        #expect(loadedWeb?.activeTabID == tabID)
    }

    @Test func webPanePrivateBlanksOnReload() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let paneID = UUID()
        let pane = Pane(
            id: paneID,
            type: .web,
            workingDirectory: NSHomeDirectory(),
            createdAt: Date(timeIntervalSince1970: 1000),
            lastActivityAt: Date(timeIntervalSince1970: 2000)
        )
        let tabID = UUID()
        // Private pane with a tab in memory — save must drop the
        // tab from disk but preserve the private flag itself so the
        // restore keeps the pane configured for a nonPersistent
        // data store.
        let webState = WebPaneState(
            tabs: [WebTab(id: tabID, url: "https://secret.example.com")],
            activeTabID: tabID,
            isPrivate: true
        )

        let wsID = UUID()
        let workspace = WorkspaceFeature.State(
            id: wsID,
            name: "Private Test",
            slug: "private-test-\(wsID.uuidString.prefix(8).lowercased())",
            color: .blue,
            panes: [pane],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 2000),
            webPanes: [paneID: webState]
        )

        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(workspace)
        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: wsID)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        let loadedWS = result.workspaces.first!
        let loadedPane = loadedWS.panes.first!
        let loadedWeb = loadedWS.webPanes[paneID]
        #expect(loadedPane.type == .web)
        #expect(loadedWeb != nil)
        #expect(loadedWeb?.isPrivate == true)
        #expect(loadedWeb?.tabs.isEmpty == true)
        #expect(loadedWeb?.activeTabID == nil)
    }

    @Test func repoAssociationRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let repoID = UUID()
        let repo = Repo(
            id: repoID,
            path: "/Users/test/code/my-repo",
            name: "my-repo"
        )

        var repos = IdentifiedArrayOf<Repo>()
        repos.append(repo)

        let assocID = UUID()
        let assoc = RepoAssociation(
            id: assocID,
            repoID: repoID,
            worktreePath: "/Users/test/code/my-repo/.worktrees/dev",
            branchName: "feature/dev"
        )

        let paneID = UUID()
        let pane = Pane(id: paneID)
        let wsID = UUID()
        let ws = WorkspaceFeature.State(
            id: wsID,
            name: "Test",
            slug: "test-\(wsID.uuidString.prefix(8).lowercased())",
            color: .blue,
            panes: [pane],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            repoAssociations: [assoc],
            createdAt: Date(),
            lastAccessedAt: Date()
        )

        var workspaces = IdentifiedArrayOf<WorkspaceFeature.State>()
        workspaces.append(ws)

        let state = AppReducer.State(workspaces: workspaces, activeWorkspaceID: ws.id, repoRegistry: repos)
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.workspaces.count == 1)
        let loadedWS = result.workspaces.first!
        #expect(loadedWS.repoAssociations.count == 1)
        #expect(loadedWS.repoAssociations.first?.id == assocID)
        #expect(loadedWS.repoAssociations.first?.repoID == repoID)
        #expect(loadedWS.repoAssociations.first?.worktreePath == "/Users/test/code/my-repo/.worktrees/dev")
        #expect(loadedWS.repoAssociations.first?.branchName == "feature/dev")
    }
}
