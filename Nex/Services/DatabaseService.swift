import Foundation
import GRDB

/// Manages the SQLite database via GRDB.
/// Handles migrations and provides access to the database writer.
final class DatabaseService: Sendable {
    let writer: any DatabaseWriter

    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Nex", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("nex.db").path

        var config = Configuration()
        config.foreignKeysEnabled = true

        let pool = try DatabasePool(path: dbPath, configuration: config)
        writer = pool
        try migrate()
    }

    /// In-memory database for testing.
    init(inMemory _: Bool) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabaseQueue(configuration: config)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("layoutJSON", .text).notNull()
                t.column("focusedPaneID", .text)
                t.column("createdAt", .double).notNull()
                t.column("lastAccessedAt", .double).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "pane") { t in
                t.primaryKey("id", .text)
                t.column("workspaceID", .text)
                    .notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("label", .text)
                t.column("type", .text).notNull().defaults(to: "shell")
                t.column("workingDirectory", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("lastActivityAt", .double).notNull()
            }

            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }

        migrator.registerMigration("v2_repos") { db in
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("remoteURL", .text)
                t.column("lastAccessedAt", .double).notNull()
            }

            try db.create(table: "repoAssociation") { t in
                t.primaryKey("id", .text)
                t.column("workspaceID", .text)
                    .notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("repoID", .text)
                    .notNull()
                    .references("repo", onDelete: .cascade)
                t.column("worktreePath", .text).notNull()
                t.column("branchName", .text)
            }
        }

        migrator.registerMigration("v3_workspace_slug") { db in
            try db.alter(table: "workspace") { t in
                t.add(column: "slug", .text).defaults(to: "")
            }
        }

        migrator.registerMigration("v4_agent_session") { db in
            let columns = try db.columns(in: "pane").map(\.name)
            if !columns.contains("claudeSessionID") {
                try db.alter(table: "pane") { t in
                    t.add(column: "claudeSessionID", .text)
                }
            }
            if !columns.contains("status") {
                try db.alter(table: "pane") { t in
                    t.add(column: "status", .text).defaults(to: "idle")
                }
            }
        }

        migrator.registerMigration("v5_markdown_panes") { db in
            let columns = try db.columns(in: "pane").map(\.name)
            if !columns.contains("filePath") {
                try db.alter(table: "pane") { t in
                    t.add(column: "filePath", .text)
                }
            }
        }

        migrator.registerMigration("v6_scratchpad_content") { db in
            let columns = try db.columns(in: "pane").map(\.name)
            if !columns.contains("content") {
                try db.alter(table: "pane") { t in
                    t.add(column: "content", .text)
                }
            }
        }

        migrator.registerMigration("v7_repo_assoc_auto_detected") { db in
            let columns = try db.columns(in: "repoAssociation").map(\.name)
            if !columns.contains("isAutoDetected") {
                try db.alter(table: "repoAssociation") { t in
                    t.add(column: "isAutoDetected", .boolean).notNull().defaults(to: false)
                }
            }
        }

        migrator.registerMigration("v8_repo_auto_discovered") { db in
            let columns = try db.columns(in: "repo").map(\.name)
            if !columns.contains("isAutoDiscovered") {
                try db.alter(table: "repo") { t in
                    t.add(column: "isAutoDiscovered", .boolean).notNull().defaults(to: false)
                }
            }
        }

        migrator.registerMigration("v9_workspace_groups") { db in
            try db.create(table: "workspace_group") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("isCollapsed", .boolean).notNull().defaults(to: false)
                t.column("childOrderJSON", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .double).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v10_workspace_group_icon") { db in
            // Guarded like v4–v8: a pre-release DB may already have the
            // column from running an earlier build, even though the
            // migration record wasn't written. Re-running
            // `ALTER TABLE ... ADD COLUMN` on an existing column
            // throws and would wedge startup.
            let columns = try db.columns(in: "workspace_group").map(\.name)
            if !columns.contains("icon") {
                try db.alter(table: "workspace_group") { t in
                    // Prefix-qualified string produced by `GroupIcon.storageString`
                    // (e.g., `"system:star.fill"`, `"emoji:📁"`). Nullable — nil
                    // renders the default colour-tinted folder glyph.
                    t.add(column: "icon", .text)
                }
            }
        }

        migrator.registerMigration("v11_workspace_labels") { db in
            let columns = try db.columns(in: "workspace").map(\.name)
            if !columns.contains("labelsJSON") {
                try db.alter(table: "workspace") { t in
                    t.add(column: "labelsJSON", .text).notNull().defaults(to: "[]")
                }
            }
        }

        try migrator.migrate(writer)
    }
}

// MARK: - GRDB Records

struct WorkspaceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workspace"

    var id: String
    var name: String
    var slug: String
    var color: String
    var layoutJSON: String
    var focusedPaneID: String?
    var createdAt: Double
    var lastAccessedAt: Double
    var sortOrder: Int
    var labelsJSON: String
}

struct PaneRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pane"

    var id: String
    var workspaceID: String
    var label: String?
    var type: String
    var workingDirectory: String
    var filePath: String?
    var content: String?
    var claudeSessionID: String?
    var status: String
    var createdAt: Double
    var lastActivityAt: Double
}

struct AppStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "appState"

    var key: String
    var value: String?
}

struct RepoRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "repo"

    var id: String
    var path: String
    var name: String
    var remoteURL: String?
    var lastAccessedAt: Double
    var isAutoDiscovered: Bool
}

struct RepoAssociationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "repoAssociation"

    var id: String
    var workspaceID: String
    var repoID: String
    var worktreePath: String
    var branchName: String?
    var isAutoDetected: Bool
}

struct WorkspaceGroupRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workspace_group"

    var id: String
    var name: String
    var color: String?
    var isCollapsed: Bool
    var childOrderJSON: String
    var createdAt: Double
    var sortOrder: Int
    var icon: String?
}
