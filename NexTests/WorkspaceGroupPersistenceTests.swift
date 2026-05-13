import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

struct WorkspaceGroupPersistenceTests {
    @Test func groupRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let ws1 = WorkspaceFeature.State(name: "Alpha", color: .blue)
        let ws2 = WorkspaceFeature.State(name: "Beta", color: .green)
        let groupID = UUID()
        let group = WorkspaceGroup(
            id: groupID,
            name: "Monitors",
            color: .gray,
            isCollapsed: true,
            childOrder: [ws2.id]
        )

        var state = AppReducer.State(
            workspaces: [ws1, ws2],
            groups: [group],
            topLevelOrder: [.workspace(ws1.id), .group(groupID)],
            activeWorkspaceID: ws1.id
        )
        _ = state // silence unused warning if mutated below

        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.workspaces.count == 2)
        #expect(result.groups.count == 1)
        let loadedGroup = result.groups[id: groupID]
        #expect(loadedGroup?.name == "Monitors")
        #expect(loadedGroup?.color == .gray)
        #expect(loadedGroup?.isCollapsed == true)
        #expect(loadedGroup?.childOrder == [ws2.id])
        #expect(result.topLevelOrder == [.workspace(ws1.id), .group(groupID)])
    }

    @Test func workspaceLabelsRoundTrip() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        var ws1 = WorkspaceFeature.State(name: "Tagged", color: .blue)
        ws1.labels = ["backend", "priority", "blocked"]
        let ws2 = WorkspaceFeature.State(name: "Untagged", color: .green)

        let state = AppReducer.State(
            workspaces: [ws1, ws2],
            groups: [],
            topLevelOrder: [.workspace(ws1.id), .workspace(ws2.id)],
            activeWorkspaceID: ws1.id
        )

        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        let loaded1 = result.workspaces[id: ws1.id]
        let loaded2 = result.workspaces[id: ws2.id]
        #expect(loaded1?.labels == ["backend", "priority", "blocked"])
        #expect(loaded2?.labels == [])
    }

    @Test func v11AddsLabelsJSONColumnWithEmptyDefault() throws {
        let db = try DatabaseService(inMemory: true)
        try db.writer.read { db in
            let columns = try db.columns(in: "workspace")
            let labelsCol = columns.first { $0.name == "labelsJSON" }
            #expect(labelsCol != nil)
            #expect(labelsCol?.isNotNull == true)
            // Default values in SQLite are stored as their literal SQL
            // representation. `'[]'` (quoted) is what GRDB writes for
            // `.defaults(to: "[]")`.
            #expect(labelsCol?.defaultValueSQL == "'[]'")
        }
    }

    @Test func malformedLabelsJSONDegradesToEmptyArray() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)
        let wsID = UUID().uuidString

        try await db.writer.write { db in
            let ws = WorkspaceRecord(
                id: wsID,
                name: "Corrupt",
                slug: "corrupt",
                color: "blue",
                layoutJSON: "{\"empty\":{}}",
                focusedPaneID: nil,
                createdAt: 1000,
                lastAccessedAt: 1000,
                sortOrder: 0,
                labelsJSON: "not valid json"
            )
            try ws.insert(db)
        }

        let result = await persistence.load()
        let loaded = result.workspaces[id: UUID(uuidString: wsID)!]
        #expect(loaded != nil)
        #expect(loaded?.labels == [])
    }

    @Test func legacyDatabaseHasEmptyTopLevelOrder() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        // Simulate a legacy DB: write workspaces directly without populating
        // topLevelOrder, then load. Caller (AppReducer) is responsible for
        // backfilling from the flat workspaces list.
        try await db.writer.write { db in
            for (idx, name) in ["First", "Second", "Third"].enumerated() {
                let ws = WorkspaceRecord(
                    id: UUID().uuidString,
                    name: name,
                    slug: name.lowercased(),
                    color: "blue",
                    layoutJSON: "{\"empty\":{}}",
                    focusedPaneID: nil,
                    createdAt: 1000,
                    lastAccessedAt: 1000,
                    sortOrder: idx,
                    labelsJSON: "[]"
                )
                try ws.insert(db)
            }
        }

        let result = await persistence.load()
        #expect(result.workspaces.count == 3)
        #expect(result.topLevelOrder.isEmpty)
        #expect(result.groups.isEmpty)
    }

    @Test func iconRoundTripsBothVariants() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let ws1 = WorkspaceFeature.State(name: "Ws1", color: .blue)
        let groupSystemID = UUID()
        let groupEmojiID = UUID()
        let groupFolderID = UUID()
        let systemGroup = WorkspaceGroup(
            id: groupSystemID,
            name: "System",
            childOrder: [],
            icon: .systemName("star.fill")
        )
        let emojiGroup = WorkspaceGroup(
            id: groupEmojiID,
            name: "Emoji",
            childOrder: [],
            icon: .emoji("🔥")
        )
        // Unset icon should round-trip as nil.
        let folderGroup = WorkspaceGroup(
            id: groupFolderID,
            name: "Folder",
            childOrder: [],
            icon: nil
        )

        let state = AppReducer.State(
            workspaces: [ws1],
            groups: [systemGroup, emojiGroup, folderGroup],
            topLevelOrder: [
                .workspace(ws1.id),
                .group(groupSystemID),
                .group(groupEmojiID),
                .group(groupFolderID)
            ],
            activeWorkspaceID: ws1.id
        )
        await persistence.save(snapshot: PersistenceSnapshot(state: state))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.groups[id: groupSystemID]?.icon == .systemName("star.fill"))
        #expect(result.groups[id: groupEmojiID]?.icon == .emoji("🔥"))
        #expect(result.groups[id: groupFolderID]?.icon == nil)
    }

    @Test func savingClearsRemovedGroups() async throws {
        let db = try DatabaseService(inMemory: true)
        let persistence = PersistenceService(db: db)

        let ws = WorkspaceFeature.State(name: "Solo", color: .red)
        let groupID = UUID()
        let group = WorkspaceGroup(id: groupID, name: "Temp", childOrder: [ws.id])

        let firstState = AppReducer.State(
            workspaces: [ws],
            groups: [group],
            topLevelOrder: [.group(groupID)],
            activeWorkspaceID: ws.id
        )
        await persistence.save(snapshot: PersistenceSnapshot(state: firstState))
        try await Task.sleep(for: .seconds(1))

        // Now save again with the group removed
        let secondState = AppReducer.State(
            workspaces: [ws],
            groups: [],
            topLevelOrder: [.workspace(ws.id)],
            activeWorkspaceID: ws.id
        )
        await persistence.save(snapshot: PersistenceSnapshot(state: secondState))
        try await Task.sleep(for: .seconds(1))

        let result = await persistence.load()
        #expect(result.groups.isEmpty)
        #expect(result.topLevelOrder == [.workspace(ws.id)])
    }
}
