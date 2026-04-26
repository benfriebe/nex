import ComposableArchitecture
import Foundation

/// Message received from the `nex` CLI via the Unix socket.
enum SocketMessage: Equatable {
    // Agent lifecycle
    case agentStarted(paneID: UUID)
    case agentStopped(paneID: UUID)
    case agentError(paneID: UUID, message: String)
    case notification(paneID: UUID, title: String, body: String)
    case sessionStarted(paneID: UUID, sessionID: String)
    // Pane commands
    case paneSplit(paneID: UUID, direction: PaneLayout.SplitDirection?, path: String?, name: String?, target: String?)
    case paneCreate(paneID: UUID, path: String?, name: String?, target: String?)
    /// Close a pane. In practice the CLI sends one or the other:
    /// `paneID` comes from `NEX_PANE_ID` for the no-flag form; `target`
    /// carries the `--target <name-or-uuid>` value. `workspace`
    /// (name-or-UUID) optionally narrows label resolution to a single
    /// workspace, disambiguating cross-workspace label collisions.
    /// The decoder preserves whichever fields are present (both `paneID`
    /// and `target` are allowed on the wire) and rejects a message
    /// missing both. The reducer prefers `target` when both are
    /// supplied and replies with a structured success/error payload
    /// (request/response — see `replyCommandAllowlist`).
    case paneClose(paneID: UUID?, target: String?, workspace: String?)
    case paneName(paneID: UUID, name: String)
    case paneSend(paneID: UUID, target: String, text: String)
    case paneMove(paneID: UUID, direction: PaneLayout.Direction)
    case paneMoveToWorkspace(paneID: UUID, toWorkspace: String, create: Bool)
    /// Workspace commands
    case workspaceCreate(name: String?, path: String?, color: WorkspaceColor?, group: String?)
    case workspaceMove(nameOrID: String, group: String?, index: Int?)
    /// Group commands. Icon-setting is deliberately UI-only: the
    /// curated palette + emoji picker lives in the context menu.
    case groupCreate(name: String, color: WorkspaceColor?)
    case groupRename(nameOrID: String, newName: String)
    case groupDelete(nameOrID: String, cascade: Bool)
    /// File commands. `reuse` = replace the originating pane in place
    /// (`nex open --here`) instead of splitting off it.
    case openFile(path: String, paneID: UUID?, reuse: Bool)
    /// `nex diff` — render git diff for `repoPath`, optionally scoped to `targetPath`.
    case openDiff(repoPath: String, targetPath: String?, paneID: UUID?)
    /// Layout commands
    case layoutCycle(paneID: UUID)
    case layoutSelect(paneID: UUID, name: String)
    /// Request/response — first command that returns data.
    /// `scope` may be `"current"` (require `paneID`) or `"all"` (default).
    case paneList(paneID: UUID?, workspace: String?, scope: String?)
}

/// Commands that expect a single-line JSON reply followed by EOF. For any
/// command outside this allowlist the server does not allocate a
/// `ReplyHandle` and the wire behaviour is byte-identical to the
/// pre-request/response protocol.
private let replyCommandAllowlist: Set<String> = ["pane-list", "pane-close"]

/// Unix domain socket server that listens for structured JSON messages
/// from the `nex` CLI tool. Agent hooks (Claude Code, Codex)
/// fire `nex` which sends events here.
///
/// Wire format (newline-terminated JSON):
/// ```
/// {"command":"stop","pane_id":"<uuid>"}\n
/// {"command":"error","pane_id":"<uuid>","message":"..."}\n
/// {"command":"pane-split","pane_id":"<uuid>","direction":"horizontal"}\n
/// {"command":"workspace-create","name":"Test","color":"blue"}\n
/// {"command":"layout-cycle","pane_id":"<uuid>"}\n
/// {"command":"layout-select","pane_id":"<uuid>","name":"tiled"}\n
/// ```
final class SocketServer: Sendable {
    static let socketPath = "/tmp/nex.sock"

    private let lock = NSLock()
    private nonisolated(unsafe) var socketFD: Int32 = -1
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var acceptSource: DispatchSourceRead?
    private nonisolated(unsafe) var tcpFD: Int32 = -1
    private nonisolated(unsafe) var tcpAcceptSource: DispatchSourceRead?
    private nonisolated(unsafe) var clientSources: [Int32: DispatchSourceRead] = [:]
    /// Reply-handle id → client FD. Populated only for commands in
    /// `replyCommandAllowlist`; other commands never allocate an entry.
    private nonisolated(unsafe) var replyFDs: [UInt64: Int32] = [:]
    private nonisolated(unsafe) var nextReplyID: UInt64 = 1

    /// Called on the main queue when a valid message arrives. The second
    /// argument is non-nil only for request-style commands (see
    /// `replyCommandAllowlist`); all existing fire-and-forget commands
    /// receive `nil` and the server behaves identically to before.
    nonisolated(unsafe) var onMessage: (@Sendable (SocketMessage, ReplyHandle?) -> Void)?

    /// Opaque handle the reducer uses to write a single JSON response
    /// line and close the client connection. Safe to drop on the floor —
    /// the existing EOF path still closes orphaned FDs when the CLI
    /// disconnects.
    ///
    /// Closure-based so tests can supply capture stubs without a live
    /// `SocketServer`. Marked `@unchecked Sendable` because it only
    /// needs to cross actors via the `socketServer.onMessage`
    /// indirection, and both the server-backed and test-backed
    /// implementations confine their state appropriately.
    struct ReplyHandle: @unchecked Sendable, Equatable {
        let id: UInt64
        private let sendImpl: ([String: Any]) -> Void
        private let closeImpl: () -> Void

        init(id: UInt64, send: @escaping ([String: Any]) -> Void, close: @escaping () -> Void) {
            self.id = id
            sendImpl = send
            closeImpl = close
        }

        func send(_ json: [String: Any]) {
            sendImpl(json)
        }

        func close() {
            closeImpl()
        }

        /// Identity compare on id only — the closures aren't comparable
        /// but two handles from the same server slot always share an id.
        /// Keeps the enclosing TCA Action Equatable-synthesized.
        static func == (lhs: ReplyHandle, rhs: ReplyHandle) -> Bool {
            lhs.id == rhs.id
        }
    }

    func start() {
        let alreadyRunning = lock.withLock {
            if isRunning { return true }
            isRunning = true
            return false
        }
        guard !alreadyRunning else { return }

        // Clean up stale socket file
        unlink(Self.socketPath)

        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("SocketServer: socket() failed — \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { path in
            withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
                let ptr = sunPath.baseAddress!.assumingMemoryBound(to: CChar.self)
                strncpy(ptr, path, sunPath.count - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("SocketServer: bind() failed — \(errno)")
            close(fd)
            return
        }

        guard listen(fd, 5) == 0 else {
            print("SocketServer: listen() failed — \(errno)")
            close(fd)
            return
        }

        lock.withLock { socketFD = fd }

        // Use DispatchSource to accept incoming connections
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.acceptConnection(serverFD: fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        lock.withLock { acceptSource = source }
        source.resume()
    }

    /// Start a TCP listener on 127.0.0.1 for dev containers and SSH tunnels.
    /// Returns `true` if the listener started successfully.
    @discardableResult
    func startTCP(port: Int) -> Bool {
        stopTCP()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("SocketServer: TCP socket() failed — \(errno)")
            return false
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            print("SocketServer: TCP bind() failed on port \(port) — \(errno)")
            close(fd)
            return false
        }

        guard listen(fd, 5) == 0 else {
            print("SocketServer: TCP listen() failed — \(errno)")
            close(fd)
            return false
        }

        lock.withLock { tcpFD = fd }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.acceptConnection(serverFD: fd)
        }
        // FD lifecycle managed by stopTCP/stop — no close in cancel handler
        // to avoid double-close when FD numbers are reused.
        lock.withLock { tcpAcceptSource = source }
        source.resume()
        return true
    }

    /// Stop only the TCP listener, leaving the Unix socket running.
    func stopTCP() {
        let (source, fd) = lock.withLock {
            let s = tcpAcceptSource
            let f = tcpFD
            tcpAcceptSource = nil
            tcpFD = -1
            return (s, f)
        }
        source?.cancel()
        if fd >= 0 {
            close(fd)
        }
    }

    func stop() {
        let (source, tcpSource, tcpFileDesc, clients, wasRunning) = lock.withLock {
            let s = acceptSource
            let ts = tcpAcceptSource
            let tf = tcpFD
            let c = clientSources
            let running = isRunning
            acceptSource = nil
            tcpAcceptSource = nil
            clientSources = [:]
            socketFD = -1
            tcpFD = -1
            isRunning = false
            return (s, ts, tf, c, running)
        }

        source?.cancel()
        tcpSource?.cancel()
        if tcpFileDesc >= 0 {
            close(tcpFileDesc)
        }
        for (_, clientSource) in clients {
            clientSource.cancel()
        }
        // Only remove the socket file if this instance actually created it.
        // Other SocketServer instances (e.g. SwiftUI @Entry defaults, TCA
        // testValue) must not delete the live socket on deinit.
        if wasRunning {
            unlink(Self.socketPath)
        }
    }

    private func acceptConnection(serverFD: Int32) {
        var clientAddr = sockaddr_storage()
        var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else { return }

        // Suppress SIGPIPE on this FD so a `reply(id:json:)` write to a
        // client that vanished between parse and reducer (e.g. the
        // user ^C'd `nex pane list`) fails with EPIPE instead of
        // terminating the whole app. macOS has no MSG_NOSIGNAL flag;
        // SO_NOSIGPIPE on the socket is the equivalent.
        var noSigPipe: Int32 = 1
        setsockopt(
            clientFD, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
        )

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .global(qos: .utility))
        clientSource.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        clientSource.setCancelHandler { [weak self] in
            close(clientFD)
            guard let self else { return }
            lock.lock()
            clientSources.removeValue(forKey: clientFD)
            // Drop any outstanding reply handles pointing at this FD.
            // The handle's `send()` / `close()` become no-ops.
            for (id, fd) in replyFDs where fd == clientFD {
                replyFDs.removeValue(forKey: id)
            }
            lock.unlock()
        }
        lock.withLock { clientSources[clientFD] = clientSource }
        clientSource.resume()
    }

    private func readFromClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)

        if bytesRead <= 0 {
            // EOF or error — clean up this client
            let source = lock.withLock { clientSources[fd] }
            source?.cancel()
            return
        }

        let data = Data(buffer[..<bytesRead])
        processData(data, clientFD: fd)
    }

    private func processData(_ data: Data, clientFD: Int32) {
        let parsed = Self.parseMessagesWithCommands(data)
        guard !parsed.isEmpty else { return }

        let callback = lock.withLock { onMessage }
        // Allocate reply handles on the read queue (before main async) so
        // the id → FD mapping is guaranteed visible when the reducer
        // runs. Non-reply commands carry a nil handle.
        var dispatch: [(SocketMessage, ReplyHandle?)] = []
        dispatch.reserveCapacity(parsed.count)
        for (message, command) in parsed {
            if replyCommandAllowlist.contains(command) {
                let handle = allocateReplyHandle(for: clientFD)
                dispatch.append((message, handle))
            } else {
                dispatch.append((message, nil))
            }
        }

        DispatchQueue.main.async {
            for (message, handle) in dispatch {
                callback?(message, handle)
            }
        }
    }

    private func allocateReplyHandle(for clientFD: Int32) -> ReplyHandle {
        let id: UInt64 = lock.withLock {
            let next = nextReplyID
            nextReplyID &+= 1
            replyFDs[next] = clientFD
            return next
        }
        return ReplyHandle(
            id: id,
            send: { [weak self] json in self?.reply(id: id, json: json) },
            close: { [weak self] in self?.closeReply(id: id) }
        )
    }

    /// Write a single JSON line to the reply-handle's FD. Silently
    /// no-ops if the handle is stale (client disconnected, server
    /// stopped). Called from the reducer on the main actor.
    fileprivate func reply(id: UInt64, json: [String: Any]) {
        let fd = lock.withLock { replyFDs[id] ?? -1 }
        guard fd >= 0 else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        text.withCString { ptr in
            let len = strlen(ptr)
            var remaining = len
            var p = ptr
            while remaining > 0 {
                let n = send(fd, p, remaining, 0)
                if n <= 0 { return }
                remaining -= n
                p = p.advanced(by: n)
            }
        }
    }

    /// Close the reply channel by cancelling the client's dispatch
    /// source (which closes the FD). The cancel handler also removes
    /// any lingering entries from `replyFDs`.
    fileprivate func closeReply(id: UInt64) {
        let (source, fd): (DispatchSourceRead?, Int32) = lock.withLock {
            guard let fd = replyFDs.removeValue(forKey: id) else { return (nil, -1) }
            return (clientSources[fd], fd)
        }
        guard fd >= 0 else { return }
        source?.cancel()
    }

    // MARK: - Static Parsing (testable)

    struct WireMessage: Decodable {
        let command: String
        var paneID: String?
        var message: String?
        var title: String?
        var body: String?
        var sessionID: String?
        var direction: String?
        var path: String?
        var name: String?
        var color: String?
        var target: String?
        var text: String?
        // Group/workspace-management fields
        var newName: String?
        var cascade: Bool?
        var index: Int?
        var group: String?
        // Request/response — `pane-list` filters
        var workspace: String?
        var scope: String?
        /// `nex open --here` → replace originating pane in place.
        var reuse: Bool?
        /// `nex diff` — repo root and optional file/directory scope.
        var repoPath: String?
        var targetPath: String?

        enum CodingKeys: String, CodingKey {
            case command
            case paneID = "pane_id"
            case message, title, body
            case sessionID = "session_id"
            case direction, path, name, color, target, text
            case newName = "new_name"
            case cascade, index, group
            case workspace, scope
            case reuse
            case repoPath = "repo_path"
            case targetPath = "target_path"
        }
    }

    /// Parse a single JSON message into a (SocketMessage, WireMessage) tuple.
    /// Returns nil if the data is invalid or the command is unrecognized.
    static func parseWireMessage(_ data: Data) -> (SocketMessage, WireMessage)? {
        guard let wire = try? JSONDecoder().decode(WireMessage.self, from: data) else { return nil }

        // workspace-create, workspace-move, group-*, open don't
        // require pane_id.
        if wire.command == "workspace-create" {
            let color = wire.color.flatMap { WorkspaceColor(rawValue: $0) }
            return (.workspaceCreate(
                name: wire.name,
                path: wire.path,
                color: color,
                group: wire.group
            ), wire)
        }

        if wire.command == "workspace-move" {
            guard let nameOrID = wire.name, !nameOrID.isEmpty else { return nil }
            // `group` nil = top-level; empty-string is normalised to
            // nil so callers that serialise a cleared field don't
            // accidentally target a group with an empty name.
            let group = (wire.group?.isEmpty == true) ? nil : wire.group
            return (.workspaceMove(nameOrID: nameOrID, group: group, index: wire.index), wire)
        }

        if wire.command == "group-create" {
            guard let name = wire.name, !name.isEmpty else { return nil }
            let color = wire.color.flatMap { WorkspaceColor(rawValue: $0) }
            return (.groupCreate(name: name, color: color), wire)
        }

        if wire.command == "group-rename" {
            guard let nameOrID = wire.name, !nameOrID.isEmpty,
                  let newName = wire.newName, !newName.isEmpty
            else { return nil }
            return (.groupRename(nameOrID: nameOrID, newName: newName), wire)
        }

        if wire.command == "group-delete" {
            guard let nameOrID = wire.name, !nameOrID.isEmpty else { return nil }
            return (.groupDelete(nameOrID: nameOrID, cascade: wire.cascade ?? false), wire)
        }

        if wire.command == "open" {
            guard let path = wire.path, !path.isEmpty else { return nil }
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            return (.openFile(path: path, paneID: paneID, reuse: wire.reuse ?? false), wire)
        }

        if wire.command == "diff" {
            guard let repoPath = wire.repoPath, !repoPath.isEmpty else { return nil }
            let targetPath = (wire.targetPath?.isEmpty == true) ? nil : wire.targetPath
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            return (.openDiff(repoPath: repoPath, targetPath: targetPath, paneID: paneID), wire)
        }

        if wire.command == "pane-close" {
            // Accept either `pane_id` (current pane, existing behaviour)
            // or `target` (name-or-UUID, new). At least one must be
            // present; the reducer resolves `target` to a concrete pane.
            // `workspace` optionally narrows label resolution to a
            // specific workspace (useful when the same label is reused
            // across workspaces).
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            let target = (wire.target?.isEmpty == true) ? nil : wire.target
            let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
            guard paneID != nil || target != nil else { return nil }
            return (.paneClose(paneID: paneID, target: target, workspace: workspace), wire)
        }

        if wire.command == "pane-list" {
            // `pane_id` is optional — required only when `scope == "current"`,
            // which the reducer validates. Invalid UUIDs fail the request
            // downstream rather than silently dropping the message.
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
            let scope = (wire.scope?.isEmpty == true) ? nil : wire.scope
            return (.paneList(paneID: paneID, workspace: workspace, scope: scope), wire)
        }

        guard let paneIDString = wire.paneID,
              let paneID = UUID(uuidString: paneIDString) else { return nil }

        let socketMessage: SocketMessage
        switch wire.command {
        case "start":
            socketMessage = .agentStarted(paneID: paneID)
        case "stop":
            socketMessage = .agentStopped(paneID: paneID)
        case "error":
            socketMessage = .agentError(paneID: paneID, message: wire.message ?? "Unknown error")
        case "notification":
            socketMessage = .notification(
                paneID: paneID,
                title: wire.title ?? "Agent",
                body: wire.body ?? ""
            )
        case "session-start":
            guard let sessionID = wire.sessionID, !sessionID.isEmpty else { return nil }
            socketMessage = .sessionStarted(paneID: paneID, sessionID: sessionID)
        case "pane-split":
            let dir = wire.direction.flatMap { PaneLayout.SplitDirection(rawValue: $0) }
            socketMessage = .paneSplit(paneID: paneID, direction: dir, path: wire.path, name: wire.name, target: wire.target)
        case "pane-create":
            socketMessage = .paneCreate(paneID: paneID, path: wire.path, name: wire.name, target: wire.target)
        case "pane-name":
            guard let name = wire.name, !name.isEmpty else { return nil }
            socketMessage = .paneName(paneID: paneID, name: name)
        case "pane-send":
            guard let target = wire.target, !target.isEmpty,
                  let text = wire.text, !text.isEmpty else { return nil }
            socketMessage = .paneSend(paneID: paneID, target: target, text: text)
        case "pane-move":
            guard let dirString = wire.direction,
                  let dir = PaneLayout.Direction(rawValue: dirString) else { return nil }
            socketMessage = .paneMove(paneID: paneID, direction: dir)
        case "pane-move-to-workspace":
            guard let toWorkspace = wire.name, !toWorkspace.isEmpty else { return nil }
            let create = wire.text == "true"
            socketMessage = .paneMoveToWorkspace(paneID: paneID, toWorkspace: toWorkspace, create: create)
        case "layout-cycle":
            socketMessage = .layoutCycle(paneID: paneID)
        case "layout-select":
            guard let name = wire.name, !name.isEmpty else { return nil }
            socketMessage = .layoutSelect(paneID: paneID, name: name)
        default:
            return nil
        }

        return (socketMessage, wire)
    }

    /// Parse newline-separated JSON data into an array of SocketMessages.
    /// Handles the session_id dual-fire logic: if a non-session-start command
    /// includes a session_id, a .sessionStarted message is also emitted.
    static func parseMessages(_ data: Data) -> [SocketMessage] {
        parseMessagesWithCommands(data).map(\.0)
    }

    /// Like `parseMessages` but also returns the originating wire command
    /// alongside each message, so callers (the server) can decide
    /// whether to allocate a `ReplyHandle` for request-style commands.
    /// The synthesized `.sessionStarted` dual-fires carry the original
    /// command name so they never end up in the reply allowlist.
    static func parseMessagesWithCommands(_ data: Data) -> [(SocketMessage, String)] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var results: [(SocketMessage, String)] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8) else { continue }

            guard let (message, wire) = parseWireMessage(jsonData) else { continue }
            results.append((message, wire.command))

            // session_id is a common field on all Claude Code hook stdin JSON.
            // Fire .sessionStarted whenever it's present (unless the command
            // itself is already session-start, to avoid a duplicate).
            if wire.command != "session-start",
               let paneIDString = wire.paneID,
               let paneID = UUID(uuidString: paneIDString),
               let sessionID = wire.sessionID, !sessionID.isEmpty {
                results.append((.sessionStarted(paneID: paneID, sessionID: sessionID), wire.command))
            }
        }
        return results
    }

    deinit {
        stop()
    }
}

// MARK: - TCA Dependency

extension SocketServer: DependencyKey {
    static let liveValue = SocketServer()
    static let testValue = SocketServer()
}

extension DependencyValues {
    var socketServer: SocketServer {
        get { self[SocketServer.self] }
        set { self[SocketServer.self] = newValue }
    }
}

// MARK: - SwiftUI Environment

import SwiftUI

extension EnvironmentValues {
    @Entry var socketServer: SocketServer = .init()
}
