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
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: .vertical, path: "/tmp"))
    }

    @Test func parsePaneSplitMinimal() {
        let data = jsonData("""
        {"command":"pane-split","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneSplit(paneID: Self.paneUUID, direction: nil, path: nil))
    }

    @Test func parsePaneCreateCommand() {
        let data = jsonData("""
        {"command":"pane-create","pane_id":"\(Self.paneIDString)","path":"/home/user"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneCreate(paneID: Self.paneUUID, path: "/home/user"))
    }

    @Test func parsePaneCloseCommand() {
        let data = jsonData("""
        {"command":"pane-close","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .paneClose(paneID: Self.paneUUID))
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
        #expect(result?.0 == .workspaceCreate(name: "Test", path: "/tmp", color: .green))
    }

    @Test func parseWorkspaceCreateMinimal() {
        let data = jsonData("""
        {"command":"workspace-create"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .workspaceCreate(name: nil, path: nil, color: nil))
    }

    @Test func parseWorkspaceCreateNoPaneIDRequired() {
        // workspace-create should work without pane_id
        let data = jsonData("""
        {"command":"workspace-create","name":"New"}
        """)
        let result = SocketServer.parseWireMessage(data)
        #expect(result != nil)
        #expect(result?.0 == .workspaceCreate(name: "New", path: nil, color: nil))
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
        #expect(results[1] == .paneSplit(paneID: Self.paneUUID, direction: .horizontal, path: nil))
        #expect(results[2] == .workspaceCreate(name: "New", path: nil, color: nil))
    }
}
