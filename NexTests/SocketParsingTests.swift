import Foundation
@testable import Nex
import Testing

struct SocketParsingTests {
    private static let paneUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let paneIDString = "00000000-0000-0000-0000-000000000001"

    private func jsonData(_ string: String) -> Data {
        string.data(using: .utf8)!
    }

    // MARK: - parseWireMessage — Agent lifecycle

    @Test func parseStartCommand() {
        let data = jsonData("""
        {"command":"start","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .agentStarted(paneID: Self.paneUUID))
    }

    @Test func parseStopCommand() {
        let data = jsonData("""
        {"command":"stop","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .agentStopped(paneID: Self.paneUUID))
    }

    @Test func parseErrorCommand() {
        let data = jsonData("""
        {"command":"error","pane_id":"\(Self.paneIDString)","message":"something broke"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .agentError(paneID: Self.paneUUID, message: "something broke"))
    }

    @Test func parseNotificationCommand() {
        let data = jsonData("""
        {"command":"notification","pane_id":"\(Self.paneIDString)","title":"Done","body":"Task complete"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .notification(paneID: Self.paneUUID, title: "Done", body: "Task complete"))
    }

    @Test func parseSessionStartCommand() {
        let data = jsonData("""
        {"command":"session-start","pane_id":"\(Self.paneIDString)","session_id":"sess-abc"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .sessionStarted(paneID: Self.paneUUID, sessionID: "sess-abc"))
    }

    @Test func parseSessionStartMissingSessionID() {
        let data = jsonData("""
        {"command":"session-start","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    // MARK: - parseWireMessage — Pane commands

    @Test func parsePaneSplitCommand() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)","direction":"vertical","path":"/tmp"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: .vertical, path: "/tmp", name: nil, target: nil))
    }

    @Test func parsePaneSplitMinimal() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: nil, path: nil, name: nil, target: nil))
    }

    @Test func parsePaneSplitWithName() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)","direction":"horizontal","name":"worker-1"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: .horizontal, path: nil, name: "worker-1", target: nil))
    }

    @Test func parsePaneSplitWithTarget() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)","name":"sub-1","target":"worker-1"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: nil, path: nil, name: "sub-1", target: "worker-1"))
    }

    @Test func parsePaneCreateCommand() {
        let data = jsonData("""
        {"command":"pane-create","pane_id":"\(Self.paneIDString)","path":"/home/user"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneCreate(paneID: Self.paneUUID, path: "/home/user", name: nil, target: nil))
    }

    @Test func parsePaneCreateWithName() {
        let data = jsonData("""
        {"command":"pane-create","pane_id":"\(Self.paneIDString)","path":"/tmp","name":"build"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneCreate(paneID: Self.paneUUID, path: "/tmp", name: "build", target: nil))
    }

    @Test func parsePaneCloseCommand() {
        let data = jsonData("""
        {"command":"pane-close","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneClose(paneID: Self.paneUUID, target: nil, workspace: nil))
    }

    @Test func parsePaneCloseWithTarget() {
        // `--target <name-or-uuid>` lets callers outside Nex close a
        // pane without NEX_PANE_ID. The reducer resolves the label.
        let data = jsonData("""
        {"command":"pane-close","target":"worker-1"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneClose(paneID: nil, target: "worker-1", workspace: nil))
    }

    @Test func parsePaneCloseWithTargetAndPaneID() {
        // If both are supplied, the wire decoder keeps them both and
        // the reducer prefers `target`.
        let data = jsonData("""
        {"command":"pane-close","pane_id":"\(Self.paneIDString)","target":"worker-1"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneClose(paneID: Self.paneUUID, target: "worker-1", workspace: nil))
    }

    @Test func parsePaneCloseWithWorkspace() {
        // `--workspace <name-or-uuid>` narrows label resolution to a
        // specific workspace — disambiguates cross-workspace label
        // collisions.
        let data = jsonData("""
        {"command":"pane-close","target":"worker","workspace":"alpha"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneClose(paneID: nil, target: "worker", workspace: "alpha"))
    }

    @Test func parsePaneCloseEmptyWorkspaceNormalisedToNil() {
        let data = jsonData("""
        {"command":"pane-close","target":"worker","workspace":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneClose(paneID: nil, target: "worker", workspace: nil))
    }

    @Test func parsePaneCloseMissingBothRejected() {
        let data = jsonData("""
        {"command":"pane-close"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneCloseEmptyTargetNormalisedToNil() {
        // An empty `target` is dropped — without a pane_id, the
        // message is rejected so a cleared field doesn't accidentally
        // resolve to something odd.
        let data = jsonData("""
        {"command":"pane-close","target":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneNameCommand() {
        let data = jsonData("""
        {"command":"pane-name","pane_id":"\(Self.paneIDString)","name":"my-pane"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneName(paneID: Self.paneUUID, name: "my-pane"))
    }

    @Test func parsePaneNameMissingName() {
        let data = jsonData("""
        {"command":"pane-name","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneSendCommand() {
        let data = jsonData("""
        {"command":"pane-send","pane_id":"\(Self.paneIDString)","target":"build","text":"make test"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSend(paneID: Self.paneUUID, target: "build", text: "make test"))
    }

    @Test func parsePaneSendMissingTarget() {
        let data = jsonData("""
        {"command":"pane-send","pane_id":"\(Self.paneIDString)","text":"ls"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneSendMissingText() {
        let data = jsonData("""
        {"command":"pane-send","pane_id":"\(Self.paneIDString)","target":"build"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    // MARK: - parseWireMessage — Workspace commands

    @Test func parseWorkspaceCreateCommand() {
        let data = jsonData("""
        {"command":"workspace-create","name":"Test","path":"/tmp","color":"green"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .workspaceCreate(name: "Test", path: "/tmp", color: .green, group: nil))
    }

    @Test func parseWorkspaceCreateMinimal() {
        let data = jsonData("""
        {"command":"workspace-create"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .workspaceCreate(name: nil, path: nil, color: nil, group: nil))
    }

    @Test func parseWorkspaceCreateNoPaneIDRequired() {
        // workspace-create should work without pane_id
        let data = jsonData("""
        {"command":"workspace-create","name":"New"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .workspaceCreate(name: "New", path: nil, color: nil, group: nil))
    }

    @Test func parseWorkspaceCreateWithGroup() {
        let data = jsonData("""
        {"command":"workspace-create","name":"New","group":"Monitors"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceCreate(
            name: "New",
            path: nil,
            color: nil,
            group: "Monitors"
        ))
    }

    @Test func parseWorkspaceMoveIntoGroup() {
        let data = jsonData("""
        {"command":"workspace-move","name":"Alpha","group":"Monitors","index":2}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceMove(
            nameOrID: "Alpha",
            group: "Monitors",
            index: 2
        ))
    }

    @Test func parseWorkspaceMoveToTopLevel() {
        // Missing `group` = top-level (detach from current parent).
        let data = jsonData("""
        {"command":"workspace-move","name":"Alpha"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceMove(
            nameOrID: "Alpha",
            group: nil,
            index: nil
        ))
    }

    @Test func parseWorkspaceMoveEmptyGroupNormalisesToNil() {
        // Empty-string `group` is normalised to nil so a cleared
        // field doesn't accidentally resolve to a group named "".
        let data = jsonData("""
        {"command":"workspace-move","name":"Alpha","group":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .workspaceMove(nameOrID: "Alpha", group: nil, index: nil))
    }

    @Test func parseWorkspaceMoveMissingNameRejected() {
        let data = jsonData("""
        {"command":"workspace-move","group":"Monitors"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    // MARK: - parseWireMessage — Group commands

    @Test func parseGroupCreateMinimal() {
        let data = jsonData("""
        {"command":"group-create","name":"Monitors"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .groupCreate(name: "Monitors", color: nil))
    }

    @Test func parseGroupCreateWithColor() {
        let data = jsonData("""
        {"command":"group-create","name":"Monitors","color":"blue"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .groupCreate(name: "Monitors", color: .blue))
    }

    @Test func parseGroupCreateMissingNameRejected() {
        let data = jsonData("""
        {"command":"group-create"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parseGroupRename() {
        let data = jsonData("""
        {"command":"group-rename","name":"Old","new_name":"New"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .groupRename(nameOrID: "Old", newName: "New"))
    }

    @Test func parseGroupRenameMissingNewNameRejected() {
        let data = jsonData("""
        {"command":"group-rename","name":"Old"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parseGroupDeleteDefaultsToPromoteChildren() {
        let data = jsonData("""
        {"command":"group-delete","name":"Monitors"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .groupDelete(nameOrID: "Monitors", cascade: false))
    }

    @Test func parseGroupDeleteWithCascade() {
        let data = jsonData("""
        {"command":"group-delete","name":"Monitors","cascade":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .groupDelete(nameOrID: "Monitors", cascade: true))
    }

    // MARK: - parseWireMessage — File commands

    @Test func parseOpenCommand() {
        let data = jsonData("""
        {"command":"open","path":"/tmp/plan.md","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .openFile(path: "/tmp/plan.md", paneID: Self.paneUUID, reuse: false))
    }

    @Test func parseOpenCommandNoPaneID() {
        let data = jsonData("""
        {"command":"open","path":"/tmp/plan.md"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .openFile(path: "/tmp/plan.md", paneID: nil, reuse: false))
    }

    @Test func parseOpenCommandMissingPath() {
        let data = jsonData("""
        {"command":"open","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parseOpenCommandEmptyPath() {
        let data = jsonData("""
        {"command":"open","path":"","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parseOpenCommandWithReuse() {
        let data = jsonData("""
        {"command":"open","path":"/tmp/plan.md","pane_id":"\(Self.paneIDString)","reuse":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .openFile(path: "/tmp/plan.md", paneID: Self.paneUUID, reuse: true))
    }

    @Test func parseOpenCommandReuseFalseExplicit() {
        let data = jsonData("""
        {"command":"open","path":"/tmp/plan.md","pane_id":"\(Self.paneIDString)","reuse":false}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .openFile(path: "/tmp/plan.md", paneID: Self.paneUUID, reuse: false))
    }

    // MARK: - parseWireMessage — Error cases

    @Test func parseUnknownCommand() {
        let data = jsonData("""
        {"command":"explode","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parseInvalidJSON() {
        let data = jsonData("not json at all")
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parseInvalidUUID() {
        let data = jsonData("""
        {"command":"start","pane_id":"not-a-uuid"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parseMissingPaneID() {
        let data = jsonData("""
        {"command":"start"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    // MARK: - parseMessages

    @Test func parseMultipleLines() {
        let input = """
        {"command":"start","pane_id":"\(Self.paneIDString)"}
        {"command":"stop","pane_id":"\(Self.paneIDString)"}
        """
        let results = SocketServer.parseMessages(jsonData(input))
        #expect(results.count == 2)
        #expect(results[0] == .agentStarted(paneID: Self.paneUUID))
        #expect(results[1] == .agentStopped(paneID: Self.paneUUID))
    }

    @Test func parseDataInvalidJSONSkipped() {
        let input = """
        {"command":"start","pane_id":"\(Self.paneIDString)"}
        this is garbage
        {"command":"stop","pane_id":"\(Self.paneIDString)"}
        """
        let results = SocketServer.parseMessages(jsonData(input))
        #expect(results.count == 2)
        #expect(results[0] == .agentStarted(paneID: Self.paneUUID))
        #expect(results[1] == .agentStopped(paneID: Self.paneUUID))
    }

    @Test func parseSessionIDDualFire() {
        let input = """
        {"command":"stop","pane_id":"\(Self.paneIDString)","session_id":"sess-xyz"}
        """
        let results = SocketServer.parseMessages(jsonData(input))
        // Should produce two messages: .agentStopped + .sessionStarted
        #expect(results.count == 2)
        #expect(results[0] == .agentStopped(paneID: Self.paneUUID))
        #expect(results[1] == .sessionStarted(paneID: Self.paneUUID, sessionID: "sess-xyz"))
    }

    @Test func parseSessionStartNoDualFire() {
        let input = """
        {"command":"session-start","pane_id":"\(Self.paneIDString)","session_id":"sess-xyz"}
        """
        let results = SocketServer.parseMessages(jsonData(input))
        // session-start with session_id should NOT dual-fire
        #expect(results.count == 1)
        #expect(results[0] == .sessionStarted(paneID: Self.paneUUID, sessionID: "sess-xyz"))
    }

    @Test func parseDataEmptyInput() {
        let results = SocketServer.parseMessages(Data())
        #expect(results.isEmpty)
    }

    @Test func parseDataBlankLines() {
        let input = "\n\n   \n"
        let results = SocketServer.parseMessages(jsonData(input))
        #expect(results.isEmpty)
    }

    @Test func parseMixedCommandTypes() {
        let input = """
        {"command":"start","pane_id":"\(Self.paneIDString)"}
        {"command":"pane-split","pane_id":"\(Self.paneIDString)","direction":"horizontal"}
        {"command":"workspace-create","name":"New"}
        """
        let results = SocketServer.parseMessages(jsonData(input))
        #expect(results.count == 3)
        #expect(results[0] == .agentStarted(paneID: Self.paneUUID))
        #expect(results[1] == .paneSplit(paneID: Self.paneUUID, direction: .horizontal, path: nil, name: nil, target: nil))
        #expect(results[2] == .workspaceCreate(name: "New", path: nil, color: nil, group: nil))
    }

    // MARK: - Pane move commands

    @Test func parsePaneMoveLeft() {
        let data = jsonData("""
        {"command":"pane-move","pane_id":"\(Self.paneIDString)","direction":"left"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneMove(paneID: Self.paneUUID, direction: .left))
    }

    @Test func parsePaneMoveAllDirections() {
        for dir in PaneLayout.Direction.allCases {
            let data = jsonData("""
            {"command":"pane-move","pane_id":"\(Self.paneIDString)","direction":"\(dir.rawValue)"}
            """)
            let result = SocketServer.parseWireMessage(data)
            #expect(result != nil)
            #expect(result?.0 == .paneMove(paneID: Self.paneUUID, direction: dir))
        }
    }

    @Test func parsePaneMoveMissingDirectionReturnsNil() {
        let data = jsonData("""
        {"command":"pane-move","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneMoveInvalidDirectionReturnsNil() {
        let data = jsonData("""
        {"command":"pane-move","pane_id":"\(Self.paneIDString)","direction":"diagonal"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    // MARK: - Pane move-to-workspace commands

    @Test func parsePaneMoveToWorkspace() {
        let data = jsonData("""
        {"command":"pane-move-to-workspace","pane_id":"\(Self.paneIDString)","name":"logs"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneMoveToWorkspace(paneID: Self.paneUUID, toWorkspace: "logs", create: false))
    }

    @Test func parsePaneMoveToWorkspaceWithCreate() {
        let data = jsonData("""
        {"command":"pane-move-to-workspace","pane_id":"\(Self.paneIDString)","name":"staging","text":"true"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneMoveToWorkspace(paneID: Self.paneUUID, toWorkspace: "staging", create: true))
    }

    @Test func parsePaneMoveToWorkspaceMissingNameReturnsNil() {
        let data = jsonData("""
        {"command":"pane-move-to-workspace","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneMoveToWorkspaceEmptyNameReturnsNil() {
        let data = jsonData("""
        {"command":"pane-move-to-workspace","pane_id":"\(Self.paneIDString)","name":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    // MARK: - Layout commands

    @Test func parseLayoutCycleCommand() {
        let data = jsonData("""
        {"command":"layout-cycle","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .layoutCycle(paneID: Self.paneUUID))
    }

    @Test func parseLayoutSelectCommand() {
        let data = jsonData("""
        {"command":"layout-select","pane_id":"\(Self.paneIDString)","name":"tiled"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .layoutSelect(paneID: Self.paneUUID, name: "tiled"))
    }

    @Test func parseLayoutSelectMissingNameReturnsNil() {
        let data = jsonData("""
        {"command":"layout-select","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    // MARK: - pane-list (request/response)

    @Test func parsePaneListNoFilter() {
        let data = jsonData("""
        {"command":"pane-list"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneList(paneID: nil, workspace: nil, scope: nil))
    }

    @Test func parsePaneListWithWorkspaceFilter() {
        let data = jsonData("""
        {"command":"pane-list","workspace":"nex"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneList(paneID: nil, workspace: "nex", scope: nil))
    }

    @Test func parsePaneListWithScopeCurrent() {
        let data = jsonData("""
        {"command":"pane-list","pane_id":"\(Self.paneIDString)","scope":"current"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneList(paneID: Self.paneUUID, workspace: nil, scope: "current"))
    }

    @Test func parsePaneListEmptyWorkspaceNormalisedToNil() {
        // Defensive — an empty-string workspace field should not be
        // treated as a name-or-ID to resolve.
        let data = jsonData("""
        {"command":"pane-list","workspace":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneList(paneID: nil, workspace: nil, scope: nil))
    }

    @Test func parsePaneListEmptyScopeNormalisedToNil() {
        let data = jsonData("""
        {"command":"pane-list","scope":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneList(paneID: nil, workspace: nil, scope: nil))
    }

    @Test func parsePaneListIgnoresUnknownPaneID() {
        // A malformed pane_id collapses to nil — the reducer will
        // surface the error when scope=current requires a valid id.
        let data = jsonData("""
        {"command":"pane-list","pane_id":"not-a-uuid"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneList(paneID: nil, workspace: nil, scope: nil))
    }
}
