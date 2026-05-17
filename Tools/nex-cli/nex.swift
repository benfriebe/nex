#!/usr/bin/env swift
//
// nex — CLI for communicating with the Nex app over a Unix socket.
//
// Usage:
//   nex --version
//   nex event stop|start|error|notification|session-start [--message ...] [--title ...] [--body ...]
//   nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] [--target <name-or-uuid>]
//   nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>]
//   nex pane close [--target <name-or-uuid>] [--workspace <name-or-uuid>]
//   nex pane name <name>
//   nex pane send [--bare] --target <name-or-uuid> [--workspace <name-or-uuid>] <command...>
//   nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>
//   nex pane move [left|right|up|down]
//   nex pane move-to-workspace --to-workspace <name-or-uuid> [--create]
//   nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]
//   nex pane capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--lines N] [--scrollback]
//   nex pane id
//   nex workspace create [--name "..."] [--path /dir] [--color blue] [--group <name>]
//   nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]
//   nex group create <name> [--color blue]
//   nex group rename <name-or-id> <new-name>
//   nex group delete <name-or-id> [--cascade]
//   nex layout cycle
//   nex layout select <name>
//   nex open [--here] <filepath>
//   nex diff [<path>]
//
// Reads NEX_PANE_ID from the environment (injected by Nex when the PTY was created).
// Reads NEX_SOCKET from the environment to select transport:
//   - Absent or empty: connects via Unix socket at /tmp/nex.sock
//   - "tcp:<host>:<port>": connects via TCP (e.g., tcp:host.docker.internal:19400)
// Falls back silently if the socket doesn't exist or NEX_PANE_ID is not set.
//
// Claude Code hook config (~/.claude/settings.json):
//   { "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "nex event stop" }] }] } }

import Foundation

let socketPath = "/tmp/nex.sock"

enum Transport {
    case unix(path: String)
    case tcp(host: String, port: UInt16)
}

let transport: Transport = {
    if let env = ProcessInfo.processInfo.environment["NEX_SOCKET"],
       env.hasPrefix("tcp:") {
        let parts = env.dropFirst(4).split(separator: ":", maxSplits: 1)
        if parts.count == 2, let port = UInt16(parts[1]) {
            return .tcp(host: String(parts[0]), port: port)
        }
    }
    return .unix(path: socketPath)
}()

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
      nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] [--target <name-or-uuid>]
      nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>]
      nex pane close [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex pane name <name>
      nex pane send [--bare] --target <name-or-uuid> [--workspace <name-or-uuid>] <command...>
      nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>
      nex pane move [left|right|up|down]
      nex pane move-to-workspace --to-workspace <name-or-uuid> [--create]
      nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]
      nex pane capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--lines N] [--scrollback]
      nex pane id
      nex workspace create [--name "..."] [--path /dir] [--color blue] [--group <name>]
      nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]
      nex group create <name> [--color blue]
      nex group rename <name-or-id> <new-name>
      nex group delete <name-or-id> [--cascade]
      nex layout cycle
      nex layout select <name>
      nex open [--here] <filepath>
      nex diff [<path>]
      nex graft start [--workspace <name-or-uuid>] [--repo <name-or-path>]
      nex graft stop [--workspace <name-or-uuid>] [--repo <name-or-path>]
      nex graft status [--json]
      nex web open <url>
      nex web url|back|forward|reload [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--hard]
      nex web capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--mode meta|text|screenshot]
    \n
    """, stderr)
}

func printPaneCloseUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane close                          # close the calling pane (requires NEX_PANE_ID)
      nex pane close --target <name-or-uuid>  # close a specific pane by label or UUID

    Options:
      --workspace <name-or-uuid>  Scope label resolution to a specific workspace.
      -h, --help                  Show this help.

    A bare positional argument is rejected on purpose — addressing a pane
    other than the caller always goes through --target so a typo cannot
    silently close the calling pane.

    Exit codes: 0 on success, non-zero on failure (unknown target, ambiguous label,
    transport failure, etc).
    \n
    """, stream)
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

/// Pop a boolean flag (presence means true). Unlike `parseFlag`, no
/// trailing value is consumed. Used for toggles like `--cascade`,
/// `--top-level`, `--reset`.
func popSwitch(_ name: String, from args: inout ArraySlice<String>) -> Bool {
    guard let idx = args.firstIndex(of: name) else { return false }
    args.remove(at: idx)
    return true
}

func requirePaneID() -> String {
    guard let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"] else {
        // Not running inside a Nex pane — silent exit
        exit(0)
    }
    return paneID
}

func sendJSON(_ payload: [String: String]) {
    sendJSONAny(payload as [String: Any])
}

/// Accepts mixed-type payloads (e.g. `cascade: true`, `index: 3`) so
/// new group / workspace-move commands can encode JSON bools and
/// numbers instead of stringified ones. The server's `WireMessage`
/// decoder requires native JSON types for `cascade: Bool?` and
/// `index: Int?`.
func sendJSONAny(_ payload: [String: Any]) {
    switch transport {
    case .unix(let path):
        sendViaUnix(path: path, payload: payload, expectsReply: false)
    case .tcp(let host, let port):
        sendViaTCP(host: host, port: port, payload: payload, expectsReply: false)
    }
}

/// Round-trip variant: send the payload, read until EOF, return the
/// accumulated response bytes. Returns `nil` if the transport fails;
/// callers must treat that differently from "empty reply" (which is
/// data.isEmpty but non-nil, signalling an older server that silently
/// dropped the request).
func sendJSONAndReadReply(_ payload: [String: Any]) -> Data? {
    switch transport {
    case .unix(let path):
        sendViaUnix(path: path, payload: payload, expectsReply: true)
    case .tcp(let host, let port):
        sendViaTCP(host: host, port: port, payload: payload, expectsReply: true)
    }
}

/// Default read timeout (seconds) for request/response commands.
/// Protects against mixed-version setups where an older Nex accepts
/// the connection but silently drops `pane-list` and never closes —
/// without this timeout the CLI would hang indefinitely. Override via
/// `NEX_REPLY_TIMEOUT` (seconds, integer) for slow TCP tunnels.
let replyTimeoutSeconds: Int = {
    if let env = ProcessInfo.processInfo.environment["NEX_REPLY_TIMEOUT"],
       let n = Int(env), n > 0 {
        return n
    }
    return 5
}()

/// Apply the reply timeout to `fd` as a receive-side socket option.
/// After this, `read()` returns -1 with `errno == EAGAIN` if nothing
/// arrives within the window.
func setReadTimeout(fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Read everything the peer sends until it closes its end. Returns
/// nil if `read()` errors before any bytes arrive; otherwise returns
/// the accumulated buffer (possibly empty when the server accepts
/// and immediately closes, or times out waiting on an older server
/// that doesn't recognise the request).
func readUntilEOF(fd: Int32) -> Data? {
    var accumulated = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            accumulated.append(buffer, count: n)
            continue
        }
        if n == 0 {
            return accumulated
        }
        // n < 0 — EINTR retry; EAGAIN/EWOULDBLOCK means the
        // SO_RCVTIMEO elapsed, which we treat the same as "no
        // reply" (empty Data) so the caller can surface a friendly
        // upgrade-required message.
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return accumulated
        }
        return accumulated.isEmpty ? nil : accumulated
    }
}

@discardableResult
func sendViaUnix(path: String, payload: [String: Any], expectsReply: Bool) -> Data? {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
          var jsonString = String(data: jsonData, encoding: .utf8)
    else {
        exit(1)
    }

    jsonString += "\n"

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        if expectsReply { return nil }
        exit(0)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { cpath in
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            let ptr = sunPath.baseAddress!.assumingMemoryBound(to: CChar.self)
            strncpy(ptr, cpath, sunPath.count - 1)
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        close(fd)
        if expectsReply { return nil }
        exit(0)
    }

    jsonString.withCString { ptr in
        let len = strlen(ptr)
        _ = send(fd, ptr, len, 0)
    }

    if expectsReply {
        setReadTimeout(fd: fd, seconds: replyTimeoutSeconds)
    }
    let reply: Data? = expectsReply ? readUntilEOF(fd: fd) : nil
    close(fd)
    return reply
}

@discardableResult
func sendViaTCP(host: String, port: UInt16, payload: [String: Any], expectsReply: Bool) -> Data? {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
          var jsonString = String(data: jsonData, encoding: .utf8)
    else {
        exit(1)
    }

    jsonString += "\n"

    // Resolve hostname (supports both names like host.docker.internal and IP literals)
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0,
          let addrInfo = result
    else {
        if expectsReply { return nil }
        exit(0)
    }
    defer { freeaddrinfo(result) }

    let fd = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, addrInfo.pointee.ai_protocol)
    guard fd >= 0 else {
        if expectsReply { return nil }
        exit(0)
    }

    let connectResult = connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)

    guard connectResult == 0 else {
        close(fd)
        if expectsReply { return nil }
        exit(0)
    }

    jsonString.withCString { ptr in
        let len = strlen(ptr)
        _ = send(fd, ptr, len, 0)
    }

    if expectsReply {
        setReadTimeout(fd: fd, seconds: replyTimeoutSeconds)
    }
    let reply: Data? = expectsReply ? readUntilEOF(fd: fd) : nil
    close(fd)
    return reply
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
        let stdinData = FileHandle.standardInput.availableData
        if !stdinData.isEmpty,
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

    // Sub-agent lifecycle events should not affect the pane indicator.
    // Claude Code sets agent_id on hooks fired by sub-agents; the root agent omits it.
    if let agentID = stdinJSON?["agent_id"] as? String, !agentID.isEmpty {
        if eventType == "stop" || eventType == "start" {
            return
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
        fputs("Usage: nex pane split|create|close|name|send|send-key|move|list|capture|id [...]\n", stderr)
        exit(1)
    }

    switch action {
    case "id":
        guard let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
              !paneID.isEmpty
        else {
            exit(1)
        }
        print(paneID)

    case "split":
        let paneID = requirePaneID()
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
        let paneID = requirePaneID()
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
        if args.contains("--help") || args.contains("-h") {
            printPaneCloseUsage(stream: stdout)
            exit(0)
        }
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        // Issue #108: a positional `<name-or-uuid>` was silently
        // dropped and the calling pane was closed instead. We
        // deliberately do NOT support positional targets — `--target`
        // is the explicit, unambiguous form. Anything left in `args`
        // after parsing the known flags is treated as user error and
        // rejected, so a typo can never silently fall through to
        // closing the caller.
        let knownFlags: Set = ["--target", "--workspace", "--help", "-h"]
        let leftover = args.filter { knownFlags.contains($0) == false }
        if let first = leftover.first {
            if first.hasPrefix("--") || first.hasPrefix("-") {
                fputs("nex pane close: unknown option \(first)\n", stderr)
            } else {
                fputs("nex pane close: unexpected argument '\(first)' — use --target <name-or-uuid> to address a specific pane\n", stderr)
            }
            printPaneCloseUsage(stream: stderr)
            exit(1)
        }
        // A bare `--workspace` without a target is meaningless and
        // would otherwise fall through to closing the calling pane —
        // the exact destructive surprise this fix exists to prevent.
        if target == nil, workspace != nil {
            fputs("nex pane close: --workspace requires --target <name-or-uuid>\n", stderr)
            printPaneCloseUsage(stream: stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "pane-close"
        ]
        if let target {
            // `--target` addresses a pane by label or UUID, so the
            // caller doesn't need to be running inside a Nex pane.
            payload["target"] = target
            // When running inside a Nex pane, also forward the origin
            // pane id so the reducer can scope label resolution to the
            // caller's own workspace (issue #92). Without this the
            // server falls back to a global lookup and silently
            // routes to a label match in another workspace.
            if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
               !originPaneID.isEmpty {
                payload["pane_id"] = originPaneID
            }
        } else {
            payload["pane_id"] = requirePaneID()
        }
        if let workspace {
            // `--workspace <name-or-id>` disambiguates when the same
            // label is reused across workspaces. Ignored when `target`
            // is a UUID; useful for label lookups.
            payload["workspace"] = workspace
        }

        guard let replyData = sendJSONAndReadReply(payload) else {
            fputs("nex pane close: transport failure (is Nex running?)\n", stderr)
            exit(1)
        }
        guard !replyData.isEmpty else {
            fputs("nex pane close: no response from Nex (upgrade required? need v0.20+)\n", stderr)
            exit(1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
            fputs("nex pane close: invalid JSON response\n", stderr)
            exit(1)
        }
        if let ok = json["ok"] as? Bool, ok == false {
            let msg = (json["error"] as? String) ?? "unknown error"
            fputs("nex pane close: \(msg)\n", stderr)
            exit(1)
        }
        // Success — print the resolved pane id (and label/workspace
        // when known) so humans see clear confirmation and scripts can
        // chain on the id.
        let closedID = (json["pane_id"] as? String) ?? "?"
        let label = json["label"] as? String
        let wsName = json["workspace_name"] as? String
        var line = "pane deleted: \(closedID)"
        if let label { line += " (\(label))" }
        if let wsName { line += " in workspace \(wsName)" }
        print(line)

    case "name":
        let paneID = requirePaneID()
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
        let paneID = requirePaneID()
        // `--target` matches the rest of the pane subcommands; `--to`
        // is the original flag and remains supported as a quiet alias
        // for any scripts that already use it.
        let target = parseFlag("--target", from: &args) ?? parseFlag("--to", from: &args)
        guard let target else {
            fputs("Usage: nex pane send [--bare] --target <name-or-uuid> [--workspace <name-or-uuid>] <command...>\n", stderr)
            exit(1)
        }
        // `--workspace <name-or-id>` scopes label resolution. Without
        // it, the server restricts label lookup to the sender's own
        // workspace (issue #92). Parse before joining the rest of the
        // args into the payload text.
        let workspace = parseFlag("--workspace", from: &args)
        // `--bare` (issue #98) — write text without appending Enter.
        // Pair with `pane send-key` for compositional input (e.g.
        // type a partial command then `pane send-key tab` to trigger
        // autocomplete). Default behaviour is unchanged.
        let bare = popSwitch("--bare", from: &args)

        let text = args.joined(separator: " ")
        guard !text.isEmpty else {
            fputs("Usage: nex pane send [--bare] --target <name-or-uuid> [--workspace <name-or-uuid>] <command...>\n", stderr)
            exit(1)
        }

        var payload: [String: Any] = [
            "command": "pane-send",
            "pane_id": paneID,
            "target": target,
            "text": text,
            "bare": bare
        ]
        if let workspace {
            payload["workspace"] = workspace
        }

        guard let replyData = sendJSONAndReadReply(payload) else {
            fputs("nex pane send: transport failure (is Nex running?)\n", stderr)
            exit(1)
        }
        // Empty reply = older Nex that silently dropped the request.
        // Fire-and-forget pre-#92 servers behaved this way; treat as
        // success so users on mixed-version setups aren't blocked.
        if replyData.isEmpty {
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
            fputs("nex pane send: invalid JSON response\n", stderr)
            exit(1)
        }
        if let ok = json["ok"] as? Bool, ok == false {
            let msg = (json["error"] as? String) ?? "unknown error"
            fputs("nex pane send: \(msg)\n", stderr)
            exit(1)
        }
        // Success ack — print the resolved pane id (and label/workspace
        // when known) so humans see clear confirmation and scripts can
        // chain on the id. Mirrors the `pane close` ack format.
        let resolvedID = (json["pane_id"] as? String) ?? "?"
        let resolvedLabel = json["label"] as? String
        let resolvedWS = json["workspace_name"] as? String
        let bareAck = (json["bare"] as? Bool) ?? false
        var ack = bareAck ? "sent (bare) to \(resolvedID)" : "sent to \(resolvedID)"
        if let resolvedLabel { ack += " (\(resolvedLabel))" }
        if let resolvedWS { ack += " in workspace \(resolvedWS)" }
        print(ack)

    case "send-key":
        // Issue #98: bracketed-paste mode in TUI targets sometimes
        // captures the trailing newline from `pane send` inside the
        // paste envelope, so the message lands as `[Pasted text]` and
        // never submits. `pane send-key` delivers an explicit
        // keystroke (Enter, Tab, Escape, ...) outside any paste
        // envelope, so the workflow becomes:
        //   nex pane send     --target X "text"
        //   nex pane send-key --target X enter
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        guard let target, !target.isEmpty else {
            fputs("Usage: nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>\n", stderr)
            exit(1)
        }
        // Reject unknown options before accepting the positional key,
        // mirroring `pane close`'s defensive parsing (issue #108) so a
        // typo can't silently fall through to a key send. parseFlag
        // has already consumed --target/--workspace and their values,
        // so anything still in args that starts with `-` is an
        // unknown option and the rest must be the single positional
        // key token.
        let keyTokens = args.filter { !$0.hasPrefix("-") }
        let unknownOpts = args.filter { $0.hasPrefix("-") }
        if let first = unknownOpts.first {
            fputs("nex pane send-key: unknown option \(first)\n", stderr)
            fputs("Usage: nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>\n", stderr)
            exit(1)
        }
        guard let key = keyTokens.first, keyTokens.count == 1 else {
            fputs("Usage: nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>\n", stderr)
            fputs("       <key> is one of: enter, return, tab, escape, esc, space, backspace, up, down, left, right, ctrl-c\n", stderr)
            exit(1)
        }

        // pane_id is the caller's NEX_PANE_ID when set — it scopes
        // label resolution to the caller's workspace by default
        // (issue #92). When called from outside a Nex pane (e.g. an
        // external script), the request still works as long as the
        // target resolves unambiguously or `--workspace` is supplied.
        var payload: [String: Any] = [
            "command": "pane-send-key",
            "target": target,
            "key": key
        ]
        if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
           !originPaneID.isEmpty {
            payload["pane_id"] = originPaneID
        }
        if let workspace, !workspace.isEmpty {
            payload["workspace"] = workspace
        }

        guard let replyData = sendJSONAndReadReply(payload) else {
            fputs("nex pane send-key: transport failure (is Nex running?)\n", stderr)
            exit(1)
        }
        // Empty reply = older Nex that doesn't know the command. Treat
        // as failure — unlike `pane send`, there's no pre-#98 fallback
        // path that produced the right behaviour silently.
        if replyData.isEmpty {
            fputs("nex pane send-key: empty reply (Nex version may not support this command)\n", stderr)
            exit(1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
            fputs("nex pane send-key: invalid JSON response\n", stderr)
            exit(1)
        }
        if let ok = json["ok"] as? Bool, ok == false {
            let msg = (json["error"] as? String) ?? "unknown error"
            fputs("nex pane send-key: \(msg)\n", stderr)
            exit(1)
        }
        let resolvedID = (json["pane_id"] as? String) ?? "?"
        let resolvedLabel = json["label"] as? String
        let resolvedWS = json["workspace_name"] as? String
        let resolvedKey = (json["key"] as? String) ?? key.lowercased()
        var ack = "sent \(resolvedKey) to \(resolvedID)"
        if let resolvedLabel { ack += " (\(resolvedLabel))" }
        if let resolvedWS { ack += " in workspace \(resolvedWS)" }
        print(ack)

    case "move":
        let paneID = requirePaneID()
        guard let direction = args.popFirst() else {
            fputs("Usage: nex pane move [left|right|up|down]\n", stderr)
            exit(1)
        }
        let validDirections: Set = ["left", "right", "up", "down"]
        guard validDirections.contains(direction) else {
            fputs("Invalid direction: \(direction)\n", stderr)
            fputs("Valid directions: left, right, up, down\n", stderr)
            exit(1)
        }
        sendJSON([
            "command": "pane-move",
            "pane_id": paneID,
            "direction": direction
        ])

    case "move-to-workspace":
        let paneID = requirePaneID()
        guard let toWorkspace = parseFlag("--to-workspace", from: &args) else {
            fputs("Usage: nex pane move-to-workspace --to-workspace <name-or-uuid> [--create]\n", stderr)
            exit(1)
        }
        var payload: [String: String] = [
            "command": "pane-move-to-workspace",
            "pane_id": paneID,
            "name": toWorkspace
        ]
        if let idx = args.firstIndex(of: "--create") {
            payload["text"] = "true"
            args.remove(at: idx)
        }
        sendJSON(payload)

    case "list":
        handlePaneList(&args)

    case "capture":
        handlePaneCapture(&args)

    default:
        fputs("Unknown pane action: \(action)\n", stderr)
        fputs("Valid actions: split, create, close, name, send, send-key, move, move-to-workspace, list, capture, id\n", stderr)
        exit(1)
    }
}

// MARK: - web (top-level subcommand)

func printWebUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex web open <url>
      nex web url      [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web back     [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web forward  [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web reload   [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--hard]
      nex web capture  [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--mode meta|text|screenshot]

    When invoked from outside a Nex pane, --target must be a UUID
    or --workspace <name-or-id> must be passed (label resolution
    needs an explicit workspace scope).
    \n
    """, stream)
}

/// Apply the `--target` / `--workspace` / `NEX_PANE_ID` rule (issue
/// #92): label targets need either an origin pane or an explicit
/// workspace; UUID targets always resolve globally. Returns the
/// payload extension; exits non-zero on rule violation.
private func attachWebTargetScope(
    _ payload: inout [String: Any],
    target: String?,
    workspace: String?,
    command: String
) {
    if let target {
        payload["target"] = target
    }
    if let workspace {
        payload["workspace"] = workspace
    }
    if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
       !originPaneID.isEmpty {
        payload["pane_id"] = originPaneID
    }

    // Enforce the external-caller workspace rule before sending so
    // failures surface as a clear CLI message rather than a server
    // error round-trip.
    let isUUIDTarget = target.flatMap { UUID(uuidString: $0) } != nil
    let hasOrigin = ProcessInfo.processInfo.environment["NEX_PANE_ID"]?.isEmpty == false
    if let target, !isUUIDTarget, workspace == nil, !hasOrigin {
        fputs("nex web \(command): --target by label requires --workspace <name-or-id> when called outside a Nex pane\n", stderr)
        exit(1)
    }
    // No target and no origin pane = no resolvable pane.
    if target == nil, !hasOrigin {
        fputs("nex web \(command): no --target supplied and NEX_PANE_ID is not set\n", stderr)
        exit(1)
    }
}

func handleWeb(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        printWebUsage(stream: stderr)
        exit(1)
    }

    if action == "-h" || action == "--help" || action == "help" {
        printWebUsage(stream: stdout)
        exit(0)
    }

    switch action {
    case "open":
        guard let url = args.popFirst(), !url.isEmpty else {
            fputs("Usage: nex web open <url>\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-open",
            "url": url
        ]
        if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
           !originPaneID.isEmpty {
            payload["pane_id"] = originPaneID
        }
        sendWebReplyAndPrintBasic(payload, command: "open")

    case "url":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        var payload: [String: Any] = ["command": "web-url"]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "url")
        sendWebReplyAndPrintURL(payload)

    case "back":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        var payload: [String: Any] = ["command": "web-back"]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "back")
        sendWebReplyAndPrintBasic(payload, command: "back")

    case "forward":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        var payload: [String: Any] = ["command": "web-forward"]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "forward")
        sendWebReplyAndPrintBasic(payload, command: "forward")

    case "reload":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let hard = popSwitch("--hard", from: &args)
        var payload: [String: Any] = ["command": "web-reload"]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "reload")
        if hard { payload["hard"] = true }
        sendWebReplyAndPrintBasic(payload, command: "reload")

    case "capture":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let mode = parseFlag("--mode", from: &args) ?? "meta"
        let allowed: Set = ["meta", "text", "screenshot"]
        guard allowed.contains(mode) else {
            fputs("nex web capture: unknown --mode '\(mode)' (allowed: meta, text, screenshot)\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-capture",
            "mode": mode
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "capture")
        sendWebReplyAndPrintCapture(payload)

    default:
        fputs("Unknown web action: \(action)\n", stderr)
        printWebUsage(stream: stderr)
        exit(1)
    }
}

private func sendWebReplyAndPrintBasic(_ payload: [String: Any], command: String) {
    guard let data = sendJSONAndReadReply(payload) else {
        fputs("nex web \(command): transport failure (is Nex running?)\n", stderr)
        exit(1)
    }
    guard !data.isEmpty else {
        fputs("nex web \(command): no response from Nex (upgrade required?)\n", stderr)
        exit(1)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("nex web \(command): invalid JSON response\n", stderr)
        exit(1)
    }
    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        fputs("nex web \(command): \(msg)\n", stderr)
        exit(1)
    }
    let paneID = (json["pane_id"] as? String) ?? "?"
    let extra = if let url = json["url"] as? String { " (\(url))" } else { "" }
    print("\(command) ok: \(paneID)\(extra)")
}

private func sendWebReplyAndPrintURL(_ payload: [String: Any]) {
    guard let data = sendJSONAndReadReply(payload) else {
        fputs("nex web url: transport failure (is Nex running?)\n", stderr)
        exit(1)
    }
    guard !data.isEmpty else {
        fputs("nex web url: no response from Nex (upgrade required?)\n", stderr)
        exit(1)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("nex web url: invalid JSON response\n", stderr)
        exit(1)
    }
    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        fputs("nex web url: \(msg)\n", stderr)
        exit(1)
    }
    let url = (json["url"] as? String) ?? ""
    let title = (json["title"] as? String) ?? ""
    if !title.isEmpty {
        print("\(url)\t\(title)")
    } else {
        print(url)
    }
}

private func sendWebReplyAndPrintCapture(_ payload: [String: Any]) {
    guard let data = sendJSONAndReadReply(payload) else {
        fputs("nex web capture: transport failure (is Nex running?)\n", stderr)
        exit(1)
    }
    guard !data.isEmpty else {
        fputs("nex web capture: no response from Nex (upgrade required?)\n", stderr)
        exit(1)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("nex web capture: invalid JSON response\n", stderr)
        exit(1)
    }
    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        fputs("nex web capture: \(msg)\n", stderr)
        exit(1)
    }
    let mode = (json["mode"] as? String) ?? "meta"
    switch mode {
    case "text":
        if let text = json["text"] as? String { print(text) }
    case "screenshot":
        if let path = json["path"] as? String {
            print(path)
        } else if let b64 = json["png_base64"] as? String {
            // Inline: print to stdout — the caller can pipe to `base64 -D > out.png`.
            print(b64)
        }
    default:
        // meta — print URL + title + byte_count
        let url = (json["url"] as? String) ?? ""
        let title = (json["title"] as? String) ?? ""
        print("url:    \(url)")
        if !title.isEmpty {
            print("title:  \(title)")
        }
        if let bytes = json["byte_count"] as? Int {
            print("bytes:  \(bytes)")
        }
    }
}

// MARK: - pane list

func handlePaneList(_ args: inout ArraySlice<String>) {
    let workspace = parseFlag("--workspace", from: &args)
    let currentOnly = popSwitch("--current", from: &args)
    let asJSON = popSwitch("--json", from: &args)
    let noHeader = popSwitch("--no-header", from: &args)

    if workspace != nil, currentOnly {
        fputs("pane list: --workspace and --current are mutually exclusive\n", stderr)
        exit(1)
    }

    var payload: [String: Any] = [
        "command": "pane-list"
    ]
    if let workspace {
        payload["workspace"] = workspace
    }
    if currentOnly {
        // `--current` requires NEX_PANE_ID. Matches the existing
        // silent-exit behaviour of other pane commands when not in a
        // Nex pane.
        payload["pane_id"] = requirePaneID()
        payload["scope"] = "current"
    }

    guard let replyData = sendJSONAndReadReply(payload) else {
        fputs("nex pane list: transport failure (is Nex running?)\n", stderr)
        exit(1)
    }

    guard !replyData.isEmpty else {
        fputs("nex pane list: no response from Nex (upgrade required? need v0.20+)\n", stderr)
        exit(1)
    }

    guard let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
        fputs("nex pane list: invalid JSON response\n", stderr)
        exit(1)
    }

    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        fputs("nex pane list: \(msg)\n", stderr)
        exit(1)
    }

    let panes = (json["panes"] as? [[String: Any]]) ?? []

    if asJSON {
        // Print the panes array unwrapped — consumers get a stable
        // shape, and exit code still encodes success.
        if let out = try? JSONSerialization.data(withJSONObject: panes, options: [.sortedKeys]),
           let s = String(data: out, encoding: .utf8) {
            print(s)
        }
        return
    }

    printPaneTable(panes, noHeader: noHeader)
}

/// Render the `pane-list` response as a fixed-width table. Columns:
/// ID (truncated UUID), LABEL, WORKSPACE, STATUS, CWD.
///
/// We truncate the UUID (first 8 + last 4) for readability; the
/// `--json` output keeps the full UUID for scripts. Other fields
/// print at their natural width with a 2-space gutter.
func printPaneTable(_ panes: [[String: Any]], noHeader: Bool) {
    struct Row {
        let id: String
        let label: String
        let workspace: String
        let status: String
        let cwd: String
    }

    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""

    let rows: [Row] = panes.map { entry in
        let fullID = (entry["id"] as? String) ?? ""
        let shortID: String
        if fullID.count >= 12 {
            let prefix = fullID.prefix(8)
            let suffix = fullID.suffix(4)
            shortID = "\(prefix)…\(suffix)"
        } else {
            shortID = fullID
        }
        var cwd = (entry["working_directory"] as? String) ?? ""
        if !home.isEmpty, cwd.hasPrefix(home) {
            cwd = "~" + cwd.dropFirst(home.count)
        }
        return Row(
            id: shortID,
            label: (entry["label"] as? String) ?? "-",
            workspace: (entry["workspace_name"] as? String) ?? "",
            status: (entry["status"] as? String) ?? "",
            cwd: cwd
        )
    }

    // Compute column widths from data (and headers if shown).
    var widths = [0, 0, 0, 0, 0]
    let headers = ["ID", "LABEL", "WORKSPACE", "STATUS", "CWD"]
    if !noHeader {
        for (i, h) in headers.enumerated() {
            widths[i] = max(widths[i], h.count)
        }
    }
    for r in rows {
        widths[0] = max(widths[0], r.id.count)
        widths[1] = max(widths[1], r.label.count)
        widths[2] = max(widths[2], r.workspace.count)
        widths[3] = max(widths[3], r.status.count)
        widths[4] = max(widths[4], r.cwd.count)
    }

    func pad(_ s: String, _ w: Int) -> String {
        if s.count >= w { return s }
        return s + String(repeating: " ", count: w - s.count)
    }

    if !noHeader {
        // Last column is not padded so trailing whitespace is avoided.
        print("\(pad(headers[0], widths[0]))  \(pad(headers[1], widths[1]))  \(pad(headers[2], widths[2]))  \(pad(headers[3], widths[3]))  \(headers[4])")
    }
    for r in rows {
        print("\(pad(r.id, widths[0]))  \(pad(r.label, widths[1]))  \(pad(r.workspace, widths[2]))  \(pad(r.status, widths[3]))  \(r.cwd)")
    }
}

// MARK: - pane capture

func handlePaneCapture(_ args: inout ArraySlice<String>) {
    let target = parseFlag("--target", from: &args)
    let workspace = parseFlag("--workspace", from: &args)
    let linesArg = parseFlag("--lines", from: &args)
    let scrollback = popSwitch("--scrollback", from: &args)

    var lines: Int?
    if let linesArg {
        guard let parsed = Int(linesArg), parsed > 0 else {
            fputs("nex pane capture: --lines must be a positive integer\n", stderr)
            exit(1)
        }
        lines = parsed
    }

    var payload: [String: Any] = [
        "command": "pane-capture"
    ]
    if let target {
        payload["target"] = target
        // Include the origin pane id when running inside a Nex pane so
        // the reducer can prefer the caller's workspace for label
        // resolution (breaks duplicate-label collisions across
        // workspaces). Outside a Nex pane this is just absent.
        if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
           !originPaneID.isEmpty {
            payload["pane_id"] = originPaneID
        }
    } else {
        payload["pane_id"] = requirePaneID()
    }
    if let workspace {
        payload["workspace"] = workspace
    }
    if let lines {
        payload["lines"] = lines
    }
    if scrollback {
        payload["scrollback"] = true
    }

    guard let replyData = sendJSONAndReadReply(payload) else {
        fputs("nex pane capture: transport failure (is Nex running?)\n", stderr)
        exit(1)
    }
    guard !replyData.isEmpty else {
        fputs("nex pane capture: no response from Nex (upgrade required? need v0.21+)\n", stderr)
        exit(1)
    }
    guard let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
        fputs("nex pane capture: invalid JSON response\n", stderr)
        exit(1)
    }
    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        fputs("nex pane capture: \(msg)\n", stderr)
        exit(1)
    }

    let text = (json["text"] as? String) ?? ""
    // Write raw text without an added trailing newline — the captured
    // output usually already ends in one. Use FileHandle so binary-safe.
    if let data = text.data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func handleWorkspace(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex workspace create|move [...]\n", stderr)
        exit(1)
    }

    switch action {
    case "create":
        let name = parseFlag("--name", from: &args)
        let path = parseFlag("--path", from: &args)
        let color = parseFlag("--color", from: &args)
        let group = parseFlag("--group", from: &args)

        var payload = [
            "command": "workspace-create"
        ]
        if let name { payload["name"] = name }
        if let path { payload["path"] = path }
        if let color { payload["color"] = color }
        if let group { payload["group"] = group }

        sendJSON(payload)

    case "move":
        guard let nameOrID = args.popFirst() else {
            fputs("Usage: nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]\n", stderr)
            exit(1)
        }
        let group = parseFlag("--group", from: &args)
        let topLevel = popSwitch("--top-level", from: &args)
        let indexRaw = parseFlag("--index", from: &args)

        if group == nil, !topLevel {
            fputs("workspace move requires --group <name> or --top-level\n", stderr)
            exit(1)
        }
        if group != nil, topLevel {
            fputs("workspace move can't take both --group and --top-level\n", stderr)
            exit(1)
        }

        var payload: [String: Any] = [
            "command": "workspace-move",
            "name": nameOrID
        ]
        if let group { payload["group"] = group }
        // `--top-level` means omit `group` entirely so the server
        // resolves nil → detach from current parent.
        if let indexRaw {
            guard let index = Int(indexRaw) else {
                fputs("--index must be an integer\n", stderr)
                exit(1)
            }
            payload["index"] = index
        }

        sendJSONAny(payload)

    default:
        fputs("Unknown workspace action: \(action)\n", stderr)
        fputs("Valid actions: create, move\n", stderr)
        exit(1)
    }
}

func handleGroup(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex group create|rename|delete [...]\n", stderr)
        exit(1)
    }

    switch action {
    case "create":
        guard let name = args.popFirst() else {
            fputs("Usage: nex group create <name> [--color blue]\n", stderr)
            exit(1)
        }
        let color = parseFlag("--color", from: &args)

        var payload: [String: String] = [
            "command": "group-create",
            "name": name
        ]
        if let color { payload["color"] = color }
        sendJSON(payload)

    case "rename":
        guard let nameOrID = args.popFirst(), let newName = args.popFirst() else {
            fputs("Usage: nex group rename <name-or-id> <new-name>\n", stderr)
            exit(1)
        }
        sendJSON([
            "command": "group-rename",
            "name": nameOrID,
            "new_name": newName
        ])

    case "delete":
        guard let nameOrID = args.popFirst() else {
            fputs("Usage: nex group delete <name-or-id> [--cascade]\n", stderr)
            exit(1)
        }
        let cascade = popSwitch("--cascade", from: &args)
        sendJSONAny([
            "command": "group-delete",
            "name": nameOrID,
            "cascade": cascade
        ])

    default:
        fputs("Unknown group action: \(action)\n", stderr)
        fputs("Valid actions: create, rename, delete\n", stderr)
        exit(1)
    }
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
    let reuse = popSwitch("--here", from: &args)
    guard let filePath = args.popFirst() else {
        fputs("Usage: nex open [--here] <filepath>\n", stderr)
        exit(1)
    }

    let absolutePath = URL(fileURLWithPath: filePath).standardizedFileURL.path

    var payload: [String: Any] = [
        "command": "open",
        "path": absolutePath
    ]

    if let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"] {
        payload["pane_id"] = paneID
    }

    if reuse {
        payload["reuse"] = true
    }

    sendJSONAny(payload)
}

func handleDiff(_ args: inout ArraySlice<String>) {
    let cwd = FileManager.default.currentDirectoryPath
    var payload: [String: Any] = [
        "command": "diff",
        "repo_path": cwd
    ]

    if let target = args.popFirst() {
        let absolute = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: cwd))
            .standardizedFileURL
            .path
        payload["target_path"] = absolute
    }

    if let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"] {
        payload["pane_id"] = paneID
    }

    sendJSONAny(payload)
}

// MARK: - graft

func handleGraft(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex graft start|stop|status\n", stderr)
        exit(1)
    }

    switch action {
    case "start":
        handleGraftCommand(command: "graft-start", args: &args)
    case "stop":
        handleGraftCommand(command: "graft-stop", args: &args)
    case "status":
        handleGraftStatus(args: &args)
    case "-h", "--help", "help":
        fputs("""
        Usage:
          nex graft start [--workspace <name-or-uuid>] [--repo <name-or-path>]
          nex graft stop  [--workspace <name-or-uuid>] [--repo <name-or-path>]
          nex graft status [--json]

        With no filters, start/stop default to the caller's workspace
        (requires NEX_PANE_ID). Use --repo to target a single
        association; use --workspace to scope across every association
        in another workspace.
        \n
        """, stderr)
    default:
        fputs("Unknown graft action: \(action)\n", stderr)
        fputs("Valid actions: start, stop, status\n", stderr)
        exit(1)
    }
}

private func handleGraftCommand(command: String, args: inout ArraySlice<String>) {
    let workspace = parseFlag("--workspace", from: &args)
    let repo = parseFlag("--repo", from: &args)

    var payload: [String: Any] = ["command": command]
    if let workspace { payload["workspace"] = workspace }
    if let repo { payload["repo"] = repo }
    if workspace == nil, repo == nil,
       let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"] {
        payload["pane_id"] = paneID
    }

    guard let replyData = sendJSONAndReadReply(payload) else {
        fputs("nex \(command): transport failure (is Nex running?)\n", stderr)
        exit(1)
    }
    guard !replyData.isEmpty else {
        fputs("nex \(command): no response from Nex (upgrade required? need v0.25+)\n", stderr)
        exit(1)
    }
    guard let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
        fputs("nex \(command): invalid JSON response\n", stderr)
        exit(1)
    }

    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        fputs("nex \(command): \(msg)\n", stderr)
        exit(1)
    }

    if command == "graft-start" {
        let started = (json["started"] as? [[String: Any]]) ?? []
        if started.isEmpty {
            print("No associations started.")
        } else {
            for entry in started {
                let assoc = (entry["association_id"] as? String) ?? "-"
                let branch = (entry["branch"] as? String) ?? "-"
                let path = (entry["worktree_path"] as? String) ?? "-"
                print("started \(branch) (\(assoc)) at \(path)")
            }
        }
        if let partial = json["partial_error"] as? String {
            fputs("Partial failure: \(partial)\n", stderr)
        }
    } else {
        let stopped = (json["stopped"] as? [String]) ?? []
        if stopped.isEmpty {
            print("No active sessions in scope.")
        } else {
            for id in stopped {
                print("stopped \(id)")
            }
        }
        if let failed = json["failed"] as? [[String: Any]], !failed.isEmpty {
            for f in failed {
                let id = (f["association_id"] as? String) ?? "?"
                let err = (f["error"] as? String) ?? "?"
                fputs("failed \(id): \(err)\n", stderr)
            }
            exit(1)
        }
    }
}

private func handleGraftStatus(args: inout ArraySlice<String>) {
    let asJSON = popSwitch("--json", from: &args)
    let payload: [String: Any] = ["command": "graft-status"]
    guard let replyData = sendJSONAndReadReply(payload) else {
        fputs("nex graft status: transport failure (is Nex running?)\n", stderr)
        exit(1)
    }
    guard !replyData.isEmpty else {
        fputs("nex graft status: no response from Nex (upgrade required? need v0.25+)\n", stderr)
        exit(1)
    }
    guard let json = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
        fputs("nex graft status: invalid JSON response\n", stderr)
        exit(1)
    }
    let sessions = (json["sessions"] as? [[String: Any]]) ?? []

    if asJSON {
        if let out = try? JSONSerialization.data(withJSONObject: sessions, options: [.sortedKeys]),
           let s = String(data: out, encoding: .utf8) {
            print(s)
        }
        return
    }

    if sessions.isEmpty {
        print("No active graft sessions.")
        return
    }
    for session in sessions {
        let branch = (session["branch"] as? String) ?? "-"
        let path = (session["worktree_path"] as? String) ?? "-"
        let status = (session["status"] as? String) ?? "-"
        print("\(branch) [\(status)] \(path)")
    }
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

if subcommand == "--help" || subcommand == "-h" || subcommand == "help" {
    printUsage()
    exit(0)
}

switch subcommand {
case "event":
    handleEvent(&args)
case "pane":
    handlePane(&args)
case "workspace":
    handleWorkspace(&args)
case "group":
    handleGroup(&args)
case "layout":
    handleLayout(&args)
case "open":
    handleOpen(&args)
case "diff":
    handleDiff(&args)
case "graft":
    handleGraft(&args)
case "web":
    handleWeb(&args)
default:
    fputs("Unknown command: \(subcommand)\n", stderr)
    printUsage()
    exit(1)
}
