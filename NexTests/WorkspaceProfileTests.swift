import ComposableArchitecture
import Foundation
@testable import Nex
import Testing

/// Workspace-profile tests (issue #233). Config-file parsing is covered in
/// `ConfigParserTests`, persistence in `PersistenceTests` /
/// `DatabaseMigrationTests`. This file exercises the reducer and socket
/// layers: `.setProfile` normalization, env resolution at surface spawn,
/// the `workspace-profile` / `workspace-create --profile` wire commands,
/// and the restart-restore path.
@MainActor
struct WorkspaceProfileTests {
    private static let wsID1 = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private static let wsID2 = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    private static let wsID3 = UUID(uuidString: "70000000-0000-0000-0000-000000000003")!
    private static let paneID1 = UUID(uuidString: "70000000-0000-0000-0000-0000000000B1")!
    private static let paneID2 = UUID(uuidString: "70000000-0000-0000-0000-0000000000B2")!
    private static let paneID3 = UUID(uuidString: "70000000-0000-0000-0000-0000000000B3")!
    private static let paneID4 = UUID(uuidString: "70000000-0000-0000-0000-0000000000B4")!
    private static let groupID = UUID(uuidString: "70000000-0000-0000-0000-0000000000A1")!

    private static func makeWorkspace(
        id: UUID,
        name: String,
        paneID: UUID,
        profileName: String? = nil
    ) -> WorkspaceFeature.State {
        WorkspaceFeature.State(
            id: id,
            name: name,
            slug: name.lowercased(),
            color: .blue,
            panes: [Pane(id: paneID)],
            layout: .leaf(paneID),
            focusedPaneID: paneID,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastAccessedAt: Date(timeIntervalSince1970: 1000),
            profileName: profileName
        )
    }

    private func makeAppStore(
        workspaces: IdentifiedArrayOf<WorkspaceFeature.State> = [],
        groups: IdentifiedArrayOf<WorkspaceGroup> = [],
        topLevelOrder: [SidebarID] = [],
        activeWorkspaceID: UUID? = nil,
        resolveEnv: (@Sendable (String) -> [String: String])? = nil
    ) -> TestStoreOf<AppReducer> {
        var appState = AppReducer.State()
        appState.workspaces = workspaces
        appState.groups = groups
        appState.topLevelOrder = topLevelOrder.isEmpty
            ? workspaces.map { .workspace($0.id) }
            : topLevelOrder
        appState.activeWorkspaceID = activeWorkspaceID

        let store = TestStore(initialState: appState) {
            AppReducer()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.gitService.getCurrentBranch = { _ in nil }
            $0.gitService.getStatus = { _ in .clean }
            $0.continuousClock = TestClock()
            if let resolveEnv {
                $0.workspaceProfiles.resolveEnv = resolveEnv
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    // MARK: - .setProfile normalization

    @Test func setProfileAssignsAndClears() async {
        let store = TestStore(initialState: WorkspaceFeature.State(name: "Test")) {
            WorkspaceFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setProfile("work")) { state in
            #expect(state.profileName == "work")
        }
        await store.send(.setProfile(nil)) { state in
            #expect(state.profileName == nil)
        }
    }

    @Test func setProfileNormalizesWhitespaceAndEmpty() async {
        let store = TestStore(initialState: WorkspaceFeature.State(name: "Test")) {
            WorkspaceFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setProfile("  padded  ")) { state in
            #expect(state.profileName == "padded")
        }
        await store.send(.setProfile("")) { state in
            #expect(state.profileName == nil)
        }
        await store.send(.setProfile("work")) { state in
            #expect(state.profileName == "work")
        }
        await store.send(.setProfile("   ")) { state in
            #expect(state.profileName == nil)
        }
    }

    // MARK: - Env resolution at spawn (WorkspaceFeature)

    @Test func splitPaneResolvesProfileEnv() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.profileName = "work"
        let sourceID = workspace.panes.first!.id
        let resolved = LockIsolated<[String]>([])

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(Self.paneID1)
            $0.workspaceProfiles.resolveEnv = { name in
                resolved.withValue { $0.append(name) }
                return ["NEX_PROFILE": name]
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPane(direction: .horizontal, sourcePaneID: sourceID))
        await store.finish()
        #expect(resolved.value == ["work"])
    }

    @Test func splitPaneWithoutProfileDoesNotResolve() async {
        let workspace = WorkspaceFeature.State(name: "Test")
        let sourceID = workspace.panes.first!.id
        let resolved = LockIsolated<[String]>([])

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(Self.paneID1)
            $0.workspaceProfiles.resolveEnv = { name in
                resolved.withValue { $0.append(name) }
                return [:]
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.splitPane(direction: .horizontal, sourcePaneID: sourceID))
        await store.finish()
        #expect(resolved.value.isEmpty)
    }

    @Test func createPaneResolvesProfileEnv() async {
        var workspace = WorkspaceFeature.State(name: "Test")
        workspace.profileName = "personal"
        let resolved = LockIsolated<[String]>([])

        let store = TestStore(initialState: workspace) {
            WorkspaceFeature()
        } withDependencies: {
            $0.surfaceManager = SurfaceManager()
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.uuid = .constant(Self.paneID2)
            $0.workspaceProfiles.resolveEnv = { name in
                resolved.withValue { $0.append(name) }
                return ["NEX_PROFILE": name]
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createPane())
        await store.finish()
        #expect(resolved.value == ["personal"])
    }

    // MARK: - Wire parsing

    private func jsonData(_ string: String) -> Data {
        Data(string.utf8)
    }

    @Test func parseWorkspaceCreateWithProfile() {
        let data = jsonData("""
        {"command":"workspace-create","name":"W","profile":"work"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceCreate(
            name: "W", path: nil, color: nil, group: nil, profile: "work"
        ))
    }

    @Test func parseWorkspaceCreateEmptyProfileNormalisesToNil() {
        let data = jsonData("""
        {"command":"workspace-create","name":"W","profile":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceCreate(
            name: "W", path: nil, color: nil, group: nil, profile: nil
        ))
    }

    @Test func parseWorkspaceProfileAssign() {
        let data = jsonData("""
        {"command":"workspace-profile","name":"alpha","profile":"work"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceProfile(nameOrID: "alpha", profile: "work"))
    }

    @Test func parseWorkspaceProfileMissingProfileIsClear() {
        let data = jsonData("""
        {"command":"workspace-profile","name":"alpha"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceProfile(nameOrID: "alpha", profile: nil))
    }

    @Test func parseWorkspaceProfileEmptyProfileIsClear() {
        let data = jsonData("""
        {"command":"workspace-profile","name":"alpha","profile":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceProfile(nameOrID: "alpha", profile: nil))
    }

    @Test func parseWorkspaceProfileRequiresName() {
        let data = jsonData("""
        {"command":"workspace-profile","profile":"work"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    // MARK: - Socket dispatch

    @Test func socketWorkspaceProfileAssignsByName() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "alpha", paneID: Self.paneID1)
        let store = makeAppStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .workspaceProfile(nameOrID: "alpha", profile: "work"), reply: nil
        ))
        await store.receive(\.workspaces) { state in
            #expect(state.workspaces[id: Self.wsID1]?.profileName == "work")
        }
    }

    @Test func socketWorkspaceProfileAssignsByUUID() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "alpha", paneID: Self.paneID1)
        let store = makeAppStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .workspaceProfile(nameOrID: Self.wsID1.uuidString, profile: "personal"),
            reply: nil
        ))
        await store.receive(\.workspaces) { state in
            #expect(state.workspaces[id: Self.wsID1]?.profileName == "personal")
        }
    }

    @Test func socketWorkspaceProfileClears() async {
        let ws = Self.makeWorkspace(
            id: Self.wsID1, name: "alpha", paneID: Self.paneID1, profileName: "work"
        )
        let store = makeAppStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .workspaceProfile(nameOrID: "alpha", profile: nil), reply: nil
        ))
        await store.receive(\.workspaces) { state in
            #expect(state.workspaces[id: Self.wsID1]?.profileName == nil)
        }
    }

    @Test func socketWorkspaceProfileAmbiguousNameIsNoOp() async {
        let a = Self.makeWorkspace(id: Self.wsID1, name: "dupe", paneID: Self.paneID1)
        let b = Self.makeWorkspace(id: Self.wsID2, name: "dupe", paneID: Self.paneID2)
        let store = makeAppStore(workspaces: [a, b], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .workspaceProfile(nameOrID: "dupe", profile: "work"), reply: nil
        ))
        #expect(store.state.workspaces[id: Self.wsID1]?.profileName == nil)
        #expect(store.state.workspaces[id: Self.wsID2]?.profileName == nil)
    }

    @Test func socketWorkspaceProfileUnknownNameIsNoOp() async {
        let ws = Self.makeWorkspace(id: Self.wsID1, name: "alpha", paneID: Self.paneID1)
        let store = makeAppStore(workspaces: [ws], activeWorkspaceID: Self.wsID1)

        await store.send(.socketMessage(
            .workspaceProfile(nameOrID: "missing", profile: "work"), reply: nil
        ))
        #expect(store.state.workspaces[id: Self.wsID1]?.profileName == nil)
    }

    // MARK: - workspace-create --profile

    @Test func socketWorkspaceCreateWithProfileAssigns() async {
        let store = makeAppStore()

        await store.send(.socketMessage(.workspaceCreate(
            name: "Alpha", path: nil, color: .blue, group: nil, profile: "work"
        ), reply: nil))
        await store.receive(\.createWorkspace) { state in
            #expect(state.workspaces.count == 1)
            #expect(state.workspaces.first?.profileName == "work")
        }
    }

    @Test func socketWorkspaceCreateGroupPathAssignsProfile() async {
        let group = WorkspaceGroup(id: Self.groupID, name: "Monitors", childOrder: [])
        let store = makeAppStore(groups: [group], topLevelOrder: [.group(Self.groupID)])

        await store.send(.socketMessage(.workspaceCreate(
            name: "Alpha", path: "/tmp", color: .blue, group: "Monitors", profile: "work"
        ), reply: nil)) { state in
            #expect(state.workspaces.first?.profileName == "work")
        }
    }

    @Test func createWorkspaceNormalizesProfileName() async {
        let store = makeAppStore()

        await store.send(.createWorkspace(name: "Padded", profileName: "  work  ")) { state in
            #expect(state.workspaces.first?.profileName == "work")
        }
    }

    @Test func createWorkspaceEmptyProfileNameStaysNil() async {
        let store = makeAppStore()

        await store.send(.createWorkspace(name: "Plain", profileName: "   ")) { state in
            #expect(state.workspaces.first?.profileName == nil)
        }
    }

    // MARK: - Env assembly (SurfaceView.mergedEnvVars)

    @Test func mergedEnvVarsBuiltinsFirstThenProfileSorted() {
        let merged = SurfaceView.mergedEnvVars(
            paneID: "PANE-ID",
            path: "/helpers:/bin",
            profileEnv: ["ZED": "z", "ALPHA": "a", "NEX_PROFILE": "work"]
        )
        #expect(merged.map(\.key) == ["NEX_PANE_ID", "PATH", "ALPHA", "NEX_PROFILE", "ZED"])
        #expect(merged[0].value == "PANE-ID")
        #expect(merged[1].value == "/helpers:/bin")
    }

    @Test func mergedEnvVarsFiltersReservedKeys() {
        let merged = SurfaceView.mergedEnvVars(
            paneID: "PANE-ID",
            path: "/real-path",
            profileEnv: ["NEX_PANE_ID": "hacked", "PATH": "/evil", "OK": "1"]
        )
        #expect(merged.map(\.key) == ["NEX_PANE_ID", "PATH", "OK"])
        #expect(merged.first(where: { $0.key == "NEX_PANE_ID" })?.value == "PANE-ID")
        #expect(merged.first(where: { $0.key == "PATH" })?.value == "/real-path")
    }

    @Test func mergedEnvVarsEmptyProfileIsJustBuiltins() {
        let merged = SurfaceView.mergedEnvVars(paneID: "P", path: "/p", profileEnv: [:])
        #expect(merged.map(\.key) == ["NEX_PANE_ID", "PATH"])
    }

    // MARK: - Live resolveEnv against a temp config file

    @Test func liveResolveEnvInjectsVarsAndCanonicalMarker() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nex-profile-test-\(UUID().uuidString)")
        try "profile = work:FOO=bar\nprofile = work:NEX_PROFILE=spoofed\n"
            .write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let env = WorkspaceProfilesClient.resolveEnv("work", configPath: tmp.path)
        #expect(env["FOO"] == "bar")
        // A config line spoofing NEX_PROFILE loses to the canonical marker.
        #expect(env["NEX_PROFILE"] == "work")
    }

    @Test func liveResolveEnvUndefinedProfileYieldsMarkerOnly() {
        let env = WorkspaceProfilesClient.resolveEnv(
            "ghost", configPath: "/nonexistent/nex-config"
        )
        #expect(env == ["NEX_PROFILE": "ghost"])
    }

    // MARK: - Restart-restore

    @Test func stateLoadedResolvesEnvPerProfileNotPerPane() async {
        // ws1 (profile "work", one pane), ws2 (profile "personal", two
        // panes — exercises the per-profile cache), ws3 (no profile).
        let ws1 = Self.makeWorkspace(
            id: Self.wsID1, name: "W1", paneID: Self.paneID1, profileName: "work"
        )
        var ws2 = Self.makeWorkspace(
            id: Self.wsID2, name: "W2", paneID: Self.paneID2, profileName: "personal"
        )
        ws2.panes.append(Pane(id: Self.paneID3))
        let ws3 = Self.makeWorkspace(id: Self.wsID3, name: "W3", paneID: Self.paneID4)

        let resolved = LockIsolated<[String]>([])
        let store = makeAppStore(resolveEnv: { name in
            resolved.withValue { $0.append(name) }
            return ["NEX_PROFILE": name]
        })

        await store.send(.stateLoaded(
            [ws1, ws2, ws3],
            groups: [],
            topLevelOrder: [],
            activeWorkspaceID: Self.wsID1,
            repoRegistry: []
        ))
        // `.persistState` is sent at the end of the same effect that spawns
        // the restored surfaces, so receiving it means the spawn loop (and
        // its resolveEnv calls) completed.
        await store.receive(\.persistState)
        #expect(resolved.value == ["work", "personal"])
    }
}
