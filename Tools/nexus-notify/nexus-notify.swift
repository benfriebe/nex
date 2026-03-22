#!/usr/bin/env swift
//
// nexus-notify — Sends agent lifecycle events to the Nexus socket server.
//
// Usage:
//   nexus-notify --event stop
//   nexus-notify --event error --message "Something went wrong"
//   nexus-notify --event notification --title "Done" --body "Task completed"
//   nexus-notify --event session-start  (reads session_id from stdin JSON)
//
// Reads NEXUS_PANE_ID from the environment (injected by Nexus when the PTY was created).
// Falls back silently if the socket doesn't exist or NEXUS_PANE_ID is not set.
//
// Claude Code hook config (~/.claude/settings.json):
//   { "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "nexus-notify --event stop" }] }] } }

import Foundation

let socketPath = "/tmp/nexus.sock"

// Parse arguments
var event: String?
var message: String?
var title: String?
var body: String?

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--event":
        event = args.popFirst()
    case "--message":
        message = args.popFirst()
    case "--title":
        title = args.popFirst()
    case "--body":
        body = args.popFirst()
    default:
        break
    }
}

guard let event else {
    fputs("Usage: nexus-notify --event stop|error|notification [--message ...] [--title ...] [--body ...]\n", stderr)
    exit(1)
}

guard let paneID = ProcessInfo.processInfo.environment["NEXUS_PANE_ID"] else {
    // Not running inside a Nexus pane — silent exit
    exit(0)
}

/// Read stdin JSON when piped (Claude Code passes JSON with session_id to all hooks)
var stdinJSON: [String: Any]?
if isatty(STDIN_FILENO) == 0 {
    if let stdinData = try? FileHandle.standardInput.availableData,
       !stdinData.isEmpty,
       let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
        stdinJSON = json
    }
}

// Extract notification fields from stdin JSON
if event == "notification", let json = stdinJSON {
    if title == nil {
        title = json["title"] as? String ?? "Claude Code"
    }
    if body == nil {
        body = json["message"] as? String
    }
}

/// Extract session_id from stdin JSON (available in all hook events)
var sessionID: String?
if let json = stdinJSON {
    sessionID = json["session_id"] as? String
}

/// Build JSON payload
var payload: [String: String] = [
    "event": event,
    "pane_id": paneID
]
if let message { payload["message"] = message }
if let title { payload["title"] = title }
if let body { payload["body"] = body }
if let sessionID { payload["session_id"] = sessionID }

guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
      var jsonString = String(data: jsonData, encoding: .utf8)
else {
    exit(1)
}

jsonString += "\n"

/// Connect to Unix socket and send
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) } // Silent fail — Nexus not running

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
socketPath.withCString { path in
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
        let ptr = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
        strncpy(ptr, path, MemoryLayout.size(ofValue: addr.sun_path) - 1)
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
