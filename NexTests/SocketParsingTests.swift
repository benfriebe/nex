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

    @Test func parseSessionEndCommand() {
        let data = jsonData("""
        {"command":"session-end","pane_id":"\(Self.paneIDString)","session_id":"sess-abc"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .sessionEnded(paneID: Self.paneUUID, sessionID: "sess-abc"))
    }

    @Test func parseSessionEndMissingSessionID() {
        let data = jsonData("""
        {"command":"session-end","pane_id":"\(Self.paneIDString)"}
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
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: .vertical, path: "/tmp", name: nil, target: nil, workspace: nil))
    }

    @Test func parsePaneSplitMinimal() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: nil, path: nil, name: nil, target: nil, workspace: nil))
    }

    @Test func parsePaneSplitWithName() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)","direction":"horizontal","name":"worker-1"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: .horizontal, path: nil, name: "worker-1", target: nil, workspace: nil))
    }

    @Test func parsePaneSplitWithTarget() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)","name":"sub-1","target":"worker-1"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: nil, path: nil, name: "sub-1", target: "worker-1", workspace: nil))
    }

    @Test func parsePaneCreateCommand() {
        let data = jsonData("""
        {"command":"pane-create","pane_id":"\(Self.paneIDString)","path":"/home/user"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneCreate(paneID: Self.paneUUID, path: "/home/user", name: nil, target: nil, workspace: nil))
    }

    @Test func parsePaneCreateWithName() {
        let data = jsonData("""
        {"command":"pane-create","pane_id":"\(Self.paneIDString)","path":"/tmp","name":"build"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneCreate(paneID: Self.paneUUID, path: "/tmp", name: "build", target: nil, workspace: nil))
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
        #expect(result?.0 == .paneName(paneID: Self.paneUUID, target: nil, workspace: nil, name: "my-pane"))
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
        #expect(result?.0 == .paneSend(paneID: Self.paneUUID, target: "build", text: "make test", workspace: nil, bare: false))
    }

    @Test func parsePaneSendWithWorkspace() {
        let data = jsonData("""
        {"command":"pane-send","pane_id":"\(Self.paneIDString)","target":"worker","text":"echo","workspace":"beta"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSend(paneID: Self.paneUUID, target: "worker", text: "echo", workspace: "beta", bare: false))
    }

    @Test func parsePaneSendEmptyWorkspaceNormalisedToNil() {
        let data = jsonData("""
        {"command":"pane-send","pane_id":"\(Self.paneIDString)","target":"worker","text":"echo","workspace":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSend(paneID: Self.paneUUID, target: "worker", text: "echo", workspace: nil, bare: false))
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

    @Test func parsePaneSendWithBareFlag() {
        // `--bare` (issue #98) — text only, no trailing Enter. Pair
        // with pane-send-key for compositional input (autocomplete,
        // multi-key sequences).
        let data = jsonData("""
        {"command":"pane-send","pane_id":"\(Self.paneIDString)","target":"build","text":"ls /tm","bare":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneSend(paneID: Self.paneUUID, target: "build", text: "ls /tm", workspace: nil, bare: true))
    }

    @Test func parsePaneSendBareDefaultsFalse() {
        // Old CLIs that don't know about --bare omit the field; the
        // wire decoder must default to false so existing behaviour is
        // unchanged.
        let data = jsonData("""
        {"command":"pane-send","pane_id":"\(Self.paneIDString)","target":"build","text":"ls"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .paneSend(paneID: Self.paneUUID, target: "build", text: "ls", workspace: nil, bare: false))
    }

    // MARK: - parseWireMessage — pane-send-key (issue #98)

    @Test func parsePaneSendKeyCommand() {
        let data = jsonData("""
        {"command":"pane-send-key","pane_id":"\(Self.paneIDString)","target":"worker","key":"enter"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSendKey(paneID: Self.paneUUID, target: "worker", key: "enter", workspace: nil))
    }

    @Test func parsePaneSendKeyWithWorkspace() {
        let data = jsonData("""
        {"command":"pane-send-key","pane_id":"\(Self.paneIDString)","target":"worker","key":"tab","workspace":"beta"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSendKey(paneID: Self.paneUUID, target: "worker", key: "tab", workspace: "beta"))
    }

    @Test func parsePaneSendKeyEmptyWorkspaceNormalisedToNil() {
        let data = jsonData("""
        {"command":"pane-send-key","pane_id":"\(Self.paneIDString)","target":"worker","key":"enter","workspace":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSendKey(paneID: Self.paneUUID, target: "worker", key: "enter", workspace: nil))
    }

    @Test func parsePaneSendKeyMissingTarget() {
        let data = jsonData("""
        {"command":"pane-send-key","pane_id":"\(Self.paneIDString)","key":"enter"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneSendKeyMissingKey() {
        let data = jsonData("""
        {"command":"pane-send-key","pane_id":"\(Self.paneIDString)","target":"worker"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneSendKeyEmptyKeyRejected() {
        let data = jsonData("""
        {"command":"pane-send-key","pane_id":"\(Self.paneIDString)","target":"worker","key":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result == nil)
    }

    @Test func parsePaneSendKeyWithoutPaneIDAccepted() {
        // External callers without a NEX_PANE_ID still produce a
        // valid wire message; the reducer's resolvePaneTarget will
        // demand --workspace for label targets.
        let data = jsonData("""
        {"command":"pane-send-key","target":"worker","key":"enter","workspace":"alpha"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSendKey(paneID: nil, target: "worker", key: "enter", workspace: "alpha"))
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

    @Test func parseSessionEndNoDualFire() {
        let input = """
        {"command":"session-end","pane_id":"\(Self.paneIDString)","session_id":"sess-xyz"}
        """
        let results = SocketServer.parseMessages(jsonData(input))
        // session-end carries session_id but must NOT dual-fire
        // .sessionStarted — that would re-attach the id it exists to drop.
        #expect(results.count == 1)
        #expect(results[0] == .sessionEnded(paneID: Self.paneUUID, sessionID: "sess-xyz"))
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
        #expect(results[1] == .paneSplit(paneID: Self.paneUUID, direction: .horizontal, path: nil, name: nil, target: nil, workspace: nil))
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

    // MARK: - parseWireMessage — Graft

    @Test func parseGraftStartWithFilters() {
        let data = jsonData("""
        {"command":"graft-start","workspace":"Dev","repo":"my-repo","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .graftStart(workspace: "Dev", repo: "my-repo", paneID: Self.paneUUID))
    }

    @Test func parseGraftStartBare() {
        let data = jsonData("""
        {"command":"graft-start"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .graftStart(workspace: nil, repo: nil, paneID: nil))
    }

    @Test func parseGraftStartEmptyStringsNormalised() {
        let data = jsonData("""
        {"command":"graft-start","workspace":"","repo":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .graftStart(workspace: nil, repo: nil, paneID: nil))
    }

    @Test func parseGraftStop() {
        let data = jsonData("""
        {"command":"graft-stop","workspace":"Dev"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .graftStop(workspace: "Dev", repo: nil, paneID: nil))
    }

    @Test func parseGraftStatus() {
        let data = jsonData("""
        {"command":"graft-status"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .graftStatus)
    }

    @Test func parsePing() {
        let data = jsonData("""
        {"command":"ping"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .ping)
    }

    // MARK: - parseWireMessage — Phase 3 web console/inspector

    @Test func parseWebConsoleDefaults() {
        let data = jsonData("""
        {"command":"web-console","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webConsole(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            since: 0,
            level: nil,
            clear: false
        ))
    }

    @Test func parseWebConsoleWithFilters() {
        let data = jsonData("""
        {"command":"web-console","pane_id":"\(Self.paneIDString)",
         "since":42,"level":"error","clear":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webConsole(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            since: 42,
            level: "error",
            clear: true
        ))
    }

    @Test func parseWebConsoleEmptyLevelNormalisedToNil() {
        let data = jsonData("""
        {"command":"web-console","pane_id":"\(Self.paneIDString)","level":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webConsole(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            since: 0,
            level: nil,
            clear: false
        ))
    }

    @Test func parseWebConsoleRequiresScope() {
        // No pane_id and no target — `parseWebTarget` rejects.
        let data = jsonData("""
        {"command":"web-console"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebConsoleByTargetWithWorkspace() {
        let data = jsonData("""
        {"command":"web-console","target":"main","workspace":"Dev"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webConsole(
            paneID: nil,
            target: "main",
            workspace: "Dev",
            since: 0,
            level: nil,
            clear: false
        ))
    }

    @Test func parseWebInspectArm() {
        let data = jsonData("""
        {"command":"web-inspect","pane_id":"\(Self.paneIDString)",
         "send_to":"agent","submit":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webInspect(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            sendTo: "agent",
            submit: true,
            disarm: false
        ))
    }

    @Test func parseWebInspectDisarm() {
        let data = jsonData("""
        {"command":"web-inspect","pane_id":"\(Self.paneIDString)","disarm":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webInspect(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            sendTo: nil,
            submit: false,
            disarm: true
        ))
    }

    @Test func parseWebInspectEmptySendToNormalisedToNil() {
        let data = jsonData("""
        {"command":"web-inspect","pane_id":"\(Self.paneIDString)","send_to":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webInspect(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            sendTo: nil,
            submit: false,
            disarm: false
        ))
    }

    @Test func parseWebInspectRequiresScope() {
        let data = jsonData("""
        {"command":"web-inspect"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebInspectResultBare() {
        let data = jsonData("""
        {"command":"web-inspect-result","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webInspectResult(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            clear: false
        ))
    }

    @Test func parseWebInspectResultClear() {
        let data = jsonData("""
        {"command":"web-inspect-result","pane_id":"\(Self.paneIDString)","clear":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webInspectResult(
            paneID: Self.paneUUID,
            target: nil,
            workspace: nil,
            clear: true
        ))
    }

    @Test func parseWebInspectResultRequiresScope() {
        let data = jsonData("""
        {"command":"web-inspect-result"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    // MARK: - Phase 5 — private mode + cookies

    @Test func parseWebOpenDefaultsToPublic() {
        let data = jsonData("""
        {"command":"web-open","url":"https://example.com"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webOpen(
            paneID: nil, url: "https://example.com", isPrivate: false
        ))
    }

    @Test func parseWebOpenWithPrivateFlag() {
        let data = jsonData("""
        {"command":"web-open","url":"https://example.com","private":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webOpen(
            paneID: nil, url: "https://example.com", isPrivate: true
        ))
    }

    @Test func parseWebNavigateByTargetLabel() {
        let data = jsonData("""
        {"command":"web-navigate","target":"web","workspace":"Dev","url":"https://example.com"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webNavigate(
            paneID: nil, target: "web", workspace: "Dev", url: "https://example.com"
        ))
    }

    @Test func parseWebNavigateByPaneID() {
        let data = jsonData("""
        {"command":"web-navigate","pane_id":"\(Self.paneIDString)","url":"https://example.com/path"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webNavigate(
            paneID: Self.paneUUID, target: nil, workspace: nil, url: "https://example.com/path"
        ))
    }

    @Test func parseWebNavigateRequiresURL() {
        let data = jsonData("""
        {"command":"web-navigate","pane_id":"\(Self.paneIDString)"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebNavigateRejectsEmptyURL() {
        let data = jsonData("""
        {"command":"web-navigate","pane_id":"\(Self.paneIDString)","url":""}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebPrivateOn() {
        let data = jsonData("""
        {"command":"web-private","pane_id":"\(Self.paneIDString)","private":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webPrivate(
            paneID: Self.paneUUID, target: nil, workspace: nil, enabled: true
        ))
    }

    @Test func parseWebPrivateOff() {
        let data = jsonData("""
        {"command":"web-private","target":"web","workspace":"Dev","private":false}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webPrivate(
            paneID: nil, target: "web", workspace: "Dev", enabled: false
        ))
    }

    @Test func parseWebPrivateRequiresFlag() {
        let data = jsonData("""
        {"command":"web-private","pane_id":"\(Self.paneIDString)"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebCookiesList() {
        let data = jsonData("""
        {"command":"web-cookies-list","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webCookiesList(
            paneID: Self.paneUUID, target: nil, workspace: nil
        ))
    }

    @Test func parseWebCookiesClearAllSiteData() {
        let data = jsonData("""
        {"command":"web-cookies-clear","pane_id":"\(Self.paneIDString)","all":true}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webCookiesClear(
            paneID: Self.paneUUID, target: nil, workspace: nil, domain: nil, all: true
        ))
    }

    @Test func parseWebCookiesClearScopedToDomain() {
        let data = jsonData("""
        {"command":"web-cookies-clear","pane_id":"\(Self.paneIDString)","domain":"example.com"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webCookiesClear(
            paneID: Self.paneUUID, target: nil, workspace: nil, domain: "example.com", all: false
        ))
    }

    @Test func parseWebCookiesDelete() {
        let data = jsonData("""
        {"command":"web-cookies-delete","pane_id":"\(Self.paneIDString)","name":"sessionid","domain":"example.com"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webCookiesDelete(
            paneID: Self.paneUUID, target: nil, workspace: nil, name: "sessionid", domain: "example.com"
        ))
    }

    @Test func parseWebCookiesDeleteRequiresName() {
        let data = jsonData("""
        {"command":"web-cookies-delete","pane_id":"\(Self.paneIDString)"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    // MARK: - Phase B — actuator verbs (click / type)

    @Test func parseWebClickMinimal() {
        let data = jsonData("""
        {"command":"web-click","pane_id":"\(Self.paneIDString)","selector":"text:Add to order"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webClick(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "text:Add to order",
            double: false, right: false, atX: nil, atY: nil
        ))
    }

    @Test func parseWebClickWithAllFlags() {
        let data = jsonData("""
        {"command":"web-click","pane_id":"\(Self.paneIDString)","selector":"css:.btn","double":true,"right":true,"at_x":10.5,"at_y":20}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webClick(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:.btn",
            double: true, right: true, atX: 10.5, atY: 20
        ))
    }

    @Test func parseWebClickRequiresSelector() {
        let data = jsonData("""
        {"command":"web-click","pane_id":"\(Self.paneIDString)"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebClickRequiresScope() {
        // Neither pane_id nor target -> no scope, parser rejects.
        let data = jsonData("""
        {"command":"web-click","selector":"text:Go"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebTypeMinimal() {
        let data = jsonData("""
        {"command":"web-type","pane_id":"\(Self.paneIDString)","selector":"css:input","text":"hello"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webType(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:input", text: "hello",
            submit: false, replace: true
        ))
    }

    @Test func parseWebTypeAcceptsEmptyText() {
        // text="" is meaningful: clears the field when combined with the
        // default replace=true. Parser must not reject it.
        let data = jsonData("""
        {"command":"web-type","pane_id":"\(Self.paneIDString)","selector":"css:input","text":""}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webType(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:input", text: "",
            submit: false, replace: true
        ))
    }

    @Test func parseWebTypeWithSubmitAndNoReplace() {
        let data = jsonData("""
        {"command":"web-type","pane_id":"\(Self.paneIDString)","selector":"text:Search","text":"q","submit":true,"replace":false}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webType(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "text:Search", text: "q",
            submit: true, replace: false
        ))
    }

    @Test func parseWebTypeRequiresSelectorAndText() {
        let missingSelector = jsonData("""
        {"command":"web-type","pane_id":"\(Self.paneIDString)","text":"x"}
        """)
        #expect(SocketServer.parseWireMessage(missingSelector) == nil)

        let missingText = jsonData("""
        {"command":"web-type","pane_id":"\(Self.paneIDString)","selector":"css:input"}
        """)
        #expect(SocketServer.parseWireMessage(missingText) == nil)
    }

    // MARK: - Phase C — read verbs (web-q-*)

    @Test func parseWebQText() {
        let data = jsonData("""
        {"command":"web-q-text","pane_id":"\(Self.paneIDString)","selector":"css:#p"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webQText(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:#p", maxBytes: nil
        ))
    }

    @Test func parseWebQTextWithMaxBytes() {
        let data = jsonData("""
        {"command":"web-q-text","pane_id":"\(Self.paneIDString)","selector":"css:#p","max_bytes":1024}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webQText(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:#p", maxBytes: 1024
        ))
    }

    @Test func parseWebQTextRequiresSelector() {
        let data = jsonData("""
        {"command":"web-q-text","pane_id":"\(Self.paneIDString)"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebQAttr() {
        let data = jsonData("""
        {"command":"web-q-attr","pane_id":"\(Self.paneIDString)","selector":"css:a","attribute":"href"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webQAttr(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:a", attribute: "href"
        ))
    }

    @Test func parseWebQAttrRequiresAttribute() {
        let data = jsonData("""
        {"command":"web-q-attr","pane_id":"\(Self.paneIDString)","selector":"css:a"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebQCount() {
        let data = jsonData("""
        {"command":"web-q-count","pane_id":"\(Self.paneIDString)","selector":"css:li"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webQCount(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:li"
        ))
    }

    @Test func parseWebQExists() {
        let data = jsonData("""
        {"command":"web-q-exists","pane_id":"\(Self.paneIDString)","selector":"text:Loaded"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webQExists(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "text:Loaded"
        ))
    }

    @Test func parseWebQDom() {
        let data = jsonData("""
        {"command":"web-q-dom","pane_id":"\(Self.paneIDString)","selector":"css:#a","max_bytes":4096}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webQDom(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:#a", maxBytes: 4096
        ))
    }

    // MARK: - Phase D — wait (web-wait)

    @Test func parseWebWaitSelectorOnly() {
        let data = jsonData("""
        {"command":"web-wait","pane_id":"\(Self.paneIDString)","selector":"text:Loaded","timeout_ms":5000}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webWait(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "text:Loaded", urlMatch: nil,
            forCondition: nil, timeoutMs: 5000
        ))
    }

    @Test func parseWebWaitUrlMatchOnly() {
        let data = jsonData("""
        {"command":"web-wait","pane_id":"\(Self.paneIDString)","url_match":"/checkout"}
        """)
        let result = SocketServer.parseWireMessage(data)
        // Missing timeout_ms → 0 flows through; the JS `wait` body
        // substitutes its 10000ms default.
        #expect(result?.0 == .webWait(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: nil, urlMatch: "/checkout",
            forCondition: nil, timeoutMs: 0
        ))
    }

    @Test func parseWebWaitWithForCondition() {
        let data = jsonData("""
        {"command":"web-wait","pane_id":"\(Self.paneIDString)","selector":"css:.spinner","for":"hidden","timeout_ms":3000}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webWait(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:.spinner", urlMatch: nil,
            forCondition: "hidden", timeoutMs: 3000
        ))
    }

    @Test func parseWebWaitRequiresSelectorOrUrlMatch() {
        // Neither field present → reject. (Different from a JS-side
        // validation error; this is the wire-layer guard so other
        // clients can't ship a bare wait and stall the actuator.)
        let data = jsonData("""
        {"command":"web-wait","pane_id":"\(Self.paneIDString)","timeout_ms":1000}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebWaitEmptyStringsTreatedAsAbsent() {
        let data = jsonData("""
        {"command":"web-wait","pane_id":"\(Self.paneIDString)","selector":"","url_match":""}
        """)
        // Both empty → both absent → reject.
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebWaitRejectsBothSelectorAndUrlMatch() {
        // Both fields populated → reject at the wire. The JS-side
        // default rule would silently prefer one and ignore the other,
        // which is confusing for direct socket clients.
        let data = jsonData("""
        {"command":"web-wait","pane_id":"\(Self.paneIDString)","selector":"css:#a","url_match":"/x"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    // MARK: - Phase E — select / scroll / hover / key

    @Test func parseWebSelect() {
        let data = jsonData("""
        {"command":"web-select","pane_id":"\(Self.paneIDString)","selector":"css:#s","value_or_label":"Large"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webSelect(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:#s", valueOrLabel: "Large"
        ))
    }

    @Test func parseWebSelectRequiresValueOrLabel() {
        let data = jsonData("""
        {"command":"web-select","pane_id":"\(Self.paneIDString)","selector":"css:#s"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebScrollDefaults() {
        let data = jsonData("""
        {"command":"web-scroll","pane_id":"\(Self.paneIDString)","selector":"css:#footer"}
        """)
        let result = SocketServer.parseWireMessage(data)
        // Missing block / behavior default to center / instant so the
        // JS side never receives empty strings (invalid scrollIntoView
        // options would otherwise silently fall back to "auto").
        #expect(result?.0 == .webScroll(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:#footer", block: "center", behavior: "instant"
        ))
    }

    @Test func parseWebScrollWithBlockAndSmooth() {
        let data = jsonData("""
        {"command":"web-scroll","pane_id":"\(Self.paneIDString)","selector":"css:#hero","block":"end","behavior":"smooth"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webScroll(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "css:#hero", block: "end", behavior: "smooth"
        ))
    }

    @Test func parseWebHover() {
        let data = jsonData("""
        {"command":"web-hover","pane_id":"\(Self.paneIDString)","selector":"text:More"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webHover(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            selector: "text:More"
        ))
    }

    @Test func parseWebKeyBare() {
        // No --selector → keystroke goes to document.activeElement.
        let data = jsonData("""
        {"command":"web-key","pane_id":"\(Self.paneIDString)","key":"Escape"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webKey(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            keyName: "Escape", selector: nil
        ))
    }

    @Test func parseWebKeyWithSelector() {
        let data = jsonData("""
        {"command":"web-key","pane_id":"\(Self.paneIDString)","key":"ArrowDown","selector":"css:#search"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webKey(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            keyName: "ArrowDown", selector: "css:#search"
        ))
    }

    @Test func parseWebKeyRequiresName() {
        let data = jsonData("""
        {"command":"web-key","pane_id":"\(Self.paneIDString)"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    // MARK: - Phase F — web-exec

    @Test func parseWebExec() {
        let data = jsonData("""
        {"command":"web-exec","pane_id":"\(Self.paneIDString)","script":"document.title"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webExec(
            paneID: Self.paneUUID, target: nil, workspace: nil,
            script: "document.title"
        ))
    }

    @Test func parseWebExecRequiresScript() {
        let data = jsonData("""
        {"command":"web-exec","pane_id":"\(Self.paneIDString)"}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebExecRejectsEmptyScript() {
        let data = jsonData("""
        {"command":"web-exec","pane_id":"\(Self.paneIDString)","script":""}
        """)
        #expect(SocketServer.parseWireMessage(data) == nil)
    }

    @Test func parseWebExecWithTargetAndWorkspace() {
        let data = jsonData("""
        {"command":"web-exec","target":"web","workspace":"Dev","script":"return 1"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result?.0 == .webExec(
            paneID: nil, target: "web", workspace: "Dev",
            script: "return 1"
        ))
    }
}
