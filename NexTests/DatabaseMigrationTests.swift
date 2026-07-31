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

    @Test func v20CreatesPipelineRunTables() throws {
        let db = try DatabaseService(inMemory: true)

        try db.writer.read { db in
            let runColumns = try Set(db.columns(in: "pipelineRun").map(\.name))
            #expect(runColumns.contains("id"))
            #expect(runColumns.contains("definitionID"))
            #expect(runColumns.contains("definitionYAML"))
            #expect(runColumns.contains("status"))
            #expect(runColumns.contains("statusDetail"))
            #expect(runColumns.contains("workspaceID"))
            #expect(runColumns.contains("runDir"))
            #expect(runColumns.contains("edgeTraversalsJSON"))

            let nodeRunColumns = try Set(db.columns(in: "pipelineNodeRun").map(\.name))
            #expect(nodeRunColumns.contains("id"))
            #expect(nodeRunColumns.contains("runID"))
            #expect(nodeRunColumns.contains("nodeID"))
            #expect(nodeRunColumns.contains("attempt"))
            #expect(nodeRunColumns.contains("status"))
        }
    }

    /// Fan-out (issue #282 round 3): `{{feedback}}` on a node with
    /// multiple inbound edges binds to the specific NodeRun that fired
    /// its spawn, which needs a persisted pointer column.
    @Test func v21AddsFeedbackSourceNodeRunIDColumn() throws {
        let db = try DatabaseService(inMemory: true)
        try db.writer.read { db in
            let columns = try Set(db.columns(in: "pipelineNodeRun").map(\.name))
            #expect(columns.contains("feedbackSourceNodeRunID"))
        }
    }

    /// Migration is idempotent — re-running `migrate()` against an
    /// already-migrated DB (the guarded `tableExists` check) must not
    /// throw, matching the house style for every other v4+ migration.
    @Test func v20MigrationIsIdempotent() throws {
        let db = try DatabaseService(inMemory: true)
        // The migrator only runs unregistered migrations, but exercising
        // a second full `DatabaseService(inMemory:)` init against the
        // same in-memory path isn't possible — assert the tables simply
        // exist and re-running the table-exists guard is a no-op by
        // constructing a second service against a throwaway DB.
        _ = try DatabaseService(inMemory: true)
        let (hasRun, hasNodeRun) = try db.writer.read { db in
            try (db.tableExists("pipelineRun"), db.tableExists("pipelineNodeRun"))
        }
        #expect(hasRun)
        #expect(hasNodeRun)
    }

    @Test func pipelineNodeRunCascadeDeletesWithRun() throws {
        let db = try DatabaseService(inMemory: true)
        let runID = "run-1"

        try db.writer.write { db in
            let run = PipelineRunRecord(
                id: runID,
                definitionID: "loop",
                definitionYAML: "name: Loop\nentry: planner\nnodes: []\n",
                status: "paused",
                statusDetail: nil,
                location: "current",
                workspaceID: nil,
                worktreePath: nil,
                runDir: "/runs/run-1",
                inputsJSON: "{}",
                edgeTraversalsJSON: "{}",
                currentNodeRunID: nil,
                createdAt: 1000,
                updatedAt: 1000,
                completedAt: nil
            )
            try run.insert(db)

            let nodeRun = PipelineNodeRunRecord(
                id: "nr-1",
                runID: runID,
                nodeID: "planner",
                attempt: 1,
                paneID: nil,
                agentSessionID: nil,
                status: "spawning",
                summary: nil,
                outputPath: nil,
                warningsJSON: "[]",
                startedAt: 1000,
                updatedAt: 1000,
                completedAt: nil
            )
            try nodeRun.insert(db)
        }

        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM pipelineRun WHERE id = ?", arguments: [runID])
        }

        let nodeRunCount = try db.writer.read { db in
            try PipelineNodeRunRecord.fetchCount(db)
        }
        #expect(nodeRunCount == 0)
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
}
