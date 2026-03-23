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
        await persistence.save(workspaces: workspaces, activeWorkspaceID: wsID)
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

    @Test func claudeSessionIDRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let paneID = UUID()
        let pane = Pane(
            id: paneID,
            type: .shell,
            workingDirectory: "/tmp",
            status: .running,
            claudeSessionID: "75a91227-c977-4c75-8921-ba01e070dd21",
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

        await persistence.save(workspaces: workspaces, activeWorkspaceID: wsID)
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        let loadedPane = result.workspaces.first!.panes.first!
        #expect(loadedPane.claudeSessionID == "75a91227-c977-4c75-8921-ba01e070dd21")
        #expect(loadedPane.status == .running)
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

        await persistence.save(workspaces: workspaces, activeWorkspaceID: ws2.id)
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

        await persistence.save(
            workspaces: workspaces,
            activeWorkspaceID: ws.id,
            repoRegistry: repos
        )
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.repoRegistry.count == 1)
        #expect(result.repoRegistry.first?.id == repoID)
        #expect(result.repoRegistry.first?.path == "/Users/test/code/my-repo")
        #expect(result.repoRegistry.first?.name == "my-repo")
        #expect(result.repoRegistry.first?.remoteURL == "https://github.com/user/my-repo.git")
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

        await persistence.save(
            workspaces: workspaces,
            activeWorkspaceID: ws.id,
            repoRegistry: repos
        )
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
