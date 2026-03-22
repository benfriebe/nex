import ComposableArchitecture
import Foundation

/// Event received from an agent hook via the Unix socket.
enum AgentEvent: Equatable {
    case started
    case stopped
    case error(message: String)
    case notification(title: String, body: String)
    case sessionStarted(sessionID: String)
}

/// Unix domain socket server that listens for structured JSON messages
/// from the `nexus-notify` CLI tool. Agent hooks (Claude Code, Codex)
/// fire `nexus-notify` which sends events here.
///
/// Wire format (newline-terminated JSON):
/// ```
/// {"event":"stop","pane_id":"<uuid>"}\n
/// {"event":"error","pane_id":"<uuid>","message":"..."}\n
/// {"event":"notification","pane_id":"<uuid>","title":"...","body":"..."}\n
/// ```
final class SocketServer: Sendable {
    static let socketPath = "/tmp/nexus.sock"

    private let lock = NSLock()
    private nonisolated(unsafe) var socketFD: Int32 = -1
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var acceptSource: DispatchSourceRead?
    private nonisolated(unsafe) var clientSources: [Int32: DispatchSourceRead] = [:]

    /// Called on the main queue when a valid event arrives.
    nonisolated(unsafe) var onEvent: (@Sendable (UUID, AgentEvent) -> Void)?

    func start() {
        lock.withLock {
            guard !isRunning else { return }
            isRunning = true
        }

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
        let (source, clients) = lock.withLock {
            let s = acceptSource
            let c = clientSources
            acceptSource = nil
            clientSources = [:]
            socketFD = -1
            isRunning = false
            return (s, c)
        }

        source?.cancel()
        for (_, clientSource) in clients {
            clientSource.cancel()
        }
        unlink(Self.socketPath)
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
            self?.lock.withLock {
                self?.clientSources.removeValue(forKey: clientFD)
            }
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
        let events = Self.parseData(data)
        guard !events.isEmpty else { return }

        let callback = lock.withLock { onEvent }
        DispatchQueue.main.async {
            for (paneID, event) in events {
                callback?(paneID, event)
            }
        }
    }

    // MARK: - Static Parsing (testable)

    struct Message: Decodable {
        let event: String
        let paneID: String
        var message: String?
        var title: String?
        var body: String?
        var sessionID: String?

        enum CodingKeys: String, CodingKey {
            case event
            case paneID = "pane_id"
            case message
            case title
            case body
            case sessionID = "session_id"
        }
    }

    /// Parse a single JSON message into a (paneID, event, message) tuple.
    /// Returns nil if the data is invalid or the event type is unrecognized.
    static func parseMessage(_ data: Data) -> (UUID, AgentEvent, Message)? {
        guard let msg = try? JSONDecoder().decode(Message.self, from: data),
              let paneID = UUID(uuidString: msg.paneID) else { return nil }

        let agentEvent: AgentEvent
        switch msg.event {
        case "start":
            agentEvent = .started
        case "stop":
            agentEvent = .stopped
        case "error":
            agentEvent = .error(message: msg.message ?? "Unknown error")
        case "notification":
            agentEvent = .notification(
                title: msg.title ?? "Agent",
                body: msg.body ?? ""
            )
        case "session-start":
            guard let sessionID = msg.sessionID, !sessionID.isEmpty else { return nil }
            agentEvent = .sessionStarted(sessionID: sessionID)
        default:
            return nil
        }

        return (paneID, agentEvent, msg)
    }

    /// Parse newline-separated JSON data into an array of (paneID, event) tuples.
    /// Handles the session_id dual-fire logic: if a non-session-start event
    /// includes a session_id, a .sessionStarted event is also emitted.
    static func parseData(_ data: Data) -> [(UUID, AgentEvent)] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var results: [(UUID, AgentEvent)] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8) else { continue }

            guard let (paneID, event, msg) = parseMessage(jsonData) else { continue }
            results.append((paneID, event))

            // session_id is a common field on all Claude Code hook stdin JSON.
            // Fire .sessionStarted whenever it's present (unless the event
            // itself is already session-start, to avoid a duplicate).
            if msg.event != "session-start",
               let sessionID = msg.sessionID, !sessionID.isEmpty {
                results.append((paneID, .sessionStarted(sessionID: sessionID)))
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
