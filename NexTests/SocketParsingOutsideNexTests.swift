import Foundation
@testable import Nex
import Testing

/// Wire-parse tests for the outside-Nex forms of `pane-send` /
/// `pane-split` / `pane-create` / `pane-name` (issue #117): these
/// commands are now parsed before the mandatory-paneID guard, so they
/// must be accepted with a `target` / `workspace` and no `pane_id`, and
/// rejected when there is no way to locate a pane/workspace.
struct SocketParsingOutsideNexTests {
    private static func parseFirst(_ json: String) -> SocketMessage? {
        SocketServer.parseWireMessage(Data(json.utf8))?.0
    }

    // MARK: pane-send

    @Test("pane-send: accepted with target and no pane_id")
    func sendNoPaneID() {
        let msg = Self.parseFirst(#"{"command":"pane-send","target":"worker","text":"echo"}"#)
        #expect(msg == .paneSend(paneID: nil, target: "worker", text: "echo", workspace: nil, bare: false))
    }

    @Test("pane-send: rejected with no target")
    func sendNoTargetRejected() {
        #expect(Self.parseFirst(#"{"command":"pane-send","text":"echo"}"#) == nil)
    }

    // MARK: pane-split

    @Test("pane-split: accepted with target and no pane_id")
    func splitTargetNoPaneID() {
        let msg = Self.parseFirst(#"{"command":"pane-split","target":"worker"}"#)
        #expect(msg == .paneSplit(paneID: nil, direction: nil, path: nil, name: nil, target: "worker", workspace: nil))
    }

    @Test("pane-split: accepted with workspace alone")
    func splitWorkspaceOnly() {
        let msg = Self.parseFirst(#"{"command":"pane-split","workspace":"beta"}"#)
        #expect(msg == .paneSplit(paneID: nil, direction: nil, path: nil, name: nil, target: nil, workspace: "beta"))
    }

    @Test("pane-split: rejected with no paneID/target/workspace")
    func splitNoAnchorRejected() {
        #expect(Self.parseFirst(#"{"command":"pane-split"}"#) == nil)
    }

    // MARK: pane-create

    @Test("pane-create: accepted with workspace alone")
    func createWorkspaceOnly() {
        let msg = Self.parseFirst(#"{"command":"pane-create","workspace":"beta"}"#)
        #expect(msg == .paneCreate(paneID: nil, path: nil, name: nil, target: nil, workspace: "beta"))
    }

    @Test("pane-create: rejected with no paneID/target/workspace")
    func createNoAnchorRejected() {
        #expect(Self.parseFirst(#"{"command":"pane-create"}"#) == nil)
    }

    // MARK: pane-name

    @Test("pane-name: accepted with target and no pane_id")
    func nameTargetNoPaneID() {
        let msg = Self.parseFirst(#"{"command":"pane-name","target":"worker","name":"renamed"}"#)
        #expect(msg == .paneName(paneID: nil, target: "worker", workspace: nil, name: "renamed"))
    }

    @Test("pane-name: rejected with no name")
    func nameNoNameRejected() {
        #expect(Self.parseFirst(#"{"command":"pane-name","target":"worker"}"#) == nil)
    }

    @Test("pane-name: rejected with neither paneID nor target")
    func nameNoAnchorRejected() {
        #expect(Self.parseFirst(#"{"command":"pane-name","name":"renamed"}"#) == nil)
    }
}
