#!/usr/bin/env swift
//
// nex — CLI for communicating with the Nex app over a Unix socket.
//
// Usage:
//   nex --version
//   nex event stop|start|error|notification|session-start [--message ...] [--title ...] [--body ...]
//   nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] [--target <name-or-uuid>]
//   nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>]
//   nex pane close
//   nex pane name <name>
//   nex pane send --to <name-or-uuid> <command...>
//   nex workspace create [--name "..."] [--path /dir] [--color blue]
//   nex layout cycle
//   nex layout select <name>
//   nex open <filepath>
//
// Reads NEX_PANE_ID from the environment (injected by Nex when the PTY was created).
// Falls back silently if the socket doesn't exist or NEX_PANE_ID is not set.
//
// Claude Code hook config (~/.claude/settings.json):
//   { "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "nex event stop" }] }] } }

import Foundation

let socketPath = "/tmp/nex.sock"

let nexVersion: String = {
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var size = UInt32(MAXPATHLEN)
    guard _NSGetExecutablePath(&pathBuffer, &size) == 0 else { return "dev" }
    let execURL = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath()
    let infoPlistURL = execURL
        .deletingLastPathComponent() // Helpers/
        .deletingLastPathComponent() // Contents/
        .appendingPathComponent("Info.plist")
    if let dict = NSDictionary(contentsOf: infoPlistURL),
       let version = dict["CFBundleShortVersionString"] as? String {
        return version
    }
    return "dev"
}()

// MARK: - Helpers

func printUsage() {
    fputs("""
    Usage:
      nex --version
      nex event stop|start|error|notification|session-start [--message ...] [--title ...] [--body ...]
      nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>]
      nex pane create [--path /dir] [--name <label>]
      nex pane close
      nex pane name <name>
      nex pane send --to <name-or-uuid> <command...>
      nex workspace create [--name "..."] [--path /dir] [--color blue]
      nex layout cycle
      nex layout select <name>
      nex open <filepath>
    \n
    """, stderr)
}

func parseFlag(_ name: String, from args: inout ArraySlice<String>) -> String? {
    guard let idx = args.firstIndex(of: name) else { return nil }
    let valueIdx = args.index(after: idx)
    guard valueIdx < args.endIndex else { return nil }
    let value = args[valueIdx]
    args.remove(at: valueIdx)
    args.remove(at: idx)
    return value
}

func requirePaneID() -> String {
    guard let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"] else {
        // Not running inside a Nex pane — silent exit
        exit(0)
    }
    return paneID
}

func sendJSON(_ payload: [String: String]) {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
          var jsonString = String(data: jsonData, encoding: .utf8)
    else {
        exit(1)
    }

    jsonString += "\n"

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(0) } // Silent fail — Nex not running

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { path in
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            let ptr = sunPath.baseAddress!.assumingMemoryBound(to: CChar.self)
            strncpy(ptr, path, sunPath.count - 1)
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        close(fd)
        exit(0) // Silent fail — socket not available
    }

    jsonString.withCString { ptr in
        let len = strlen(ptr)
        _ = send(fd, ptr, len, 0)
    }

    close(fd)
}

// MARK: - Subcommands

func handleEvent(_ args: inout ArraySlice<String>) {
    guard let eventType = args.popFirst() else {
        fputs("Usage: nex event stop|start|error|notification|session-start [--message ...] [--title ...] [--body ...]\n", stderr)
        exit(1)
    }

    let validEvents: Set = ["stop", "start", "error", "notification", "session-start"]
    guard validEvents.contains(eventType) else {
        fputs("Unknown event type: \(eventType)\n", stderr)
        fputs("Valid events: stop, start, error, notification, session-start\n", stderr)
        exit(1)
    }

    let paneID = requirePaneID()

    let message = parseFlag("--message", from: &args)
    var title = parseFlag("--title", from: &args)
    var body = parseFlag("--body", from: &args)

    // Read stdin JSON when piped (Claude Code passes JSON with session_id to all hooks)
    var stdinJSON: [String: Any]?
    if isatty(STDIN_FILENO) == 0 {
        if let stdinData = try? FileHandle.standardInput.availableData,
           !stdinData.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
            stdinJSON = json
        }
    }

    // Extract notification fields from stdin JSON
    if eventType == "notification", let json = stdinJSON {
        if title == nil {
            title = json["title"] as? String ?? "Claude Code"
        }
        if body == nil {
            body = json["message"] as? String
        }
    }

    // Extract session_id from stdin JSON (available in all hook events)
    var sessionID: String?
    if let json = stdinJSON {
        sessionID = json["session_id"] as? String
    }

    var payload: [String: String] = [
        "command": eventType,
        "pane_id": paneID
    ]
    if let message { payload["message"] = message }
    if let title { payload["title"] = title }
    if let body { payload["body"] = body }
    if let sessionID { payload["session_id"] = sessionID }

    sendJSON(payload)
}

func handlePane(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex pane split|create|close|name|send [...]\n", stderr)
        exit(1)
    }

    let paneID = requirePaneID()

    switch action {
    case "split":
        let direction = parseFlag("--direction", from: &args)
        let path = parseFlag("--path", from: &args)
        let name = parseFlag("--name", from: &args)
        let target = parseFlag("--target", from: &args)

        var payload: [String: String] = [
            "command": "pane-split",
            "pane_id": paneID
        ]
        if let direction { payload["direction"] = direction }
        if let path { payload["path"] = path }
        if let name { payload["name"] = name }
        if let target { payload["target"] = target }
        sendJSON(payload)

    case "create":
        let path = parseFlag("--path", from: &args)
        let name = parseFlag("--name", from: &args)
        let target = parseFlag("--target", from: &args)

        var payload: [String: String] = [
            "command": "pane-create",
            "pane_id": paneID
        ]
        if let path { payload["path"] = path }
        if let name { payload["name"] = name }
        if let target { payload["target"] = target }
        sendJSON(payload)

    case "close":
        let payload: [String: String] = [
            "command": "pane-close",
            "pane_id": paneID
        ]
        sendJSON(payload)

    case "name":
        guard let name = args.popFirst() else {
            fputs("Usage: nex pane name <name>\n", stderr)
            exit(1)
        }

        let payload: [String: String] = [
            "command": "pane-name",
            "pane_id": paneID,
            "name": name
        ]
        sendJSON(payload)

    case "send":
        guard let target = parseFlag("--to", from: &args) else {
            fputs("Usage: nex pane send --to <name-or-uuid> <command...>\n", stderr)
            exit(1)
        }

        let text = args.joined(separator: " ")
        guard !text.isEmpty else {
            fputs("Usage: nex pane send --to <name-or-uuid> <command...>\n", stderr)
            exit(1)
        }

        let payload: [String: String] = [
            "command": "pane-send",
            "pane_id": paneID,
            "target": target,
            "text": text
        ]
        sendJSON(payload)

    default:
        fputs("Unknown pane action: \(action)\n", stderr)
        fputs("Valid actions: split, create, close, name, send\n", stderr)
        exit(1)
    }
}

func handleWorkspace(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex workspace create [--name \"...\"] [--path /dir] [--color blue]\n", stderr)
        exit(1)
    }

    guard action == "create" else {
        fputs("Unknown workspace action: \(action)\n", stderr)
        fputs("Valid actions: create\n", stderr)
        exit(1)
    }

    let name = parseFlag("--name", from: &args)
    let path = parseFlag("--path", from: &args)
    let color = parseFlag("--color", from: &args)

    var payload = [
        "command": "workspace-create"
    ]
    if let name { payload["name"] = name }
    if let path { payload["path"] = path }
    if let color { payload["color"] = color }

    sendJSON(payload)
}

func handleLayout(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex layout cycle|select <name>\n", stderr)
        exit(1)
    }

    let paneID = requirePaneID()

    switch action {
    case "cycle":
        sendJSON(["command": "layout-cycle", "pane_id": paneID])

    case "select":
        guard let name = args.popFirst() else {
            fputs("Usage: nex layout select <name>\n", stderr)
            fputs("Valid layouts: even-horizontal, even-vertical, main-horizontal, main-vertical, tiled\n", stderr)
            exit(1)
        }
        sendJSON(["command": "layout-select", "pane_id": paneID, "name": name])

    default:
        fputs("Unknown layout action: \(action)\n", stderr)
        fputs("Valid actions: cycle, select\n", stderr)
        exit(1)
    }
}

func handleOpen(_ args: inout ArraySlice<String>) {
    guard let filePath = args.popFirst() else {
        fputs("Usage: nex open <filepath>\n", stderr)
        exit(1)
    }

    let absolutePath = URL(fileURLWithPath: filePath).standardizedFileURL.path

    var payload: [String: String] = [
        "command": "open",
        "path": absolutePath
    ]

    if let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"] {
        payload["pane_id"] = paneID
    }

    sendJSON(payload)
}

// MARK: - Main

var args = CommandLine.arguments.dropFirst()

guard let subcommand = args.popFirst() else {
    printUsage()
    exit(1)
}

if subcommand == "--version" || subcommand == "version" {
    print("nex \(nexVersion)")
    exit(0)
}

switch subcommand {
case "event":
    handleEvent(&args)
case "pane":
    handlePane(&args)
case "workspace":
    handleWorkspace(&args)
case "layout":
    handleLayout(&args)
case "open":
    handleOpen(&args)
default:
    fputs("Unknown command: \(subcommand)\n", stderr)
    printUsage()
    exit(1)
}
