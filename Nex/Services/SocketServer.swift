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
    case paneClose(paneID: UUID)
    case paneName(paneID: UUID, name: String)
    case paneSend(paneID: UUID, target: String, text: String)
    case paneMove(paneID: UUID, direction: PaneLayout.Direction)
    case paneMoveToWorkspace(paneID: UUID, toWorkspace: String, create: Bool)
    /// Workspace commands
    case workspaceCreate(name: String?, path: String?, color: WorkspaceColor?)
    /// File commands
    case openFile(path: String, paneID: UUID?)
    /// Layout commands
    case layoutCycle(paneID: UUID)
    case layoutSelect(paneID: UUID, name: String)
}

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
    private nonisolated(unsafe) var clientSources: [Int32: DispatchSourceRead] = [:]

    /// Called on the main queue when a valid message arrives.
    nonisolated(unsafe) var onMessage: (@Sendable (SocketMessage) -> Void)?

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

    func stop() {
        let (source, clients, wasRunning) = lock.withLock {
            let s = acceptSource
            let c = clientSources
            let running = isRunning
            acceptSource = nil
            clientSources = [:]
            socketFD = -1
            isRunning = false
            return (s, c, running)
        }

        source?.cancel()
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
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else { return }

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .global(qos: .utility))
        clientSource.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        clientSource.setCancelHandler { [weak self] in
            close(clientFD)
            guard let self else { return }
            lock.lock()
            clientSources.removeValue(forKey: clientFD)
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
        processData(data)
    }

    private func processData(_ data: Data) {
        let messages = Self.parseMessages(data)
        guard !messages.isEmpty else { return }

        let callback = lock.withLock { onMessage }
        DispatchQueue.main.async {
            for message in messages {
                callback?(message)
            }
        }
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

        enum CodingKeys: String, CodingKey {
            case command
            case paneID = "pane_id"
            case message, title, body
            case sessionID = "session_id"
            case direction, path, name, color, target, text
        }
    }

    /// Parse a single JSON message into a (SocketMessage, WireMessage) tuple.
    /// Returns nil if the data is invalid or the command is unrecognized.
    static func parseWireMessage(_ data: Data) -> (SocketMessage, WireMessage)? {
        guard let wire = try? JSONDecoder().decode(WireMessage.self, from: data) else { return nil }

        // workspace-create and open don't require pane_id
        if wire.command == "workspace-create" {
            let color = wire.color.flatMap { WorkspaceColor(rawValue: $0) }
            return (.workspaceCreate(name: wire.name, path: wire.path, color: color), wire)
        }

        if wire.command == "open" {
            guard let path = wire.path, !path.isEmpty else { return nil }
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            return (.openFile(path: path, paneID: paneID), wire)
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
        case "pane-close":
            socketMessage = .paneClose(paneID: paneID)
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
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var results: [SocketMessage] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8) else { continue }

            guard let (message, wire) = parseWireMessage(jsonData) else { continue }
            results.append(message)

            // session_id is a common field on all Claude Code hook stdin JSON.
            // Fire .sessionStarted whenever it's present (unless the command
            // itself is already session-start, to avoid a duplicate).
            if wire.command != "session-start",
               let paneIDString = wire.paneID,
               let paneID = UUID(uuidString: paneIDString),
               let sessionID = wire.sessionID, !sessionID.isEmpty {
                results.append(.sessionStarted(paneID: paneID, sessionID: sessionID))
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
