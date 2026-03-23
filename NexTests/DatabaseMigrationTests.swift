import Foundation
import GRDB
@testable import Nex
import Testing

struct DatabaseMigrationTests {
    @Test func v2MigrationCreatesRepoTables() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.read { db in
            // Verify repo table exists with expected columns
            let repoColumns = try db.columns(in: "repo")
            let repoColumnNames = Set(repoColumns.map(\.name))
            #expect(repoColumnNames.contains("id"))
            #expect(repoColumnNames.contains("path"))
            #expect(repoColumnNames.contains("name"))
            #expect(repoColumnNames.contains("remoteURL"))
            #expect(repoColumnNames.contains("lastAccessedAt"))

            // Verify repoAssociation table exists with expected columns
            let assocColumns = try db.columns(in: "repoAssociation")
            let assocColumnNames = Set(assocColumns.map(\.name))
            #expect(assocColumnNames.contains("id"))
            #expect(assocColumnNames.contains("workspaceID"))
            #expect(assocColumnNames.contains("repoID"))
            #expect(assocColumnNames.contains("worktreePath"))
            #expect(assocColumnNames.contains("branchName"))
        }
    }

    @Test func repoRecordInsertAndFetch() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.write { db in
            let record = RepoRecord(
                id: "test-id",
                path: "/path/to/repo",
                name: "my-repo",
                remoteURL: "https://github.com/user/repo.git",
                lastAccessedAt: Date().timeIntervalSince1970
            )
            try record.insert(db)
        }

        let fetched = try db.writer.read { db in
            try RepoRecord.fetchOne(db)
        }

        #expect(fetched?.id == "test-id")
        #expect(fetched?.path == "/path/to/repo")
        #expect(fetched?.name == "my-repo")
        #expect(fetched?.remoteURL == "https://github.com/user/repo.git")
    }

    @Test func repoPathUniqueness() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.write { db in
            let record1 = RepoRecord(
                id: "id-1",
                path: "/same/path",
                name: "repo1",
                remoteURL: nil,
                lastAccessedAt: 1000
            )
            try record1.insert(db)
        }

        #expect(throws: (any Error).self) {
            try db.writer.write { db in
                let record2 = RepoRecord(
                    id: "id-2",
                    path: "/same/path",
                    name: "repo2",
                    remoteURL: nil,
                    lastAccessedAt: 2000
                )
                try record2.insert(db)
            }
        }
    }

    @Test func cascadeDeleteWorkspaceRemovesAssociations() throws {
        let db = try DatabaseService(inMemory: true)

        let wsID = "ws-1"
        let repoID = "repo-1"

        try db.writer.write { db in
            // Insert workspace
            let ws = WorkspaceRecord(
                id: wsID,
                name: "Test",
                slug: "test",
                color: "blue",
                layoutJSON: "{}",
                focusedPaneID: nil,
                createdAt: 1000,
                lastAccessedAt: 1000,
                sortOrder: 0
            )
            try ws.insert(db)

            // Insert repo
            let repo = RepoRecord(
                id: repoID,
                path: "/path",
                name: "repo",
                remoteURL: nil,
                lastAccessedAt: 1000
            )
            try repo.insert(db)

            // Insert association
            let assoc = RepoAssociationRecord(
                id: "assoc-1",
                workspaceID: wsID,
                repoID: repoID,
                worktreePath: "/worktree",
                branchName: "main"
            )
            try assoc.insert(db)
        }

        // Delete workspace — association should cascade
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM workspace WHERE id = ?", arguments: [wsID])
        }

        let assocCount = try db.writer.read { db in
            try RepoAssociationRecord.fetchCount(db)
        }
        #expect(assocCount == 0)
    }

    @Test func cascadeDeleteRepoRemovesAssociations() throws {
        let db = try DatabaseService(inMemory: true)

        let wsID = "ws-1"
        let repoID = "repo-1"

        try db.writer.write { db in
            let ws = WorkspaceRecord(
                id: wsID,
                name: "Test",
                slug: "test",
                color: "blue",
                layoutJSON: "{}",
                focusedPaneID: nil,
                createdAt: 1000,
                lastAccessedAt: 1000,
                sortOrder: 0
            )
            try ws.insert(db)

            let repo = RepoRecord(
                id: repoID,
                path: "/path",
                name: "repo",
                remoteURL: nil,
                lastAccessedAt: 1000
            )
            try repo.insert(db)

            let assoc = RepoAssociationRecord(
                id: "assoc-1",
                workspaceID: wsID,
                repoID: repoID,
                worktreePath: "/worktree",
                branchName: "main"
            )
            try assoc.insert(db)
        }

        // Delete repo — association should cascade
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM repo WHERE id = ?", arguments: [repoID])
        }

        let assocCount = try db.writer.read { db in
            try RepoAssociationRecord.fetchCount(db)
        }
        #expect(assocCount == 0)
    }
}
