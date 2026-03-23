import Foundation
@testable import Nex
import Testing

struct SocketParsingTests {
    private static let paneUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let paneIDString = "00000000-0000-0000-0000-000000000001"

    private func jsonData(_ string: String) -> Data {
        string.data(using: .utf8)!
    }

    // MARK: - parseMessage

    @Test func parseStartEvent() {
        let data = jsonData("""
        {"event":"start","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseMessage(data)
        #expect(result != nil)
        #expect(result?.0 == Self.paneUUID)
        #expect(result?.1 == .started)
    }

    @Test func parseStopEvent() {
        let data = jsonData("""
        {"event":"stop","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseMessage(data)
        #expect(result != nil)
        #expect(result?.1 == .stopped)
    }

    @Test func parseErrorEvent() {
        let data = jsonData("""
        {"event":"error","pane_id":"\(Self.paneIDString)","message":"something broke"}
        """)
        let result = SocketServer.parseMessage(data)
        #expect(result != nil)
        #expect(result?.1 == .error(message: "something broke"))
    }

    @Test func parseNotificationEvent() {
        let data = jsonData("""
        {"event":"notification","pane_id":"\(Self.paneIDString)","title":"Done","body":"Task complete"}
        """)
        let result = SocketServer.parseMessage(data)
        #expect(result != nil)
        #expect(result?.1 == .notification(title: "Done", body: "Task complete"))
    }

    @Test func parseSessionStartEvent() {
        let data = jsonData("""
        {"event":"session-start","pane_id":"\(Self.paneIDString)","session_id":"sess-abc"}
        """)
        let result = SocketServer.parseMessage(data)
        #expect(result != nil)
        #expect(result?.1 == .sessionStarted(sessionID: "sess-abc"))
    }

    @Test func parseUnknownEvent() {
        let data = jsonData("""
        {"event":"explode","pane_id":"\(Self.paneIDString)"}
        """)
        let result = SocketServer.parseMessage(data)
        #expect(result == nil)
    }

    @Test func parseInvalidJSON() {
        let data = jsonData("not json at all")
        let result = SocketServer.parseMessage(data)
        #expect(result == nil)
    }

    @Test func parseInvalidUUID() {
        let data = jsonData("""
        {"event":"start","pane_id":"not-a-uuid"}
        """)
        let result = SocketServer.parseMessage(data)
        #expect(result == nil)
    }

    // MARK: - parseData

    @Test func parseMultipleLines() {
        let input = """
        {"event":"start","pane_id":"\(Self.paneIDString)"}
        {"event":"stop","pane_id":"\(Self.paneIDString)"}
        """
        let results = SocketServer.parseData(jsonData(input))
        #expect(results.count == 2)
        #expect(results[0].1 == .started)
        #expect(results[1].1 == .stopped)
    }

    @Test func parseDataInvalidJSONSkipped() {
        let input = """
        {"event":"start","pane_id":"\(Self.paneIDString)"}
        this is garbage
        {"event":"stop","pane_id":"\(Self.paneIDString)"}
        """
        let results = SocketServer.parseData(jsonData(input))
        #expect(results.count == 2)
        #expect(results[0].1 == .started)
        #expect(results[1].1 == .stopped)
    }

    @Test func parseSessionIDDualFire() {
        let input = """
        {"event":"stop","pane_id":"\(Self.paneIDString)","session_id":"sess-xyz"}
        """
        let results = SocketServer.parseData(jsonData(input))
        // Should produce two events: .stopped + .sessionStarted
        #expect(results.count == 2)
        #expect(results[0].1 == .stopped)
        #expect(results[1].1 == .sessionStarted(sessionID: "sess-xyz"))
    }

    @Test func parseSessionStartNoDualFire() {
        let input = """
        {"event":"session-start","pane_id":"\(Self.paneIDString)","session_id":"sess-xyz"}
        """
        let results = SocketServer.parseData(jsonData(input))
        // session-start with session_id should NOT dual-fire
        #expect(results.count == 1)
        #expect(results[0].1 == .sessionStarted(sessionID: "sess-xyz"))
    }

    @Test func parseDataEmptyInput() {
        let results = SocketServer.parseData(Data())
        #expect(results.isEmpty)
    }

    @Test func parseDataBlankLines() {
        let input = "\n\n   \n"
        let results = SocketServer.parseData(jsonData(input))
        #expect(results.isEmpty)
    }
}
