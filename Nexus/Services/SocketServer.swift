import ComposableArchitecture
import Foundation

/// Event received from an agent hook via the Unix socket.
enum AgentEvent: Equatable, Sendable {
    case started
    case stopped
    case error(message: String)
    case notification(title: String, body: String)
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
    nonisolated(unsafe) private var socketFD: Int32 = -1
    nonisolated(unsafe) private var isRunning = false
    nonisolated(unsafe) private var acceptSource: DispatchSourceRead?
    nonisolated(unsafe) private var clientSources: [Int32: DispatchSourceRead] = [:]

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
        guard let text = String(data: data, encoding: .utf8) else { return }

        // Split on newlines — each line is a separate JSON message
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8) else { continue }
            parseMessage(jsonData)
        }
    }

    private func parseMessage(_ data: Data) {
        struct Message: Decodable {
            let event: String
            let pane_id: String
            var message: String?
            var title: String?
            var body: String?
        }

        guard let msg = try? JSONDecoder().decode(Message.self, from: data),
              let paneID = UUID(uuidString: msg.pane_id) else { return }

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
        default:
            return
        }

        let callback = lock.withLock { onEvent }
        DispatchQueue.main.async {
            callback?(paneID, agentEvent)
        }
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

private struct SocketServerKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue = SocketServer()
}

extension EnvironmentValues {
    var socketServer: SocketServer {
        get { self[SocketServerKey.self] }
        set { self[SocketServerKey.self] = newValue }
    }
}
