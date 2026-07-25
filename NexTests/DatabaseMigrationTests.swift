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

    @Test func v17AddsWorkspaceProfileNameColumn() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.read { db in
            let columns = try Set(db.columns(in: "workspace").map(\.name))
            #expect(columns.contains("profileName"))
        }
    }

    @Test func v18AddsPaneAgentKindColumn() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.read { db in
            let columns = try Set(db.columns(in: "pane").map(\.name))
            #expect(columns.contains("agentKind"))
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
                lastAccessedAt: Date().timeIntervalSince1970,
                isAutoDiscovered: false
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
                lastAccessedAt: 1000,
                isAutoDiscovered: false
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
                    lastAccessedAt: 2000,
                    isAutoDiscovered: false
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
                sortOrder: 0,
                labelsJSON: "[]"
            )
            try ws.insert(db)

            // Insert repo
            let repo = RepoRecord(
                id: repoID,
                path: "/path",
                name: "repo",
                remoteURL: nil,
                lastAccessedAt: 1000,
                isAutoDiscovered: false
            )
            try repo.insert(db)

            // Insert association
            let assoc = RepoAssociationRecord(
                id: "assoc-1",
                workspaceID: wsID,
                repoID: repoID,
                worktreePath: "/worktree",
                branchName: "main",
                isAutoDetected: false
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

    @Test func v9CreatesWorkspaceGroupTable() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.read { db in
            let columns = try db.columns(in: "workspace_group")
            let names = Set(columns.map(\.name))
            #expect(names.contains("id"))
            #expect(names.contains("name"))
            #expect(names.contains("color"))
            #expect(names.contains("isCollapsed"))
            #expect(names.contains("childOrderJSON"))
            #expect(names.contains("createdAt"))
            #expect(names.contains("sortOrder"))
        }
    }

    @Test func v10AddsIconColumnToWorkspaceGroup() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.read { db in
            let columns = try db.columns(in: "workspace_group")
            let names = Set(columns.map(\.name))
            #expect(names.contains("icon"))
            // Column is nullable — the v10 migration shouldn't force
            // existing rows to carry an icon value.
            if let iconColumn = columns.first(where: { $0.name == "icon" }) {
                #expect(iconColumn.isNotNull == false)
            }
        }
    }

    @Test func workspaceGroupRecordInsertAndFetch() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.write { db in
            let record = WorkspaceGroupRecord(
                id: "grp-1",
                name: "Monitors",
                color: "gray",
                isCollapsed: true,
                childOrderJSON: "[\"abc\"]",
                createdAt: 1000,
                sortOrder: 0,
                icon: "system:star.fill"
            )
            try record.insert(db)
        }

        let fetched = try db.writer.read { db in
            try WorkspaceGroupRecord.fetchOne(db)
        }

        #expect(fetched?.id == "grp-1")
        #expect(fetched?.name == "Monitors")
        #expect(fetched?.color == "gray")
        #expect(fetched?.isCollapsed == true)
        #expect(fetched?.childOrderJSON == "[\"abc\"]")
        #expect(fetched?.icon == "system:star.fill")
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
                sortOrder: 0,
                labelsJSON: "[]"
            )
            try ws.insert(db)

            let repo = RepoRecord(
                id: repoID,
                path: "/path",
                name: "repo",
                remoteURL: nil,
                lastAccessedAt: 1000,
                isAutoDiscovered: false
            )
            try repo.insert(db)

            let assoc = RepoAssociationRecord(
                id: "assoc-1",
                workspaceID: wsID,
                repoID: repoID,
                worktreePath: "/worktree",
                branchName: "main",
                isAutoDetected: false
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

    /// Every other migration test here runs against a *fresh* DB, so
    /// every migration only ever executes against an empty schema — the
    /// v15 `claudeSessionID` → `agentSessionID` rename was never
    /// actually exercised against a populated pre-v15 database (issue
    /// #267). Seed a real on-disk DB at exactly the v14 schema (the
    /// last version before the rename), insert a row the way a genuine
    /// pre-v15 install would have it, then run the remaining migrations
    /// and confirm the value survived under its new column name.
    @Test func v15RenameIsDataPreservingOnPopulatedOldSchema() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nex-v15-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: tmp.path, configuration: config)

        // Stop at v14 — the schema every real pre-v15 install had.
        try DatabaseService.makeMigrator().migrate(pool, upTo: "v14_web_pane_private")

        let wsID = "ws-legacy"
        let paneID = "pane-legacy"
        try pool.write { db in
            try db.execute(sql: """
            INSERT INTO workspace
                (id, name, slug, color, layoutJSON, focusedPaneID, createdAt, lastAccessedAt, sortOrder, labelsJSON)
            VALUES (?, 'Legacy', 'legacy', 'blue', '{}', NULL, 1000, 1000, 0, '[]')
            """, arguments: [wsID])
            try db.execute(sql: """
            INSERT INTO pane
                (id, workspaceID, label, type, workingDirectory, createdAt, lastActivityAt, claudeSessionID, status)
            VALUES (?, ?, NULL, 'shell', '/tmp', 1000, 1000, 'legacy-session-abc', 'running')
            """, arguments: [paneID, wsID])
        }

        // Run the rest of the chain (v15 onward) against the populated DB.
        try DatabaseService.makeMigrator().migrate(pool)

        try pool.read { db in
            let columns = try Set(db.columns(in: "pane").map(\.name))
            #expect(columns.contains("agentSessionID"))
            #expect(!columns.contains("claudeSessionID"))
        }

        let paneRecord = try pool.read { db in
            try PaneRecord.filter(Column("id") == paneID).fetchOne(db)
        }
        #expect(paneRecord?.agentSessionID == "legacy-session-abc")
        #expect(paneRecord?.status == "running")
    }

    /// A DB that can't open (corrupt file) used to `fatalError` on every
    /// launch with no recovery (issue #267). `DatabaseService.init`
    /// should instead quarantine the unreadable file and start fresh so
    /// the app always launches, leaving the original on disk for manual
    /// recovery rather than silently deleting it.
    @Test func corruptDatabaseFileIsQuarantinedAndRecreated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nex-corrupt-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("nex.db")

        // Not a valid SQLite file.
        try Data("not a sqlite database".utf8).write(to: dbPath)

        let db = try DatabaseService(testPath: dbPath.path)
        let count = try db.writer.read { db in try WorkspaceRecord.fetchCount(db) }
        #expect(count == 0)

        // The corrupt original was moved aside, not silently discarded.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings.contains { $0.hasPrefix("nex.db.corrupt-") })
    }
}
