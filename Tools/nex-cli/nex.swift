#!/usr/bin/env swift
//
// nex — CLI for communicating with the Nex app over a Unix socket.
//
// Usage:
//   nex --version
//   nex event stop|start|error|notification|session-start|session-end [--message ...] [--title ...] [--body ...]
//   nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] [--target <name-or-uuid>]
//   nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>]
//   nex pane close [--target <name-or-uuid>] [--workspace <name-or-uuid>]
//   nex pane name <name>
//   nex pane resize [--target <name-or-uuid>] [--workspace <name-or-uuid>] (--ratio <0..1> | --grow [amt] | --shrink [amt])
//   nex pane send [--bare] --target <name-or-uuid> [--workspace <name-or-uuid>] <command...>
//   nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>
//   nex pane move [left|right|up|down]
//   nex pane move-to-workspace --to-workspace <name-or-uuid> [--create]
//   nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]
//   nex pane capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--lines N] [--scrollback]
//   nex pane sync (on|off|toggle|status) [--workspace <name-or-uuid>] [--json]
//   nex pane sync exclude --target <name-or-uuid> [--workspace <name-or-uuid>]
//   nex pane sync include --target <name-or-uuid> [--workspace <name-or-uuid>]
//   nex pane id
//   nex workspace list [--json] [--no-header]
//   nex workspace create [--name "..."] [--path /dir] [--color blue] [--group <name>] [--profile <name>] [--json]
//   nex workspace create --worktree <name> [--branch <name>] [--repo <path>] [--update-main]  (issue #222)
//   nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]
//   nex workspace delete <name-or-id> [<name-or-id> ...] [--force|-y] [--prune-worktree] [--json]
//   nex workspace profile <name-or-id> (<profile> | --clear)
//   nex group list [--json] [--no-header]
//   nex group create <name> [--color blue]
//   nex group rename <name-or-id> <new-name>
//   nex group delete <name-or-id> [--cascade]
//   nex layout cycle
//   nex layout select <name>
//   nex open [--here] <filepath>   (routes by file type: markdown / web pane)
//   nex md [--here] <filepath>
//   nex diff [<path>]
//   nex doctor [--json]
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

// MARK: - Transport diagnostics

//
// The CLI's transport helpers (`sendViaUnix`/`sendViaTCP`) used to
// collapse every failure into a single `nil` return, which left
// callers printing terse, unhelpful text like "transport failure
// (is Nex running?)". Issue #100 surfaced that for users hitting
// edge cases (stale socket from a crashed app, version drift, etc.)
// the generic message left no path forward.
//
// The helpers now classify each failure into a `TransportFailure`
// case and stash it in `lastTransportFailure` so `printTransportFailure`
// can produce an error line plus a concrete "Repair:" suggestion at
// each call site. `nex doctor` reads from the same enum.

enum TransportFailure {
    /// Unix socket path doesn't exist on disk. Most likely: Nex is
    /// not running, or it's running with TCP transport only.
    case unixSocketMissing(path: String)
    /// Socket file exists but connect was refused — typically a stale
    /// `/tmp/nex.sock` left behind by a previous Nex process that
    /// didn't shut down cleanly.
    case unixConnectRefused(path: String)
    /// Some other connect-time errno on the Unix path (EACCES, etc.).
    case unixConnectFailed(path: String, errno: Int32)
    /// `getaddrinfo` failed — hostname doesn't resolve.
    case tcpResolveFailed(host: String)
    /// TCP `connect()` failed — most often "Nex isn't listening on
    /// this host/port" (no `tcp-port` in `~/.config/nex/config`, or
    /// SSH tunnel down).
    case tcpConnectFailed(host: String, port: UInt16, errno: Int32)
    /// `socket(2)` itself failed — process-level (FD exhaustion, etc.).
    case createSocketFailed(errno: Int32)
    /// Connection succeeded and bytes were sent, but the peer closed
    /// (or the timeout elapsed) before any reply arrived. Usually
    /// means an older Nex that doesn't recognise the command, or the
    /// app's main-actor handler is wedged.
    case emptyReply(command: String)
}

/// Stashed by `sendViaUnix`/`sendViaTCP` on failure so the call
/// site can emit a structured error without having to plumb the
/// classification through the existing `Data?` return.
var lastTransportFailure: TransportFailure?

/// Produces (one-line error, one-line repair tip) for a failure.
/// `command` is the CLI subcommand name to make the error
/// attributable in mixed pipelines (e.g. "nex pane close: ...").
func describeTransportFailure(_ failure: TransportFailure, command: String) -> (String, String) {
    switch failure {
    case .unixSocketMissing(let path):
        (
            "\(command): cannot reach Nex — socket \(path) does not exist.",
            "Is Nex running? Launch the app, then retry. If Nex is running but using TCP, set NEX_SOCKET=tcp:<host>:<port>."
        )
    case .unixConnectRefused(let path):
        (
            "\(command): socket \(path) exists but connect was refused — Nex is not listening (likely stale socket from a previous crash).",
            "Restart Nex (panes and workspaces are persisted to ~/Library/Application Support/Nex/nex.db so they will be restored). If the file remains after Nex quits, remove it with `rm \(path)`."
        )
    case .unixConnectFailed(let path, let err):
        (
            "\(command): connect to \(path) failed (errno \(err): \(String(cString: strerror(err)))).",
            "Run `nex doctor` for full IPC diagnostics."
        )
    case .tcpResolveFailed(let host):
        (
            "\(command): cannot resolve host \"\(host)\" (from NEX_SOCKET).",
            "Check the hostname in NEX_SOCKET. From a dev container the usual value is `tcp:host.docker.internal:<port>`."
        )
    case .tcpConnectFailed(let host, let port, let err):
        (
            "\(command): TCP connect to \(host):\(port) failed (errno \(err): \(String(cString: strerror(err)))).",
            "Confirm Nex has `tcp-port = \(port)` set in ~/.config/nex/config and is running. If you're tunneling, check the SSH reverse tunnel is up."
        )
    case .createSocketFailed(let err):
        (
            "\(command): socket(2) failed (errno \(err): \(String(cString: strerror(err)))).",
            "Process-level failure — check for FD exhaustion. Run `nex doctor` for diagnostics."
        )
    case .emptyReply(let cmd):
        (
            "\(command): no response from Nex for `\(cmd)` (connected, then peer closed before replying).",
            "Likely an older Nex that doesn't recognise the command, or the app is wedged. Run `nex doctor` to confirm. Restart Nex if the doctor reports the app pid is responsive but commands hang."
        )
    }
}

/// Print the most recent transport failure to `stream` as two lines
/// (error + Repair tip). Use `fireAndForget: true` for commands that
/// historically silently exited on transport failure — the prefix
/// becomes "Warning" so scripted callers see something actionable
/// without breaking the existing exit-0 behaviour.
func printTransportFailure(
    command: String,
    to stream: UnsafeMutablePointer<FILE> = stderr,
    fireAndForget: Bool = false
) {
    guard let failure = lastTransportFailure else {
        fputs("\(command): transport failure (no diagnostic captured).\n", stream)
        return
    }
    let (line, repair) = describeTransportFailure(failure, command: command)
    let prefix = fireAndForget ? "Warning" : "Error"
    fputs("\(prefix): \(line)\nRepair: \(repair)\n", stream)
}

// MARK: - Helpers

func printUsage() {
    fputs("""
    Usage:
      nex --version
      nex event stop|start|error|notification|session-start|session-end [--message ...] [--title ...] [--body ...]
      nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] [--target <name-or-uuid>]
      nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>]
      nex pane close [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex pane name <name>
      nex pane resize [--target <name-or-uuid>] [--workspace <name-or-uuid>] (--ratio <0..1> | --grow [amt] | --shrink [amt])
      nex pane send [--bare] --target <name-or-uuid> [--workspace <name-or-uuid>] <command...>
      nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>
      nex pane move [left|right|up|down]
      nex pane move-to-workspace --to-workspace <name-or-uuid> [--create]
      nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]
      nex pane capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--lines N] [--scrollback]
      nex pane sync (on|off|toggle|status) [--workspace <name-or-uuid>] [--json]
      nex pane sync exclude --target <name-or-uuid> [--workspace <name-or-uuid>]
      nex pane sync include --target <name-or-uuid> [--workspace <name-or-uuid>]
      nex pane id
      nex workspace list [--json] [--no-header]
      nex workspace create [--name "..."] [--path /dir] [--color blue] [--group <name>] [--profile <name>] [--json]
      nex workspace create --worktree <name> [--branch <name>] [--repo <path>] [--update-main] [--group <existing>]
      nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]
      nex workspace delete <name-or-id> [<name-or-id> ...] [--force|-y] [--prune-worktree] [--json]
      nex workspace profile <name-or-id> (<profile> | --clear)
      nex group list [--json] [--no-header]
      nex group create <name> [--color blue]
      nex group rename <name-or-id> <new-name>
      nex group delete <name-or-id> [--cascade]
      nex layout cycle
      nex layout select <name>
      nex open [--here] <filepath>   # routes by file type: .md→markdown, .html/.pdf/images→web pane
      nex md [--here] <filepath>     # always opens a markdown preview pane
      nex diff [<path>]
      nex graft start [--workspace <name-or-uuid>] [--repo <name-or-path>]
      nex graft stop [--workspace <name-or-uuid>] [--repo <name-or-path>]
      nex graft status [--json]
      nex web open [--private] <url>
      nex web navigate <url> [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web url|back|forward|reload [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--hard]
      nex web capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--mode meta|text|screenshot]
      nex web private on|off [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web cookies list|clear|delete [...]
      nex web click <selector> [--target X] [--workspace Y] [--double] [--right] [--at x,y] [--json]
      nex web type <selector> <text> [--target X] [--workspace Y] [--submit] [--no-replace] [--json]
      nex web text <selector> [--target X] [--workspace Y] [--max-bytes N] [--json]
      nex web attr <selector> <attribute> [--target X] [--workspace Y] [--json]
      nex web count <selector> [--target X] [--workspace Y] [--json]
      nex web exists <selector> [--target X] [--workspace Y]   # exit 0 = yes, 1 = no
      nex web dom <selector> [--target X] [--workspace Y] [--max-bytes N] [--json]
      nex web wait (--selector <sel> | --url-match <substr-or-regex>) [--for visible|hidden|exists|count=N|text=X] [--timeout 10] [--target X] [--workspace Y] [--json]
      nex web select <selector> <value-or-label> [--target X] [--workspace Y] [--json]
      nex web scroll <selector> [--top|--bottom|--smooth] [--target X] [--workspace Y] [--json]
      nex web hover <selector> [--target X] [--workspace Y] [--json]
      nex web key <key-name> [--selector <sel>] [--target X] [--workspace Y] [--json]
      nex web exec (--file <path> | <js>) [--timeout 30] [--target X] [--workspace Y] [--json]
      nex doctor [--json]                                   # IPC health check
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

func printPaneSendUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane send [--bare] [--json] --target <name-or-uuid> [--workspace <name-or-uuid>] <command...>

    Writes text to a pane's PTY and (unless --bare) presses Enter so it runs.

    Options:
      --target <name-or-uuid>     Pane to write to. A UUID resolves globally; a
                                  label needs a workspace scope (NEX_PANE_ID or
                                  --workspace) so it can't route to the wrong pane.
      --workspace <name-or-uuid>  Scope label resolution to a specific workspace.
      --bare                      Write the text without the trailing Enter (pair
                                  with `nex pane send-key` to submit).
      --json                      Print the structured reply instead of the ack.
      -h, --help                  Show this help.

    Works from outside a Nex pane (no NEX_PANE_ID needed) when --target is a UUID
    or --workspace is given. Exit codes: 0 on success, non-zero on failure.
    \n
    """, stream)
}

func printPaneSplitUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] \\
                     [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--json]

    Splits a pane, creating a new one beside it.

    Options:
      --target <name-or-uuid>     Pane to split (UUID = global, label needs scope).
      --workspace <name-or-uuid>  Scope label resolution, or (alone) split that
                                  workspace's focused pane.
      --direction h|v             Split direction (default horizontal).
      --path /dir                 Working directory for the new pane.
      --name <label>              Label for the new pane.
      --json                      Print the structured reply (incl. the new pane id).
      -h, --help                  Show this help.

    Works from outside a Nex pane when --target or --workspace is given. The reply
    carries the new pane's id. Exit codes: 0 on success, non-zero on failure.
    \n
    """, stream)
}

func printPaneCreateUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane create [--path /dir] [--name <label>] [--workspace <name-or-uuid>] \\
                      [--target <name-or-uuid>] [--json]

    Adds a pane to a workspace (splitting the focused pane, or creating the first
    pane if the workspace is empty).

    Options:
      --workspace <name-or-uuid>  Workspace to create the pane in.
      --target <name-or-uuid>     A pane whose workspace to create in (alternative
                                  to --workspace).
      --path /dir                 Working directory for the new pane.
      --name <label>              Label for the new pane.
      --json                      Print the structured reply (incl. the new pane id).
      -h, --help                  Show this help.

    Works from outside a Nex pane when --workspace or --target is given. The reply
    carries the new pane's id. Exit codes: 0 on success, non-zero on failure.
    \n
    """, stream)
}

func printPaneNameUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane name <name>                              # rename the calling pane
      nex pane name --target <name-or-uuid> <name>      # rename a specific pane

    Options:
      --target <name-or-uuid>     Pane to rename (UUID = global, label needs scope).
      --workspace <name-or-uuid>  Scope label resolution to a specific workspace.
      --json                      Print the structured reply instead of the ack.
      -h, --help                  Show this help.

    Without --target the calling pane is renamed (requires NEX_PANE_ID). The new
    label is the sole positional argument. Exit codes: 0 on success, non-zero on
    failure.
    \n
    """, stream)
}

func printPaneResizeUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane resize --ratio <0..1>                      # resize the calling pane
      nex pane resize --target <name-or-uuid> --ratio 0.4 # resize a specific pane
      nex pane resize --target coordinator --grow         # enlarge by a step
      nex pane resize --target worker-1 --shrink 0.1      # shrink by 0.1

    Adjusts a pane's share of its immediate split against its sibling. Without
    --target the calling pane is resized (requires NEX_PANE_ID).

    Options:
      --target <name-or-uuid>     Pane to resize (UUID = global, label needs scope).
      --workspace <name-or-uuid>  Scope label resolution to a specific workspace.
      --ratio <0..1>              Set the pane's share of its split exactly.
      --grow [amount]             Enlarge the pane's share (default step 0.05).
      --shrink [amount]           Shrink the pane's share (default step 0.05).
      --json                      Print the structured reply instead of the ack.
      -h, --help                  Show this help.

    Exactly one of --ratio / --grow / --shrink is required. The effective share
    is clamped to [0.1, 0.9]. Exit codes: 0 on success, non-zero on failure.
    \n
    """, stream)
}

func printPaneCaptureUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--lines N] [--scrollback]

    Prints a pane's terminal contents to stdout. Without --target, captures the
    calling pane (requires NEX_PANE_ID).

    Options:
      --target <name-or-uuid>     Pane to read (UUID = global, label needs scope).
      --workspace <name-or-uuid>  Scope label resolution to a specific workspace.
      --lines N                   Limit to the last N lines (positive integer).
      --scrollback                Include the full scrollback, not just the viewport.
      -h, --help                  Show this help.

    The target is flag-only: a bare positional argument is rejected on purpose so
    `nex pane capture <uuid>` can't silently fall back to capturing the caller.
    Exit codes: 0 on success, non-zero on failure.
    \n
    """, stream)
}

func printPaneListUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane list [--workspace <name-or-uuid> | --current] [--json] [--no-header]

    Lists panes as a table (or a JSON array with --json).

    Options:
      --workspace <name-or-uuid>  Only panes in this workspace.
      --current                   Only the calling pane's workspace (requires NEX_PANE_ID).
      --json                      Print a JSON array instead of the table.
      --no-header                 Omit the table header row.
      -h, --help                  Show this help.

    --workspace and --current are mutually exclusive. This command takes no
    positional arguments. Exit codes: 0 on success, non-zero on failure.
    \n
    """, stream)
}

func printWorkspaceUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex workspace list|create|move|delete|profile [...]

    Subcommands:
      list      List every workspace (grouped + top-level).
      create    Create a new workspace (optionally with a git worktree).
      move      Move a workspace into a group or to the top level.
      delete    Delete one or more workspaces.
      profile   Assign or clear a workspace's profile.

    Run `nex workspace <subcommand> --help` for subcommand-specific usage.
    \n
    """, stream)
}

func printWorkspaceListUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex workspace list [--json] [--no-header]

    Lists every workspace (grouped + top-level) as a table, or a JSON array
    with --json.

    Options:
      --json         Print a JSON array instead of the table.
      --no-header    Omit the table header row.
      -h, --help     Show this help.

    This command takes no positional arguments. Exit codes: 0 on success,
    non-zero on failure.
    \n
    """, stream)
}

func printWorkspaceCreateUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex workspace create [--name "..."] [--path /dir] [--color blue] \\
                           [--group <name>] [--profile <name>] [--json]
      nex workspace create --worktree <name> [--branch <name>] [--repo <path>] \\
                           [--update-main] [--group <existing>] [--json]

    Creates a new workspace and returns its id.

    Options:
      --name <name>      Workspace name.
      --path /dir        Working directory for the workspace's first pane.
      --color <color>    Workspace color.
      --group <name>     Place the workspace in this group (created if missing,
                         unless --worktree is given, which requires an existing group).
      --profile <name>   Assign a workspace profile at creation.
      --worktree <name>  Create a git worktree and open the first pane in it.
      --branch <name>    Branch for the worktree (defaults to the worktree name).
      --repo <path>      Source repo for the worktree (defaults to the cwd).
      --update-main      Fetch and branch off origin/<default> for the worktree.
      --json             Print the structured reply (incl. the new workspace id).
      -h, --help         Show this help.

    Exit codes: 0 on success, non-zero on failure.
    \n
    """, stream)
}

func printWorkspaceMoveUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]

    Moves a workspace into a group or detaches it to the top level.

    Options:
      --group <name>   Destination group (must already exist).
      --top-level      Detach the workspace from its current group.
      --index N        Position within the destination (0-based).
      -h, --help       Show this help.

    Exactly one of --group / --top-level is required. Exit codes: 0 on success,
    non-zero on failure.
    \n
    """, stream)
}

func printWorkspaceDeleteUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex workspace delete <name-or-id> [<name-or-id> ...] [--force|-y] \\
                           [--prune-worktree] [--json]

    Deletes one or more workspaces (closing any remaining panes). Refuses to
    delete the last remaining workspace.

    Options:
      --force, -y        Delete even when a workspace still has running agents.
      --prune-worktree   Best-effort `git worktree remove` of the deleted dir.
      --json             Print a per-id JSON result array.
      -h, --help         Show this help.

    Exit codes: 0 on success, non-zero if any delete failed.
    \n
    """, stream)
}

func printWorkspaceProfileUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex workspace profile <name-or-id> (<profile> | --clear)

    Assigns or clears a workspace's profile.

    Options:
      --clear        Clear the workspace's profile assignment.
      -h, --help     Show this help.

    Exactly one of <profile> / --clear is required. Exit codes: 0 on success,
    non-zero on failure.
    \n
    """, stream)
}

/// Send a pane-mutation command (`split` / `create` / `name`) and print
/// the structured `{ok,...}` reply. Exits non-zero on transport failure,
/// empty reply (Nex too old for request/response on this command),
/// invalid JSON, or `ok:false`. With `asJSON`, prints the reply verbatim
/// (minus the `ok` flag); otherwise prints a one-line ack
/// "`<verb>: <pane_id> (<label>) in workspace <name>`".
private func sendPaneMutationReply(
    _ payload: [String: Any], command: String, asJSON: Bool, verb: String
) {
    let json = decodeReply(payload, command: "nex pane \(command)")
    if asJSON {
        var clean = json
        clean.removeValue(forKey: "ok")
        if let data = try? JSONSerialization.data(withJSONObject: clean, options: .sortedKeys),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        return
    }
    let id = (json["pane_id"] as? String) ?? "?"
    let label = json["label"] as? String
    let ws = json["workspace_name"] as? String
    var line = "\(verb): \(id)"
    if let label { line += " (\(label))" }
    if let ws { line += " in workspace \(ws)" }
    print(line)
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

/// Parse a flag whose value is *optional* (e.g. `--grow` or `--grow 0.1`).
/// Returns nil when the flag is absent. When present, consumes the next
/// token only if it parses as a Double; otherwise returns `default`. Used
/// by `pane resize`'s `--grow` / `--shrink` step flags.
func parseOptionalAmountFlag(
    _ name: String, default def: Double, from args: inout ArraySlice<String>
) -> Double? {
    guard let idx = args.firstIndex(of: name) else { return nil }
    var amount = def
    let next = args.index(after: idx)
    if next < args.endIndex, let value = Double(args[next]) {
        amount = value
        args.remove(at: next)
    }
    args.remove(at: idx)
    return amount
}

/// Split `args` at the first POSIX `--` terminator. Removes everything
/// from `--` onward from `args` and returns the trailing items as
/// positionals that flag parsers must not touch. Used by verbs whose
/// positional payload can legitimately look like a switch (e.g.
/// `nex web type css:#i -- --submit` types the literal string;
/// `nex web select css:#s -- --json` selects the option "--json").
func extractPositionalTail(from args: inout ArraySlice<String>) -> [String] {
    guard let idx = args.firstIndex(of: "--") else { return [] }
    let tail = Array(args[args.index(after: idx)...])
    args = args[..<idx]
    return tail
}

/// After a subcommand has consumed every flag it recognises, reject
/// whatever is left so a stray positional or a mistyped flag fails loudly
/// instead of being silently dropped (issue #237). Silent fallthrough is
/// especially dangerous for verbs whose no-target default is "the calling
/// pane" (e.g. `pane capture`): `nex pane capture <uuid>` would otherwise
/// drop the positional and capture the caller's own pane with exit 0.
///
/// `positionalHint` is appended to the unexpected-positional message to
/// point the caller at the flag they meant to use (e.g.
/// "target panes with --target <name-or-uuid>"). `usage`, when supplied,
/// prints the subcommand's usage block to stderr before exiting.
/// A no-op when `args` is empty, so callers can invoke it unconditionally.
func rejectLeftoverArgs(
    _ args: ArraySlice<String>,
    command: String,
    positionalHint: String? = nil,
    usage: ((UnsafeMutablePointer<FILE>) -> Void)? = nil
) {
    guard let first = args.first else { return }
    if first.hasPrefix("-") {
        fputs("\(command): unknown option \(first)\n", stderr)
    } else if let positionalHint {
        fputs("\(command): unexpected argument '\(first)' — \(positionalHint)\n", stderr)
    } else {
        fputs("\(command): unexpected argument '\(first)'\n", stderr)
    }
    usage?(stderr)
    exit(1)
}

func requirePaneID() -> String {
    guard let paneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"] else {
        // Not running inside a Nex pane — silent exit
        exit(0)
    }
    return paneID
}

func sendJSON(_ payload: [String: String], commandLabel: String = "nex") {
    sendJSONAny(payload as [String: Any], commandLabel: commandLabel)
}

/// Accepts mixed-type payloads (e.g. `cascade: true`, `index: 3`) so
/// new group / workspace-move commands can encode JSON bools and
/// numbers instead of stringified ones. The server's `WireMessage`
/// decoder requires native JSON types for `cascade: Bool?` and
/// `index: Int?`.
func sendJSONAny(_ payload: [String: Any], commandLabel: String = "nex") {
    switch transport {
    case .unix(let path):
        sendViaUnix(path: path, payload: payload, expectsReply: false, commandLabel: commandLabel)
    case .tcp(let host, let port):
        sendViaTCP(host: host, port: port, payload: payload, expectsReply: false, commandLabel: commandLabel)
    }
}

/// Round-trip variant: send the payload, read until EOF, return the
/// accumulated response bytes. Returns `nil` if the transport fails;
/// callers must treat that differently from "empty reply" (which is
/// data.isEmpty but non-nil, signalling an older server that silently
/// dropped the request).
///
/// `readTimeoutOverride` extends the socket read timeout for commands
/// that legitimately block server-side longer than `replyTimeoutSeconds`
/// (currently just `web wait`, where the JS polls up to `--timeout`).
func sendJSONAndReadReply(
    _ payload: [String: Any], readTimeoutOverride: Int? = nil
) -> Data? {
    switch transport {
    case .unix(let path):
        sendViaUnix(
            path: path, payload: payload, expectsReply: true,
            readTimeoutOverride: readTimeoutOverride
        )
    case .tcp(let host, let port):
        sendViaTCP(
            host: host, port: port, payload: payload, expectsReply: true,
            readTimeoutOverride: readTimeoutOverride
        )
    }
}

// MARK: - Reply decoding

// Almost every request/response command shares the same reply preamble:
// send the payload, bail on transport failure, bail on an empty reply
// (an older Nex that closed the connection without answering), reject
// invalid JSON, and surface `ok:false` as a stderr error + non-zero
// exit. The three helpers below centralise each branch so the wording
// lives in exactly one place. `command` is always the full user-facing
// label, e.g. "nex pane list".

/// Send `payload` and return the guaranteed-non-empty reply bytes.
/// Exits non-zero on transport failure or an empty reply.
func readReplyOrExit(
    _ payload: [String: Any], command: String, readTimeoutOverride: Int? = nil
) -> Data {
    guard let data = sendJSONAndReadReply(payload, readTimeoutOverride: readTimeoutOverride) else {
        printTransportFailure(command: command)
        exit(1)
    }
    guard !data.isEmpty else {
        fputs("\(command): no response from Nex (upgrade required?)\nRepair: if the running Nex is recent, the app may be wedged — try `nex doctor` first, then restart Nex if needed.\n", stderr)
        exit(1)
    }
    return data
}

/// Decode a non-empty reply and enforce the `{ok, error?}` envelope.
/// Exits non-zero on invalid JSON or `ok:false`. Call this directly
/// (after a bespoke empty-reply check) for the few commands that treat
/// an empty reply specially — `pane send` succeeds on empty, while
/// `pane send-key` / `pane sync` print a "may not support" message.
func parseReplyOrExit(_ data: Data, command: String) -> [String: Any] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("\(command): invalid JSON response\n", stderr)
        exit(1)
    }
    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        fputs("\(command): \(msg)\n", stderr)
        exit(1)
    }
    return json
}

/// Full round-trip for a command returning the standard `{ok, ...}`
/// envelope: send, then exit non-zero with a categorised stderr message
/// on transport failure, empty reply, invalid JSON, or `ok:false`.
/// Returns the parsed reply for verb-specific rendering on success.
func decodeReply(
    _ payload: [String: Any], command: String, readTimeoutOverride: Int? = nil
) -> [String: Any] {
    let data = readReplyOrExit(payload, command: command, readTimeoutOverride: readTimeoutOverride)
    return parseReplyOrExit(data, command: command)
}

/// Round-trip variant for batch commands (bulk `workspace delete`) that
/// must keep going after a single `ok:false`. Transport failure, an
/// empty reply, and invalid JSON stay fatal for the whole batch — they
/// mean the socket is dead or the app is too old, so no later id would
/// fare better. A well-formed `{ok:false}` is *returned* (never exits)
/// so the caller records the per-id failure and moves on.
func decodeReplyAllowingFailure(
    _ payload: [String: Any], command: String
) -> [String: Any] {
    let data = readReplyOrExit(payload, command: command)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("\(command): invalid JSON response\n", stderr)
        exit(1)
    }
    return json
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

/// Set by `nex event …` (Claude Code hook entrypoint) to avoid
/// stderr spam in user terminals on every hook fire when Nex is
/// closed. Distinct from `NEX_SILENT`, which is the user-facing
/// opt-in for non-hook callers.
var suppressFireAndForgetWarnings = false

/// Fire-and-forget callers historically wanted a silent exit(0) when
/// Nex wasn't reachable so Claude Code Stop hooks etc. wouldn't fail.
/// We preserve the exit code, but surface a one-line stderr warning
/// with a repair tip so the user can at least see why nothing
/// happened. Set `NEX_SILENT=1` to fully suppress (matches the old
/// behaviour for callers that explicitly opt in). `nex event …`
/// hooks also suppress by default since they fire on every Claude
/// Code stop/start — set `NEX_VERBOSE_HOOKS=1` to opt back in.
func handleFireAndForgetTransportFailure(command: String) -> Never {
    if !suppressFireAndForgetWarnings,
       ProcessInfo.processInfo.environment["NEX_SILENT"] == nil {
        printTransportFailure(command: command, fireAndForget: true)
    }
    exit(0)
}

@discardableResult
func sendViaUnix(
    path: String, payload: [String: Any], expectsReply: Bool,
    readTimeoutOverride: Int? = nil,
    commandLabel: String = "nex"
) -> Data? {
    // Reset the global so a previous call's diagnostic can't leak
    // into this call's failure path. Important for `nex doctor`,
    // which makes multiple successive calls (ping + ps) — without
    // this reset, a passed ping followed by a failed-but-no-update
    // path could surface the stale prior diagnostic.
    lastTransportFailure = nil

    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
          var jsonString = String(data: jsonData, encoding: .utf8)
    else {
        exit(1)
    }

    jsonString += "\n"

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        lastTransportFailure = .createSocketFailed(errno: errno)
        if expectsReply { return nil }
        handleFireAndForgetTransportFailure(command: commandLabel)
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
        let err = errno
        close(fd)
        switch err {
        case ENOENT:
            lastTransportFailure = .unixSocketMissing(path: path)
        case ECONNREFUSED:
            lastTransportFailure = .unixConnectRefused(path: path)
        default:
            lastTransportFailure = .unixConnectFailed(path: path, errno: err)
        }
        if expectsReply { return nil }
        handleFireAndForgetTransportFailure(command: commandLabel)
    }

    jsonString.withCString { ptr in
        let len = strlen(ptr)
        _ = send(fd, ptr, len, 0)
    }

    if expectsReply {
        setReadTimeout(fd: fd, seconds: readTimeoutOverride ?? replyTimeoutSeconds)
    }
    let reply: Data? = expectsReply ? readUntilEOF(fd: fd) : nil
    close(fd)
    if expectsReply, reply == nil {
        // `readUntilEOF` returns nil when read(2) errors with
        // something other than EINTR/EAGAIN before any bytes
        // arrived (e.g. ECONNRESET after the peer closed mid-handshake).
        // The connection succeeded so this isn't a "missing socket"
        // condition — surface it as emptyReply so the caller's
        // repair tip points at "wedged or pre-ping Nex" rather than
        // the no-diagnostic-captured fallback.
        lastTransportFailure = .emptyReply(command: (payload["command"] as? String) ?? commandLabel)
    }
    return reply
}

@discardableResult
func sendViaTCP(
    host: String, port: UInt16, payload: [String: Any], expectsReply: Bool,
    readTimeoutOverride: Int? = nil,
    commandLabel: String = "nex"
) -> Data? {
    // See note on `sendViaUnix` — reset so doctor / chained calls
    // don't surface stale prior diagnostics.
    lastTransportFailure = nil

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
        lastTransportFailure = .tcpResolveFailed(host: host)
        if expectsReply { return nil }
        handleFireAndForgetTransportFailure(command: commandLabel)
    }
    defer { freeaddrinfo(result) }

    let fd = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, addrInfo.pointee.ai_protocol)
    guard fd >= 0 else {
        lastTransportFailure = .createSocketFailed(errno: errno)
        if expectsReply { return nil }
        handleFireAndForgetTransportFailure(command: commandLabel)
    }

    let connectResult = connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)

    guard connectResult == 0 else {
        let err = errno
        close(fd)
        lastTransportFailure = .tcpConnectFailed(host: host, port: port, errno: err)
        if expectsReply { return nil }
        handleFireAndForgetTransportFailure(command: commandLabel)
    }

    jsonString.withCString { ptr in
        let len = strlen(ptr)
        _ = send(fd, ptr, len, 0)
    }

    if expectsReply {
        setReadTimeout(fd: fd, seconds: readTimeoutOverride ?? replyTimeoutSeconds)
    }
    let reply: Data? = expectsReply ? readUntilEOF(fd: fd) : nil
    close(fd)
    if expectsReply, reply == nil {
        // See note on the matching Unix path.
        lastTransportFailure = .emptyReply(command: (payload["command"] as? String) ?? commandLabel)
    }
    return reply
}

// MARK: - Subcommands

func handleEvent(_ args: inout ArraySlice<String>) {
    // `nex event …` is the Claude Code hook entrypoint (Stop, Start,
    // Notification, etc.). These run on every hook fire — including
    // when the user has Nex closed — so a stderr warning per call
    // would spam the terminal. Silence transport warnings unless the
    // user has explicitly opted in to verbose hook output.
    if ProcessInfo.processInfo.environment["NEX_VERBOSE_HOOKS"] == nil {
        suppressFireAndForgetWarnings = true
    }

    guard let eventType = args.popFirst() else {
        fputs("Usage: nex event stop|start|error|notification|session-start|session-end [--message ...] [--title ...] [--body ...]\n", stderr)
        exit(1)
    }

    let validEvents: Set = ["stop", "start", "error", "notification", "session-start", "session-end"]
    guard validEvents.contains(eventType) else {
        fputs("Unknown event type: \(eventType)\n", stderr)
        fputs("Valid events: stop, start, error, notification, session-start, session-end\n", stderr)
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

    sendJSON(payload, commandLabel: "nex event \(eventType)")
}

func handlePane(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex pane split|create|close|name|send|send-key|move|list|capture|sync|id [...]\n", stderr)
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
        // Issue #117: works from outside a Nex pane. `--target` names the
        // pane to split (UUID = global, label needs scope), `--workspace`
        // scopes label resolution or splits that workspace's focused pane.
        // Request/response so the new pane's id comes back and failures
        // exit non-zero.
        if args.contains("--help") || args.contains("-h") {
            printPaneSplitUsage(stream: stdout)
            exit(0)
        }
        let direction = parseFlag("--direction", from: &args)
        let path = parseFlag("--path", from: &args)
        let name = parseFlag("--name", from: &args)
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        // `pane split` takes no positionals; reject stray args / unknown
        // flags instead of silently dropping them (issue #237).
        rejectLeftoverArgs(args, command: "nex pane split", usage: printPaneSplitUsage)
        let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        guard target != nil || workspace != nil || originPaneID != nil else {
            fputs("nex pane split: requires --target <name-or-uuid> or --workspace <name-or-id> when called from outside a Nex pane\n", stderr)
            printPaneSplitUsage(stream: stderr)
            exit(1)
        }
        var payload: [String: Any] = ["command": "pane-split"]
        if let direction { payload["direction"] = direction }
        if let path { payload["path"] = path }
        if let name { payload["name"] = name }
        if let target { payload["target"] = target }
        if let workspace { payload["workspace"] = workspace }
        if let originPaneID { payload["pane_id"] = originPaneID }
        sendPaneMutationReply(payload, command: "split", asJSON: asJSON, verb: "split pane")

    case "create":
        if args.contains("--help") || args.contains("-h") {
            printPaneCreateUsage(stream: stdout)
            exit(0)
        }
        let path = parseFlag("--path", from: &args)
        let name = parseFlag("--name", from: &args)
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        // `pane create` takes no positionals; reject stray args / unknown
        // flags instead of silently dropping them (issue #237).
        rejectLeftoverArgs(args, command: "nex pane create", usage: printPaneCreateUsage)
        let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        guard target != nil || workspace != nil || originPaneID != nil else {
            fputs("nex pane create: requires --workspace <name-or-id> or --target <name-or-uuid> when called from outside a Nex pane\n", stderr)
            printPaneCreateUsage(stream: stderr)
            exit(1)
        }
        var payload: [String: Any] = ["command": "pane-create"]
        if let path { payload["path"] = path }
        if let name { payload["name"] = name }
        if let target { payload["target"] = target }
        if let workspace { payload["workspace"] = workspace }
        if let originPaneID { payload["pane_id"] = originPaneID }
        sendPaneMutationReply(payload, command: "create", asJSON: asJSON, verb: "created pane")

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

        let json = decodeReply(payload, command: "nex pane close")
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
        // Issue #117: `--target` renames any pane from outside Nex;
        // without it, renames the caller pane (NEX_PANE_ID). The new
        // label is the sole positional. Reject stray options/positionals
        // (issue #108) so a typo can't misroute. Request/response.
        if args.contains("--help") || args.contains("-h") {
            printPaneNameUsage(stream: stdout)
            exit(0)
        }
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        let unknownOpts = args.filter { $0.hasPrefix("-") }
        if let first = unknownOpts.first {
            fputs("nex pane name: unknown option \(first)\n", stderr)
            printPaneNameUsage(stream: stderr)
            exit(1)
        }
        let positionals = args.filter { !$0.hasPrefix("-") }
        guard let name = positionals.first, positionals.count == 1, !name.isEmpty else {
            fputs("nex pane name: exactly one <name> argument is required\n", stderr)
            printPaneNameUsage(stream: stderr)
            exit(1)
        }
        let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        guard target != nil || originPaneID != nil else {
            fputs("nex pane name: requires --target <name-or-uuid> when called from outside a Nex pane\n", stderr)
            printPaneNameUsage(stream: stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "pane-name",
            "name": name
        ]
        if let target { payload["target"] = target }
        if let workspace { payload["workspace"] = workspace }
        if let originPaneID { payload["pane_id"] = originPaneID }
        sendPaneMutationReply(payload, command: "name", asJSON: asJSON, verb: "renamed pane")

    case "resize":
        // Issue #241: resize a pane against its split sibling so agents
        // can keep a coordinator prominent / balance a fanned-out grid
        // without the GUI. Mirrors `pane name` scoping (works from outside
        // a Nex pane via --target). Request/response.
        if args.contains("--help") || args.contains("-h") {
            printPaneResizeUsage(stream: stdout)
            exit(0)
        }
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        let ratioStr = parseFlag("--ratio", from: &args)
        let grow = parseOptionalAmountFlag("--grow", default: 0.05, from: &args)
        let shrink = parseOptionalAmountFlag("--shrink", default: 0.05, from: &args)

        let directives = [ratioStr != nil, grow != nil, shrink != nil].count(where: { $0 })
        guard directives == 1 else {
            fputs("nex pane resize: exactly one of --ratio / --grow / --shrink is required\n", stderr)
            printPaneResizeUsage(stream: stderr)
            exit(1)
        }

        rejectLeftoverArgs(
            args, command: "pane resize",
            positionalHint: "size panes with --ratio / --grow / --shrink",
            usage: printPaneResizeUsage
        )

        let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        guard target != nil || originPaneID != nil else {
            fputs("nex pane resize: requires --target <name-or-uuid> when called from outside a Nex pane\n", stderr)
            printPaneResizeUsage(stream: stderr)
            exit(1)
        }

        var payload: [String: Any] = ["command": "pane-resize"]
        if let ratioStr {
            guard let ratio = Double(ratioStr), ratio > 0, ratio < 1 else {
                fputs("nex pane resize: --ratio must be a number between 0 and 1 (exclusive)\n", stderr)
                exit(1)
            }
            payload["ratio"] = ratio
        } else if let grow {
            payload["delta"] = grow
        } else if let shrink {
            payload["delta"] = -shrink
        }
        if let target { payload["target"] = target }
        if let workspace { payload["workspace"] = workspace }
        if let originPaneID { payload["pane_id"] = originPaneID }

        guard let replyData = sendJSONAndReadReply(payload) else {
            printTransportFailure(command: "nex pane resize")
            exit(1)
        }
        if replyData.isEmpty {
            fputs("nex pane resize: empty reply (Nex version may not support this command)\n", stderr)
            exit(1)
        }
        let json = parseReplyOrExit(replyData, command: "nex pane resize")
        if asJSON {
            var clean = json
            clean.removeValue(forKey: "ok")
            if let data = try? JSONSerialization.data(withJSONObject: clean, options: .sortedKeys),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return
        }
        let resolvedID = (json["pane_id"] as? String) ?? "?"
        let resolvedLabel = json["label"] as? String
        let resolvedWS = json["workspace_name"] as? String
        var ack = "resized \(resolvedID)"
        if let resolvedLabel { ack += " (\(resolvedLabel))" }
        if let share = json["target_share"] as? Double {
            ack += String(format: " to %.0f%% of its split", share * 100)
        }
        if let resolvedWS { ack += " in workspace \(resolvedWS)" }
        print(ack)

    case "send":
        // Issue #117: works from outside a Nex pane. `pane_id` (the
        // caller, when set) only scopes label resolution; routing is by
        // `--target` (UUID = global, label needs a scope via NEX_PANE_ID
        // or `--workspace`).
        if args.contains("--help") || args.contains("-h") {
            printPaneSendUsage(stream: stdout)
            exit(0)
        }
        // `--target` matches the rest of the pane subcommands; `--to`
        // is the original flag and remains supported as a quiet alias
        // for any scripts that already use it.
        let target = parseFlag("--target", from: &args) ?? parseFlag("--to", from: &args)
        guard let target else {
            printPaneSendUsage(stream: stderr)
            exit(1)
        }
        // `--workspace <name-or-id>` scopes label resolution. Without
        // it, the server restricts label lookup to the sender's own
        // workspace (issue #92). Parse before joining the rest of the
        // args into the payload text.
        let workspace = parseFlag("--workspace", from: &args)
        // `--bare` (issue #98) — write text without appending Enter.
        let bare = popSwitch("--bare", from: &args)
        // `--json` (issue #117) — print the server's structured reply
        // verbatim instead of the human ack. Parse before joining text.
        let asJSON = popSwitch("--json", from: &args)

        let text = args.joined(separator: " ")
        guard !text.isEmpty else {
            printPaneSendUsage(stream: stderr)
            exit(1)
        }

        var payload: [String: Any] = [
            "command": "pane-send",
            "target": target,
            "text": text,
            "bare": bare
        ]
        if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
           !originPaneID.isEmpty {
            payload["pane_id"] = originPaneID
        }
        if let workspace {
            payload["workspace"] = workspace
        }

        guard let replyData = sendJSONAndReadReply(payload) else {
            printTransportFailure(command: "nex pane send")
            exit(1)
        }
        // Empty reply = older Nex that silently dropped the request.
        // Fire-and-forget pre-#92 servers behaved this way; treat as
        // success so users on mixed-version setups aren't blocked.
        if replyData.isEmpty {
            return
        }
        let json = parseReplyOrExit(replyData, command: "nex pane send")
        if asJSON {
            var clean = json
            clean.removeValue(forKey: "ok")
            if let data = try? JSONSerialization.data(withJSONObject: clean, options: .sortedKeys),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return
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
            printTransportFailure(command: "nex pane send-key")
            exit(1)
        }
        // Empty reply = older Nex that doesn't know the command. Treat
        // as failure — unlike `pane send`, there's no pre-#98 fallback
        // path that produced the right behaviour silently.
        if replyData.isEmpty {
            fputs("nex pane send-key: empty reply (Nex version may not support this command)\n", stderr)
            exit(1)
        }
        let json = parseReplyOrExit(replyData, command: "nex pane send-key")
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

    case "sync":
        handlePaneSync(&args)

    default:
        fputs("Unknown pane action: \(action)\n", stderr)
        fputs("Valid actions: split, create, close, name, send, send-key, move, move-to-workspace, list, capture, sync, id\n", stderr)
        exit(1)
    }
}

// MARK: - pane sync (issue #121)

/// Implements `nex pane sync (on|off|toggle|status|exclude|include)`.
/// All forms are request/response and exit non-zero on server error.
func handlePaneSync(_ args: inout ArraySlice<String>) {
    guard let mode = args.popFirst() else {
        printPaneSyncUsage(stream: stderr)
        exit(1)
    }

    if mode == "-h" || mode == "--help" || mode == "help" {
        printPaneSyncUsage(stream: stdout)
        exit(0)
    }

    let workspace = parseFlag("--workspace", from: &args)
    let asJSON = popSwitch("--json", from: &args)

    switch mode {
    case "on", "off", "toggle", "status":
        // `--target` doesn't make sense for the whole-workspace
        // toggle — surface the typo rather than silently dropping it.
        if let stray = parseFlag("--target", from: &args) {
            fputs("nex pane sync \(mode): --target \(stray) is not valid here " +
                "(the toggle is workspace-wide). Use `nex pane sync exclude --target ...` " +
                "to opt a pane out.\n", stderr)
            exit(1)
        }
        if let stray = args.first {
            fputs("nex pane sync \(mode): unexpected argument '\(stray)'\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "pane-sync",
            "action": mode
        ]
        if let workspace, !workspace.isEmpty {
            payload["workspace"] = workspace
        }
        if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
           !originPaneID.isEmpty {
            payload["pane_id"] = originPaneID
        }
        sendPaneSyncReply(payload, command: "sync \(mode)", asJSON: asJSON)

    case "exclude", "include":
        let target = parseFlag("--target", from: &args)
        guard let target, !target.isEmpty else {
            fputs("Usage: nex pane sync \(mode) --target <name-or-uuid> [--workspace <name-or-uuid>]\n", stderr)
            exit(1)
        }
        if let stray = args.first {
            fputs("nex pane sync \(mode): unexpected argument '\(stray)'\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "pane-sync-exclude",
            "target": target,
            "excluded": mode == "exclude"
        ]
        if let workspace, !workspace.isEmpty {
            payload["workspace"] = workspace
        }
        if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
           !originPaneID.isEmpty {
            payload["pane_id"] = originPaneID
        }
        sendPaneSyncReply(payload, command: "sync \(mode)", asJSON: asJSON)

    default:
        fputs("Unknown sync mode: \(mode)\n", stderr)
        printPaneSyncUsage(stream: stderr)
        exit(1)
    }
}

func printPaneSyncUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex pane sync (on|off|toggle|status) [--workspace <name-or-uuid>] [--json]
      nex pane sync exclude --target <name-or-uuid> [--workspace <name-or-uuid>]
      nex pane sync include --target <name-or-uuid> [--workspace <name-or-uuid>]

    When `on`, every keystroke typed in any pane of the workspace is mirrored
    to the other panes in the workspace. Use `exclude` / `include` to opt a
    specific pane out of (or back into) the sync group. `status` reports the
    current sync state without mutating it.

    Excludes are ephemeral within a single on-cycle: any `on` / `off` /
    `toggle` clears the exclusion set. Sequence is `sync on` first, then
    `sync exclude --target <pane>`; running exclude while sync is off has
    no effect on the next on-cycle.

    Workspace defaults to the calling pane's workspace (via NEX_PANE_ID)
    when --workspace is not supplied.
    \n
    """, stream)
}

private func sendPaneSyncReply(
    _ payload: [String: Any], command: String, asJSON: Bool
) {
    guard let replyData = sendJSONAndReadReply(payload) else {
        printTransportFailure(command: "nex pane \(command)")
        exit(1)
    }
    if replyData.isEmpty {
        fputs("nex pane \(command): empty reply (Nex version may not support this command)\n", stderr)
        exit(1)
    }
    let json = parseReplyOrExit(replyData, command: "nex pane \(command)")

    if asJSON {
        // Strip the `ok` field so JSON consumers see the same shape
        // they'd get from a status-only query without the success flag
        // (success is implicit since we exit non-zero on `ok: false`).
        var clean = json
        clean.removeValue(forKey: "ok")
        if let data = try? JSONSerialization.data(withJSONObject: clean, options: .sortedKeys),
           let string = String(data: data, encoding: .utf8) {
            print(string)
        }
        return
    }

    // Default human-readable summary.
    let active = (json["active"] as? Bool) ?? false
    let synced = (json["synced_pane_ids"] as? [String]) ?? []
    let excluded = (json["excluded"] as? [[String: Any]]) ?? []
    let workspaceName = (json["workspace_name"] as? String) ?? "?"

    let stateStr = active ? "on" : "off"
    print("workspace: \(workspaceName)")
    print("sync     : \(stateStr)")
    if active {
        print("synced   : \(synced.count) pane\(synced.count == 1 ? "" : "s")")
        if !excluded.isEmpty {
            let labels = excluded.compactMap { entry -> String in
                if let label = entry["label"] as? String, !label.isEmpty {
                    return label
                }
                return (entry["id"] as? String) ?? "?"
            }
            print("excluded : \(labels.joined(separator: ", "))")
        }
    }
}

// MARK: - web (top-level subcommand)

func printWebUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex web open      [--private] <url>
      nex web navigate  [--target <name-or-uuid>] [--workspace <name-or-uuid>] <url>
      nex web url       [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web back     [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web forward  [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web reload   [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--hard]
      nex web capture  [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--mode meta|text|screenshot]
      nex web tabs        [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--json] [--no-header]
      nex web tab-new     [<url>] [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--no-focus]
      nex web tab-close   <ref> [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web tab-select  <ref> [--target <name-or-uuid>] [--workspace <name-or-uuid>]
      nex web console     [--target ...] [--workspace ...] [--since N] [--level log|debug|info|warn|error] [--clear] [--json]
      nex web inspect     [--target ...] [--workspace ...] [--send-to <pane>] [--submit] [--disarm]
      nex web inspect-result [--target ...] [--workspace ...] [--clear] [--json]
      nex web private    on|off [--target ...] [--workspace ...]
      nex web cookies    list|clear|delete [...]
      nex web click   [--target ...] [--workspace ...] <selector> [--double] [--right] [--at x,y] [--json]
      nex web type    [--target ...] [--workspace ...] <selector> <text> [--submit] [--no-replace] [--json]
      nex web text    [--target ...] [--workspace ...] <selector> [--max-bytes N] [--json]
      nex web attr    [--target ...] [--workspace ...] <selector> <attribute> [--json]
      nex web count   [--target ...] [--workspace ...] <selector> [--json]
      nex web exists  [--target ...] [--workspace ...] <selector>   # exit 0 = yes, 1 = no
      nex web dom     [--target ...] [--workspace ...] <selector> [--max-bytes N] [--json]
      nex web wait    [--target ...] [--workspace ...] (--selector <sel> | --url-match <sub-or-regex>) [--for visible|hidden|exists|count=N|text=X] [--timeout 10] [--json]
      nex web select  [--target ...] [--workspace ...] <selector> <value-or-label> [--json]
      nex web scroll  [--target ...] [--workspace ...] <selector> [--top|--bottom|--smooth] [--json]
      nex web hover   [--target ...] [--workspace ...] <selector> [--json]
      nex web key     [--target ...] [--workspace ...] <key-name> [--selector <sel>] [--json]
      nex web exec    [--target ...] [--workspace ...] (--file <path> | <js>) [--timeout S] [--json]

    `web exec` runs author-supplied JS inside an async wrapper with
    $ / $$ / nex bound to __nexAct.find / __nexAct.findAll / __nexAct.
    A single trailing expression is returned automatically; for
    multi-statement scripts, use an explicit `return`. `--timeout`
    bounds how long the CLI waits for a reply (default 30s, since
    `nex.wait` alone can run for 10s).

    `open`, `navigate`, and `tab-new` resolve local file paths: an
    explicit path (./x, ../x, /x, ~/x), or a bare name that matches a
    file with an extension in the current directory, is converted to
    a `file://` URL — so `nex web open foo.html` just works. Bare
    hostnames (example.com) and single-label hosts (app, api) stay
    URLs; use ./name to force a local path.

    When invoked from outside a Nex pane, --target must be a UUID
    or --workspace <name-or-id> must be passed (label resolution
    needs an explicit workspace scope).

    For `click`, `type`, and `select`, use `--` to terminate options
    when the positional payload looks like a flag (e.g. typing the
    literal string "--submit" into a search box, or selecting an
    option whose value is "--json"):
      nex web type css:#i -- --submit
      nex web select css:#s -- --json
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

/// If `arg` denotes a local filesystem path (rather than a URL,
/// opaque scheme, or bare hostname), return a percent-encoded
/// `file://` URL resolved against the current directory (expanding
/// `~`). Otherwise return nil so the caller forwards the raw input
/// and the app treats it as a hostname / URL.
///
/// A path is recognised when it is clearly path-shaped (`/`, `./`,
/// `../`, or `~` prefix), or when a *bare* argument names a regular
/// file **with an extension** that exists in the current directory —
/// so `nex web open foo.html` opens the local file, while
/// `nex web open example.com` (no such file) and `nex web open app`
/// (a directory, or a single-label internal hostname) stay hostnames
/// (issue #177). Bare extensionless names are never treated as files,
/// so dev hostnames like `app` / `web` / `api` that collide with cwd
/// directories aren't hijacked — use `./app` to force a local path.
func localFileURL(forWebArg arg: String) -> String? {
    let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    // Already a full URL (http://, https://, file://, ...).
    if trimmed.contains("://") { return nil }
    // Opaque scheme without `://` (data:, mailto:, about:, tel:, ...).
    // A letter-led token followed by a colon whose next char isn't a
    // digit is a scheme, not a `host:port`. Path-like inputs never
    // start with letter+colon, so they fall through to the path check.
    if let colonIdx = trimmed.firstIndex(of: ":"),
       let first = trimmed.first, first.isLetter {
        let scheme = trimmed[..<colonIdx]
        let schemeChars = scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
        let afterColon = trimmed[trimmed.index(after: colonIdx)...]
        let looksLikePort = afterColon.first?.isNumber == true
        if schemeChars, !looksLikePort { return nil }
    }

    let looksLikePath = trimmed.hasPrefix("/")
        || trimmed.hasPrefix("./")
        || trimmed.hasPrefix("../")
        || trimmed.hasPrefix("~")
    var path = trimmed
    if path.hasPrefix("~") {
        path = (path as NSString).expandingTildeInPath
    }
    let cwd = FileManager.default.currentDirectoryPath
    let absolute = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd))
        .standardizedFileURL

    // An explicit path is always a file. A bare argument is only a
    // file when a regular file with that name *and* a file extension
    // exists in the cwd — so directories and extensionless single-label
    // hostnames pass through to the app as hosts (see doc comment).
    if looksLikePath {
        return absolute.absoluteString
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: absolute.path, isDirectory: &isDirectory)
    if exists, !isDirectory.boolValue, !absolute.pathExtension.isEmpty {
        return absolute.absoluteString
    }
    return nil
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
        let isPrivate = popSwitch("--private", from: &args)
        if args.contains("--target") || args.contains("--workspace") {
            fputs("nex web open: --target / --workspace are not supported (open always creates a new pane).\n", stderr)
            fputs("       Use `nex web navigate <url> --target X [--workspace Y]` to redirect an existing pane's active tab,\n", stderr)
            fputs("       or `nex web tab-new <url> --target X` to open in a new tab.\n", stderr)
            exit(1)
        }
        guard let url = args.popFirst(), !url.isEmpty else {
            fputs("Usage: nex web open [--private] <url>\n", stderr)
            exit(1)
        }
        if url.hasPrefix("-") {
            fputs("nex web open: unexpected option '\(url)' (URL must not start with '-')\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-open",
            "url": localFileURL(forWebArg: url) ?? url
        ]
        if isPrivate {
            payload["private"] = true
        }
        if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
           !originPaneID.isEmpty {
            payload["pane_id"] = originPaneID
        }
        sendWebReplyAndPrintBasic(payload, command: "open")

    case "navigate":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        guard let url = args.popFirst(), !url.isEmpty else {
            fputs("Usage: nex web navigate <url> [--target <name-or-uuid>] [--workspace <name-or-uuid>]\n", stderr)
            exit(1)
        }
        if url.hasPrefix("-") {
            fputs("nex web navigate: unexpected option '\(url)' (URL must not start with '-')\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-navigate",
            "url": localFileURL(forWebArg: url) ?? url
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "navigate")
        sendWebReplyAndPrintBasic(payload, command: "navigate")

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

    case "tabs":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        let noHeader = popSwitch("--no-header", from: &args)
        var payload: [String: Any] = ["command": "web-tabs"]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "tabs")
        sendWebReplyAndPrintTabs(payload, asJSON: asJSON, noHeader: noHeader)

    case "tab-new":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let noFocus = popSwitch("--no-focus", from: &args)
        let url = args.popFirst() ?? ""
        var payload: [String: Any] = [
            "command": "web-tab-new",
            "url": url.isEmpty ? url : (localFileURL(forWebArg: url) ?? url),
            "make_active": !noFocus
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "tab-new")
        sendWebReplyAndPrintBasic(payload, command: "tab-new")

    case "tab-close":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        guard let ref = args.popFirst(), !ref.isEmpty else {
            fputs("Usage: nex web tab-close <ref> [--target X] [--workspace Y]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-tab-close",
            "tab": ref
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "tab-close")
        sendWebReplyAndPrintBasic(payload, command: "tab-close")

    case "tab-select":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        guard let ref = args.popFirst(), !ref.isEmpty else {
            fputs("Usage: nex web tab-select <ref> [--target X] [--workspace Y]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-tab-select",
            "tab": ref
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "tab-select")
        sendWebReplyAndPrintBasic(payload, command: "tab-select")

    case "console":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let sinceArg = parseFlag("--since", from: &args)
        let level = parseFlag("--level", from: &args)
        let clear = popSwitch("--clear", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        var payload: [String: Any] = ["command": "web-console"]
        if let sinceArg, let parsed = UInt64(sinceArg) {
            payload["since"] = parsed
        } else if let sinceArg {
            fputs("nex web console: --since must be an unsigned integer (got '\(sinceArg)')\n", stderr)
            exit(1)
        }
        if let level {
            let allowed: Set = ["log", "debug", "info", "warn", "error"]
            guard allowed.contains(level) else {
                fputs("nex web console: --level must be one of log|debug|info|warn|error\n", stderr)
                exit(1)
            }
            payload["level"] = level
        }
        if clear { payload["clear"] = true }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "console")
        sendWebReplyAndPrintConsole(payload, asJSON: asJSON)

    case "inspect":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let sendTo = parseFlag("--send-to", from: &args)
        let submit = popSwitch("--submit", from: &args)
        let disarm = popSwitch("--disarm", from: &args)
        var payload: [String: Any] = ["command": "web-inspect"]
        if let sendTo { payload["send_to"] = sendTo }
        if submit { payload["submit"] = true }
        if disarm { payload["disarm"] = true }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "inspect")
        sendWebReplyAndPrintInspect(payload)

    case "inspect-result":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let clear = popSwitch("--clear", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        var payload: [String: Any] = ["command": "web-inspect-result"]
        if clear { payload["clear"] = true }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "inspect-result")
        sendWebReplyAndPrintInspectResult(payload, asJSON: asJSON)

    case "private":
        guard let mode = args.popFirst(), !mode.isEmpty else {
            fputs("Usage: nex web private on|off [--target X] [--workspace Y]\n", stderr)
            exit(1)
        }
        let enabled: Bool
        switch mode.lowercased() {
        case "on", "true", "1", "yes":
            enabled = true
        case "off", "false", "0", "no":
            enabled = false
        default:
            fputs("nex web private: expected 'on' or 'off' (got '\(mode)')\n", stderr)
            exit(1)
        }
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        var payload: [String: Any] = [
            "command": "web-private",
            "private": enabled
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "private")
        sendWebReplyAndPrintPrivate(payload)

    case "cookies":
        handleWebCookies(&args)

    case "click":
        let tail = extractPositionalTail(from: &args)
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let double = popSwitch("--double", from: &args)
        let right = popSwitch("--right", from: &args)
        let atArg = parseFlag("--at", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        var positional = ArraySlice(args + tail)
        guard let selector = positional.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web click [--target X] [--workspace Y] <selector> [--double] [--right] [--at x,y] [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-click",
            "selector": selector
        ]
        if double { payload["double"] = true }
        if right { payload["right"] = true }
        if let atArg {
            let parts = atArg.split(separator: ",").map(String.init)
            guard parts.count == 2,
                  let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
                fputs("nex web click: --at must be 'x,y' numbers (got '\(atArg)')\n", stderr)
                exit(1)
            }
            payload["at_x"] = x
            payload["at_y"] = y
        }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "click")
        sendWebReplyAndPrintActuator(payload, command: "click", asJSON: asJSON)

    case "type":
        // Pull off any `--`-terminated tail before flag parsing so a
        // text payload like "--submit" or "--json" survives intact.
        let tail = extractPositionalTail(from: &args)
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let submit = popSwitch("--submit", from: &args)
        let noReplace = popSwitch("--no-replace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        var positional = ArraySlice(args + tail)
        guard let selector = positional.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web type [--target X] [--workspace Y] <selector> <text> [--submit] [--no-replace] [--json]\n", stderr)
            exit(1)
        }
        guard let text = positional.popFirst() else {
            fputs("Usage: nex web type [--target X] [--workspace Y] <selector> <text> [--submit] [--no-replace] [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-type",
            "selector": selector,
            "text": text
        ]
        if submit { payload["submit"] = true }
        if noReplace { payload["replace"] = false }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "type")
        sendWebReplyAndPrintActuator(payload, command: "type", asJSON: asJSON)

    case "text":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let maxBytes = parseFlag("--max-bytes", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let selector = args.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web text [--target X] [--workspace Y] <selector> [--max-bytes N] [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-q-text",
            "selector": selector
        ]
        if let maxBytes {
            guard let n = Int(maxBytes), n > 0 else {
                fputs("nex web text: --max-bytes must be a positive integer (got '\(maxBytes)')\n", stderr)
                exit(1)
            }
            payload["max_bytes"] = n
        }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "text")
        sendWebReplyAndPrintRead(payload, command: "text", asJSON: asJSON)

    case "attr":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let selector = args.popFirst(), !selector.isEmpty,
              let attribute = args.popFirst(), !attribute.isEmpty else {
            fputs("Usage: nex web attr [--target X] [--workspace Y] <selector> <attribute> [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-q-attr",
            "selector": selector,
            "attribute": attribute
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "attr")
        sendWebReplyAndPrintRead(payload, command: "attr", asJSON: asJSON)

    case "count":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let selector = args.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web count [--target X] [--workspace Y] <selector> [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-q-count",
            "selector": selector
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "count")
        sendWebReplyAndPrintRead(payload, command: "count", asJSON: asJSON)

    case "exists":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let selector = args.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web exists [--target X] [--workspace Y] <selector> [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-q-exists",
            "selector": selector
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "exists")
        sendWebReplyAndPrintRead(payload, command: "exists", asJSON: asJSON)

    case "dom":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let maxBytes = parseFlag("--max-bytes", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let selector = args.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web dom [--target X] [--workspace Y] <selector> [--max-bytes N] [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-q-dom",
            "selector": selector
        ]
        if let maxBytes {
            guard let n = Int(maxBytes), n > 0 else {
                fputs("nex web dom: --max-bytes must be a positive integer (got '\(maxBytes)')\n", stderr)
                exit(1)
            }
            payload["max_bytes"] = n
        }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "dom")
        sendWebReplyAndPrintRead(payload, command: "dom", asJSON: asJSON)

    case "select":
        // Pull off any `--`-terminated tail before flag parsing so a
        // value or label like "--json" survives intact.
        let tail = extractPositionalTail(from: &args)
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        var positional = ArraySlice(args + tail)
        guard let selector = positional.popFirst(), !selector.isEmpty,
              let valueOrLabel = positional.popFirst() else {
            fputs("Usage: nex web select [--target X] [--workspace Y] <selector> <value-or-label> [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-select",
            "selector": selector,
            "value_or_label": valueOrLabel
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "select")
        sendWebReplyAndPrintActuator(payload, command: "select", asJSON: asJSON)

    case "scroll":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let top = popSwitch("--top", from: &args)
        let bottom = popSwitch("--bottom", from: &args)
        let smooth = popSwitch("--smooth", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let selector = args.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web scroll [--target X] [--workspace Y] <selector> [--top|--bottom|--smooth] [--json]\n", stderr)
            exit(1)
        }
        if top, bottom {
            fputs("nex web scroll: --top and --bottom are mutually exclusive\n", stderr)
            exit(1)
        }
        let block = top ? "start" : (bottom ? "end" : "center")
        let behavior = smooth ? "smooth" : "instant"
        var payload: [String: Any] = [
            "command": "web-scroll",
            "selector": selector,
            "block": block,
            "behavior": behavior
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "scroll")
        sendWebReplyAndPrintActuator(payload, command: "scroll", asJSON: asJSON)

    case "hover":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let selector = args.popFirst(), !selector.isEmpty else {
            fputs("Usage: nex web hover [--target X] [--workspace Y] <selector> [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-hover",
            "selector": selector
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "hover")
        sendWebReplyAndPrintActuator(payload, command: "hover", asJSON: asJSON)

    case "key":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let selector = parseFlag("--selector", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        guard let keyName = args.popFirst(), !keyName.isEmpty else {
            fputs("Usage: nex web key [--target X] [--workspace Y] <key-name> [--selector <sel>] [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-key",
            "key": keyName
        ]
        if let selector { payload["selector"] = selector }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "key")
        sendWebReplyAndPrintActuator(payload, command: "key", asJSON: asJSON)

    case "exec":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let file = parseFlag("--file", from: &args)
        let timeoutStr = parseFlag("--timeout", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        // Default 30s — `nex.wait` itself defaults to 10s on the JS
        // side, and exec scripts routinely chain a wait with fetch /
        // another wait. 5s (the global default) trips on a single
        // `await nex.wait(...)` and surfaces a misleading "no response
        // from Nex" before the server replies.
        let timeoutSeconds: Double
        if let timeoutStr {
            // `parsed.isFinite` rejects `Double("inf")` / `Double("1e309")`
            // — both pass `> 0` but trap on `Int(_:)` conversion below.
            guard let parsed = Double(timeoutStr), parsed > 0, parsed.isFinite else {
                fputs("nex web exec: --timeout must be a positive finite number of seconds (got '\(timeoutStr)')\n", stderr)
                exit(1)
            }
            timeoutSeconds = parsed
        } else {
            timeoutSeconds = 30
        }
        let script: String
        if let file {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let str = String(data: data, encoding: .utf8) else {
                fputs("nex web exec: cannot read --file '\(file)'\n", stderr)
                exit(1)
            }
            script = str
        } else if let positional = args.popFirst(), !positional.isEmpty {
            script = positional
        } else {
            fputs("Usage: nex web exec [--target X] [--workspace Y] [--timeout S] (--file <path> | <js>) [--json]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-exec",
            "script": script
        ]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "exec")
        let readTimeout = max(Int(timeoutSeconds.rounded(.up)) + 5, replyTimeoutSeconds)
        sendWebReplyAndPrintExec(payload, asJSON: asJSON, readTimeoutOverride: readTimeout)

    case "wait":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let selector = parseFlag("--selector", from: &args)
        let forCondition = parseFlag("--for", from: &args)
        let urlMatch = parseFlag("--url-match", from: &args)
        let timeoutStr = parseFlag("--timeout", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        // Exactly one of --selector / --url-match must be present.
        // Conditions like visible/hidden/count/text always need a
        // selector; url-match conflicts with selector (the JS side
        // ignores selector when for=url-match anyway, but we reject
        // here so misuse surfaces at usage time).
        guard selector != nil || urlMatch != nil else {
            fputs("nex web wait: one of --selector or --url-match is required\n", stderr)
            exit(1)
        }
        if selector != nil, urlMatch != nil {
            fputs("nex web wait: --selector and --url-match are mutually exclusive\n", stderr)
            exit(1)
        }
        // --timeout is in seconds (matches user expectation); wire
        // ships milliseconds. Default 10s — JS side enforces the
        // same default if we ship 0.
        let timeoutSeconds: Double
        if let timeoutStr {
            // `isFinite` rejects `inf` / `1e309` — both pass `> 0` but
            // trap on the `Int(_:)` conversion below.
            guard let parsed = Double(timeoutStr), parsed > 0, parsed.isFinite else {
                fputs("nex web wait: --timeout must be a positive finite number of seconds (got '\(timeoutStr)')\n", stderr)
                exit(1)
            }
            timeoutSeconds = parsed
        } else {
            timeoutSeconds = 10
        }
        var payload: [String: Any] = [
            "command": "web-wait",
            "timeout_ms": Int(timeoutSeconds * 1000)
        ]
        if let selector { payload["selector"] = selector }
        if let urlMatch { payload["url_match"] = urlMatch }
        if let forCondition { payload["for"] = forCondition }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "wait")
        // The server can legitimately hold the reply for the full wait
        // duration. Pad the socket read timeout past `timeoutSeconds`
        // so a slow-firing or about-to-timeout condition still gets
        // its reply through instead of tripping the default 5s
        // "no response from Nex" error.
        let readTimeout = max(Int(timeoutSeconds.rounded(.up)) + 5, replyTimeoutSeconds)
        sendWebReplyAndPrintActuator(
            payload, command: "wait", asJSON: asJSON,
            readTimeoutOverride: readTimeout
        )

    default:
        fputs("Unknown web action: \(action)\n", stderr)
        printWebUsage(stream: stderr)
        exit(1)
    }
}

/// Decode a `web-*` reply envelope into a `[String: Any]` dict,
/// handling the shared error paths: transport failure, empty reply,
/// invalid JSON, `--json` pretty-print, and `ok==false` → stderr +
/// exit 1. Returns `nil` only when `--json` was requested AND the
/// reply had `ok==false` (so the JSON dump runs before exit) — in
/// every other failure mode this function calls `exit(1)` itself.
/// On success, returns the parsed dict ready for verb-specific
/// rendering.
private func decodeWebReply(
    _ payload: [String: Any], command: String, asJSON: Bool,
    readTimeoutOverride: Int? = nil
) -> [String: Any] {
    let data = readReplyOrExit(payload, command: "nex web \(command)", readTimeoutOverride: readTimeoutOverride)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("nex web \(command): invalid JSON response\n", stderr)
        exit(1)
    }
    if asJSON,
       let pretty = try? JSONSerialization.data(
           withJSONObject: json,
           options: [.prettyPrinted, .sortedKeys]
       ),
       let str = String(data: pretty, encoding: .utf8) {
        print(str)
    }
    if let ok = json["ok"] as? Bool, ok == false {
        let msg = (json["error"] as? String) ?? "unknown error"
        if !asJSON {
            fputs("nex web \(command): \(msg)\n", stderr)
        }
        exit(1)
    }
    return json
}

/// Reply printer for actuator action verbs (`click`, `type`).
/// One-line acknowledgement on success, exit-1 on `ok==false`.
/// `--json` dumps the full reply payload instead.
private func sendWebReplyAndPrintActuator(
    _ payload: [String: Any], command: String, asJSON: Bool,
    readTimeoutOverride: Int? = nil
) {
    let json = decodeWebReply(
        payload, command: command, asJSON: asJSON,
        readTimeoutOverride: readTimeoutOverride
    )
    if asJSON { return }
    switch command {
    case "click":
        let text = (json["text"] as? String) ?? ""
        let label = text.isEmpty ? "" : ": \"\(text)\""
        print("clicked\(label)")
    case "type":
        let value = (json["value"] as? String) ?? ""
        print("typed: \(value)")
    case "wait":
        // The decode helper already exited on ok=false (incl. timeout
        // sets ok:false), so reaching here means the condition fired.
        let cond = (json["condition"] as? String) ?? "exists"
        let waited = (json["waited_ms"] as? Int) ?? 0
        print("matched \(cond) in \(waited) ms")
    case "select":
        let label = (json["label"] as? String) ?? ""
        let value = (json["value"] as? String) ?? ""
        print("selected: \(label.isEmpty ? value : label)")
    case "scroll":
        print("scrolled")
    case "hover":
        print("hovered")
    case "key":
        let k = (json["key"] as? String) ?? ""
        print("key: \(k)")
    default:
        print("\(command) ok")
    }
}

/// Reply printer for read verbs (`text`, `attr`, `count`, `exists`,
/// `dom`). Each verb prints its primary value directly to stdout —
/// strings unquoted, numbers as-is, booleans surfaced via exit code
/// for `exists`. `--json` dumps the full reply but `exists` still
/// uses exit-1-for-not-found even in JSON mode so the until-loop
/// ergonomic survives `--json`.
private func sendWebReplyAndPrintRead(
    _ payload: [String: Any], command: String, asJSON: Bool
) {
    let json = decodeWebReply(payload, command: command, asJSON: asJSON)
    if asJSON {
        if command == "exists", let found = json["found"] as? Bool, !found {
            exit(1)
        }
        return
    }
    switch command {
    case "text":
        let text = (json["text"] as? String) ?? ""
        print(text)
    case "attr":
        // Distinguish attribute absent from attribute present with
        // empty value: absent → exit 1, present → print value (which
        // may be empty) and exit 0.
        let present = (json["present"] as? Bool) ?? false
        if !present {
            exit(1)
        }
        let value = (json["value"] as? String) ?? ""
        print(value)
    case "count":
        let count = (json["count"] as? Int) ?? 0
        print(count)
    case "exists":
        let found = (json["found"] as? Bool) ?? false
        exit(found ? 0 : 1)
    case "dom":
        let html = (json["outer_html"] as? String) ?? ""
        print(html)
    default:
        print("\(command) ok")
    }
}

private func sendWebReplyAndPrintExec(
    _ payload: [String: Any], asJSON: Bool, readTimeoutOverride: Int? = nil
) {
    let json = decodeWebReply(
        payload, command: "exec", asJSON: asJSON,
        readTimeoutOverride: readTimeoutOverride
    )
    if asJSON { return }
    guard let result = json["result"] else { return }
    switch result {
    case is NSNull:
        return
    case let s as String:
        print(s)
    case let b as Bool:
        print(b ? "true" : "false")
    case let n as NSNumber:
        // `.stringValue` prints integers without a trailing `.0`.
        print(n.stringValue)
    default:
        if let data = try? JSONSerialization.data(
            withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed]
        ), let str = String(data: data, encoding: .utf8) {
            print(str)
        } else {
            print(String(describing: result))
        }
    }
}

private func sendWebReplyAndPrintTabs(_ payload: [String: Any], asJSON: Bool, noHeader: Bool) {
    let json = decodeReply(payload, command: "nex web tabs")
    let tabs = (json["tabs"] as? [[String: Any]]) ?? []
    if asJSON {
        if let out = try? JSONSerialization.data(withJSONObject: tabs, options: [.sortedKeys]),
           let s = String(data: out, encoding: .utf8) {
            print(s)
        }
        return
    }
    // Plain text: INDEX  ACTIVE  TITLE  URL  ID
    if !noHeader {
        print("IDX  A  TITLE                    URL")
    }
    for tab in tabs {
        let idx = (tab["index"] as? Int) ?? 0
        let active = (tab["active"] as? Bool) ?? false
        let title = (tab["title"] as? String) ?? ""
        let url = (tab["url"] as? String) ?? ""
        let titleClipped = title.count > 24 ? String(title.prefix(23)) + "…" : title
        print(String(format: "%-3d  %@  %-24@  %@", idx, active ? "*" : " ", titleClipped as NSString, url))
    }
}

private func sendWebReplyAndPrintBasic(_ payload: [String: Any], command: String) {
    let json = decodeReply(payload, command: "nex web \(command)")
    let paneID = (json["pane_id"] as? String) ?? "?"
    let extra = if let url = json["url"] as? String { " (\(url))" } else { "" }
    print("\(command) ok: \(paneID)\(extra)")
}

private func sendWebReplyAndPrintURL(_ payload: [String: Any]) {
    let json = decodeReply(payload, command: "nex web url")
    let url = (json["url"] as? String) ?? ""
    let title = (json["title"] as? String) ?? ""
    if !title.isEmpty {
        print("\(url)\t\(title)")
    } else {
        print(url)
    }
}

private func sendWebReplyAndPrintCapture(_ payload: [String: Any]) {
    let json = decodeReply(payload, command: "nex web capture")
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

private func sendWebReplyAndPrintConsole(_ payload: [String: Any], asJSON: Bool) {
    let json = decodeReply(payload, command: "nex web console")
    let lines = (json["lines"] as? [[String: Any]]) ?? []
    if asJSON {
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let s = String(data: out, encoding: .utf8) {
            print(s)
        }
        return
    }
    if let dropped = json["dropped"] as? Int, dropped > 0 {
        fputs("(dropped \(dropped) lines before this batch — buffer was full)\n", stderr)
    }
    for line in lines {
        let seq = (line["seq"] as? UInt64) ?? 0
        let level = (line["level"] as? String) ?? "log"
        let message = (line["message"] as? String) ?? ""
        print("[\(seq)] \(level): \(message)")
    }
    if let next = json["next_since"] as? UInt64 {
        fputs("(next_since=\(next))\n", stderr)
    }
}

private func sendWebReplyAndPrintInspect(_ payload: [String: Any]) {
    let json = decodeReply(payload, command: "nex web inspect")
    let paneID = (json["pane_id"] as? String) ?? "?"
    let armed = (json["armed"] as? Bool) ?? false
    if !armed {
        print("inspect disarmed: \(paneID)")
        return
    }
    let sendTo = (json["send_to"] as? String) ?? ""
    if sendTo.isEmpty {
        print("inspect armed: \(paneID) — click an element in the web pane to capture")
    } else {
        let submit = (json["submit"] as? Bool) ?? false
        print("inspect armed: \(paneID) → will paste to \(sendTo)\(submit ? " (+submit)" : "")")
    }
}

private func sendWebReplyAndPrintInspectResult(_ payload: [String: Any], asJSON: Bool) {
    let json = decodeReply(payload, command: "nex web inspect-result")
    let results = (json["results"] as? [[String: Any]]) ?? []
    if asJSON {
        if let out = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]),
           let s = String(data: out, encoding: .utf8) {
            print(s)
        }
        return
    }
    if results.isEmpty {
        print("(no pending inspect results)")
        return
    }
    for result in results {
        let selector = (result["selector"] as? String) ?? ""
        let url = (result["url"] as? String) ?? ""
        let tag = (result["tag"] as? String) ?? ""
        print("\(tag)  \(selector)  (\(url))")
    }
}

// MARK: - web private + cookies

func handleWebCookies(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        printWebCookiesUsage(stream: stderr)
        exit(1)
    }
    if action == "-h" || action == "--help" || action == "help" {
        printWebCookiesUsage(stream: stdout)
        exit(0)
    }

    switch action {
    case "list":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let asJSON = popSwitch("--json", from: &args)
        var payload: [String: Any] = ["command": "web-cookies-list"]
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "cookies list")
        sendWebReplyAndPrintCookies(payload, asJSON: asJSON)

    case "clear":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let domain = parseFlag("--domain", from: &args)
        let all = popSwitch("--all", from: &args)
        if all, domain != nil {
            fputs("nex web cookies clear: --all and --domain are mutually exclusive\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = ["command": "web-cookies-clear"]
        if let domain { payload["domain"] = domain }
        if all { payload["all"] = true }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "cookies clear")
        sendWebReplyAndPrintCookiesClear(payload, all: all)

    case "delete":
        let target = parseFlag("--target", from: &args)
        let workspace = parseFlag("--workspace", from: &args)
        let domain = parseFlag("--domain", from: &args)
        guard let name = parseFlag("--name", from: &args) ?? args.popFirst(),
              !name.isEmpty else {
            fputs("Usage: nex web cookies delete <name> [--domain <d>] [--target X] [--workspace Y]\n", stderr)
            exit(1)
        }
        var payload: [String: Any] = [
            "command": "web-cookies-delete",
            "name": name
        ]
        if let domain { payload["domain"] = domain }
        attachWebTargetScope(&payload, target: target, workspace: workspace, command: "cookies delete")
        sendWebReplyAndPrintCookiesDelete(payload)

    default:
        fputs("Unknown cookies action: \(action)\n", stderr)
        printWebCookiesUsage(stream: stderr)
        exit(1)
    }
}

private func printWebCookiesUsage(stream: UnsafeMutablePointer<FILE>) {
    fputs("""
    Usage:
      nex web cookies list   [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--json]
      nex web cookies clear  [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--domain <d>] [--all]
      nex web cookies delete <name> [--domain <d>] [--target <name-or-uuid>] [--workspace <name-or-uuid>]

    --all on `clear` removes cookies AND caches/local storage/indexed db for
    this pane's data store. Without --domain, `clear` removes every cookie.
    \n
    """, stream)
}

/// Thin `nex web ...` wrapper over `decodeReply`: prefixes the command
/// label with "nex web " so the verb callers only pass the bare verb
/// (e.g. "private", "cookies list"). Exits non-zero with a structured
/// stderr message on transport failure, empty reply, invalid JSON, or
/// `ok:false`; returns the parsed reply on success.
private func readWebReplyOrExit(_ payload: [String: Any], command: String) -> [String: Any] {
    decodeReply(payload, command: "nex web \(command)")
}

private func sendWebReplyAndPrintPrivate(_ payload: [String: Any]) {
    let json = readWebReplyOrExit(payload, command: "private")
    let isPrivate = (json["private"] as? Bool) ?? false
    let changed = (json["changed"] as? Bool) ?? false
    let paneID = (json["pane_id"] as? String) ?? "?"
    let suffix = changed ? "" : " (no change)"
    print("private \(isPrivate ? "on" : "off"): \(paneID)\(suffix)")
}

private func sendWebReplyAndPrintCookies(_ payload: [String: Any], asJSON: Bool) {
    let json = readWebReplyOrExit(payload, command: "cookies list")
    let cookies = (json["cookies"] as? [[String: Any]]) ?? []
    if asJSON {
        if let out = try? JSONSerialization.data(withJSONObject: cookies, options: [.sortedKeys]),
           let s = String(data: out, encoding: .utf8) {
            print(s)
        }
        return
    }
    if cookies.isEmpty {
        print("(no cookies)")
        return
    }
    print("DOMAIN                     NAME                 VALUE")
    let sorted = cookies.sorted {
        let a = ($0["domain"] as? String) ?? ""
        let b = ($1["domain"] as? String) ?? ""
        if a != b { return a < b }
        return (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "")
    }
    for cookie in sorted {
        let domain = (cookie["domain"] as? String) ?? ""
        let name = (cookie["name"] as? String) ?? ""
        let value = (cookie["value"] as? String) ?? ""
        let domainClipped = domain.count > 24 ? String(domain.prefix(23)) + "…" : domain
        let nameClipped = name.count > 20 ? String(name.prefix(19)) + "…" : name
        let valueClipped = value.count > 40 ? String(value.prefix(39)) + "…" : value
        print(String(
            format: "%-26@  %-20@  %@",
            domainClipped as NSString,
            nameClipped as NSString,
            valueClipped
        ))
    }
}

private func sendWebReplyAndPrintCookiesClear(_ payload: [String: Any], all: Bool) {
    let json = readWebReplyOrExit(payload, command: "cookies clear")
    if all || (json["cleared_site_data"] as? Bool) == true {
        print("cleared all site data")
        return
    }
    let deleted = (json["deleted"] as? Int) ?? 0
    let domain = (json["domain"] as? String) ?? ""
    if domain.isEmpty {
        print("deleted \(deleted) cookie\(deleted == 1 ? "" : "s")")
    } else {
        print("deleted \(deleted) cookie\(deleted == 1 ? "" : "s") for \(domain)")
    }
}

private func sendWebReplyAndPrintCookiesDelete(_ payload: [String: Any]) {
    let json = readWebReplyOrExit(payload, command: "cookies delete")
    let deleted = (json["deleted"] as? Int) ?? 0
    let name = (json["name"] as? String) ?? "?"
    if deleted == 0 {
        print("no cookie matched name '\(name)'")
        exit(1)
    }
    print("deleted \(deleted) cookie\(deleted == 1 ? "" : "s") named '\(name)'")
}

// MARK: - pane list

func handlePaneList(_ args: inout ArraySlice<String>) {
    if args.contains("--help") || args.contains("-h") {
        printPaneListUsage(stream: stdout)
        exit(0)
    }
    let workspace = parseFlag("--workspace", from: &args)
    let currentOnly = popSwitch("--current", from: &args)
    let asJSON = popSwitch("--json", from: &args)
    let noHeader = popSwitch("--no-header", from: &args)
    // `pane list` takes no positionals; reject stray args and unknown
    // flags rather than silently ignoring them (issue #237).
    rejectLeftoverArgs(args, command: "nex pane list", usage: printPaneListUsage)

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

    let json = decodeReply(payload, command: "nex pane list")
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
/// ID (full UUID), LABEL, TYPE, WORKSPACE, STATUS, SESSION, CWD.
///
/// The pane id prints in full so it can be copy-pasted straight into
/// `--target <uuid>` — `resolvePaneTarget` only accepts a complete UUID,
/// so a truncated id was unusable as a target (issue #240). The agent
/// session id is still truncated (first 8 + last 4) since it's never a
/// `--target` and keeps the row narrower; the `--json` output keeps the
/// full value for scripts. SESSION is `-` when no agent session is
/// attached. Other fields print at their natural width with a 2-space
/// gutter.
func printPaneTable(_ panes: [[String: Any]], noHeader: Bool) {
    struct Row {
        let id: String
        let label: String
        let type: String
        let workspace: String
        let status: String
        let session: String
        let cwd: String
    }

    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""

    func shortUUID(_ value: String) -> String {
        guard value.count >= 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    let rows: [Row] = panes.map { entry in
        // Full pane UUID so it round-trips through `--target` (issue #240).
        let fullID = (entry["id"] as? String) ?? ""
        var cwd = (entry["working_directory"] as? String) ?? ""
        if !home.isEmpty, cwd.hasPrefix(home) {
            cwd = "~" + cwd.dropFirst(home.count)
        }
        let typeRaw = (entry["type"] as? String) ?? ""
        let sessionRaw = (entry["agent_session_id"] as? String) ?? ""
        return Row(
            id: fullID,
            label: (entry["label"] as? String) ?? "-",
            type: typeRaw.isEmpty ? "-" : typeRaw,
            workspace: (entry["workspace_name"] as? String) ?? "",
            status: (entry["status"] as? String) ?? "",
            session: sessionRaw.isEmpty ? "-" : shortUUID(sessionRaw),
            cwd: cwd
        )
    }

    // Compute column widths from data (and headers if shown).
    var widths = [0, 0, 0, 0, 0, 0, 0]
    let headers = ["ID", "LABEL", "TYPE", "WORKSPACE", "STATUS", "SESSION", "CWD"]
    if !noHeader {
        for (i, h) in headers.enumerated() {
            widths[i] = max(widths[i], h.count)
        }
    }
    for r in rows {
        widths[0] = max(widths[0], r.id.count)
        widths[1] = max(widths[1], r.label.count)
        widths[2] = max(widths[2], r.type.count)
        widths[3] = max(widths[3], r.workspace.count)
        widths[4] = max(widths[4], r.status.count)
        widths[5] = max(widths[5], r.session.count)
        widths[6] = max(widths[6], r.cwd.count)
    }

    func pad(_ s: String, _ w: Int) -> String {
        if s.count >= w { return s }
        return s + String(repeating: " ", count: w - s.count)
    }

    if !noHeader {
        // Last column is not padded so trailing whitespace is avoided.
        print("\(pad(headers[0], widths[0]))  \(pad(headers[1], widths[1]))  \(pad(headers[2], widths[2]))  \(pad(headers[3], widths[3]))  \(pad(headers[4], widths[4]))  \(pad(headers[5], widths[5]))  \(headers[6])")
    }
    for r in rows {
        print("\(pad(r.id, widths[0]))  \(pad(r.label, widths[1]))  \(pad(r.type, widths[2]))  \(pad(r.workspace, widths[3]))  \(pad(r.status, widths[4]))  \(pad(r.session, widths[5]))  \(r.cwd)")
    }
}

// MARK: - pane capture

func handlePaneCapture(_ args: inout ArraySlice<String>) {
    if args.contains("--help") || args.contains("-h") {
        printPaneCaptureUsage(stream: stdout)
        exit(0)
    }
    let target = parseFlag("--target", from: &args)
    let workspace = parseFlag("--workspace", from: &args)
    let linesArg = parseFlag("--lines", from: &args)
    let scrollback = popSwitch("--scrollback", from: &args)
    // The target is flag-only. Reject any stray positional or unknown
    // flag so `nex pane capture <uuid>` fails loudly instead of silently
    // falling back to capturing the calling pane (issue #237).
    rejectLeftoverArgs(
        args, command: "nex pane capture",
        positionalHint: "target panes with --target <name-or-uuid>",
        usage: printPaneCaptureUsage
    )

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

    let json = decodeReply(payload, command: "nex pane capture")
    let text = (json["text"] as? String) ?? ""
    // Write raw text without an added trailing newline — the captured
    // output usually already ends in one. Use FileHandle so binary-safe.
    if let data = text.data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func handleWorkspace(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        printWorkspaceUsage(stream: stderr)
        exit(1)
    }

    // `nex workspace --help` / `-h` / `help` prints the group overview and
    // exits 0 (before any subcommand dispatch or socket call).
    if action == "--help" || action == "-h" || action == "help" {
        printWorkspaceUsage(stream: stdout)
        exit(0)
    }

    switch action {
    case "list":
        if args.contains("--help") || args.contains("-h") {
            printWorkspaceListUsage(stream: stdout)
            exit(0)
        }
        let asJSON = popSwitch("--json", from: &args)
        let noHeader = popSwitch("--no-header", from: &args)
        rejectLeftoverArgs(args, command: "nex workspace list", usage: printWorkspaceListUsage)

        let json = decodeReply(["command": "workspace-list"], command: "nex workspace list")
        let workspaces = (json["workspaces"] as? [[String: Any]]) ?? []
        if asJSON {
            if let out = try? JSONSerialization.data(withJSONObject: workspaces, options: [.sortedKeys]),
               let string = String(data: out, encoding: .utf8) {
                print(string)
            }
            return
        }
        printWorkspaceTable(workspaces, noHeader: noHeader)

    case "create":
        if args.contains("--help") || args.contains("-h") {
            printWorkspaceCreateUsage(stream: stdout)
            exit(0)
        }
        let name = parseFlag("--name", from: &args)
        let path = parseFlag("--path", from: &args)
        let color = parseFlag("--color", from: &args)
        let group = parseFlag("--group", from: &args)
        let profile = parseFlag("--profile", from: &args)
        // Inline worktree flow (issue #222): `--worktree <name>` creates a
        // git worktree and opens the new workspace's first pane in it.
        // `--branch` defaults to the worktree name; `--repo` is the source
        // repo (defaults to the CLI's cwd); `--update-main` fetches and
        // branches off `origin/<default>`.
        let worktree = parseFlag("--worktree", from: &args)
        let branch = parseFlag("--branch", from: &args)
        let repo = parseFlag("--repo", from: &args)
        let updateMain = popSwitch("--update-main", from: &args)
        let json = popSwitch("--json", from: &args)
        // `workspace create` takes no positionals; reject stray args / unknown
        // flags instead of silently dropping them (parity with `pane create`).
        rejectLeftoverArgs(args, command: "nex workspace create", usage: printWorkspaceCreateUsage)

        var payload: [String: Any] = [
            "command": "workspace-create"
        ]
        if let name { payload["name"] = name }
        if let path { payload["path"] = path }
        if let color { payload["color"] = color }
        if let group { payload["group"] = group }
        if let profile { payload["profile"] = profile }
        if let worktree {
            payload["worktree"] = worktree
            if let branch { payload["branch"] = branch }
            if updateMain { payload["update_main"] = true }
            // Always send the source repo so the app can branch from it.
            // Default to the CLI's cwd when --repo is omitted.
            payload["repo"] = repo ?? FileManager.default.currentDirectoryPath
        }

        // Request/response (matches `pane create` / `workspace delete`):
        // returns the newly created workspace's id so scripts can chain.
        // The worktree path replies only after `git worktree add` (and, with
        // --update-main, a network `git fetch`) completes — well past the 5s
        // default. Extend the read timeout so a slow-but-succeeding create
        // isn't reported as a spurious failure (review of #222).
        let createTimeout: Int? = (worktree != nil) ? 120 : nil
        let reply = decodeReply(payload, command: "nex workspace create", readTimeoutOverride: createTimeout)
        if json {
            if let data = try? JSONSerialization.data(
                withJSONObject: reply, options: [.sortedKeys]
            ), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            let wsName = (reply["workspace_name"] as? String) ?? (name ?? "Workspace")
            let wsID = (reply["workspace_id"] as? String) ?? "?"
            if let wt = reply["worktree_path"] as? String {
                let br = (reply["branch"] as? String) ?? "?"
                let inGroup = (reply["group"] as? String).map { " in group \($0)" } ?? ""
                print("created workspace \(wsName) (\(wsID))\(inGroup) with worktree \(wt) on branch \(br)")
            } else if let grp = reply["group"] as? String {
                print("created workspace \(wsName) (\(wsID)) in group \(grp)")
            } else {
                print("created workspace \(wsName) (\(wsID))")
            }
        }

    case "move":
        if args.contains("--help") || args.contains("-h") {
            printWorkspaceMoveUsage(stream: stdout)
            exit(0)
        }
        guard let nameOrID = args.popFirst() else {
            printWorkspaceMoveUsage(stream: stderr)
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

    case "delete":
        if args.contains("--help") || args.contains("-h") {
            printWorkspaceDeleteUsage(stream: stdout)
            exit(0)
        }
        // `--force`/`-y` bypass the server's running-agents guard: without
        // it, deleting a workspace that still has active agents is refused
        // (mirrors the app-quit warning). Popped unconditionally (not
        // short-circuited) so both are consumed when passed together.
        let forceFlag = popSwitch("--force", from: &args)
        let yFlag = popSwitch("-y", from: &args)
        let force = forceFlag || yFlag
        let prune = popSwitch("--prune-worktree", from: &args)
        let json = popSwitch("--json", from: &args)

        // Everything left must be bare name-or-id targets. Reject stray
        // flags so a typo can't be silently swallowed as an id.
        let targets = Array(args)
        if let bad = targets.first(where: { $0.hasPrefix("-") }) {
            fputs("Unknown option for workspace delete: \(bad)\n", stderr)
            fputs("Usage: nex workspace delete <name-or-id> [<name-or-id> ...] [--force|-y] [--prune-worktree] [--json]\n", stderr)
            exit(1)
        }
        // Dedupe exact-duplicate ids, preserving first-seen order, so a
        // repeated argument doesn't resolve to "not found" the 2nd time.
        var seen = Set<String>()
        let ids = targets.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else {
            fputs("Usage: nex workspace delete <name-or-id> [<name-or-id> ...] [--force|-y] [--prune-worktree] [--json]\n", stderr)
            exit(1)
        }

        var results: [[String: Any]] = []
        var anyFailed = false
        for id in ids {
            let reply = decodeReplyAllowingFailure(
                ["command": "workspace-delete", "name": id, "force": force],
                command: "nex workspace delete"
            )
            let ok = (reply["ok"] as? Bool) ?? false
            let wsName = (reply["workspace_name"] as? String) ?? id
            var record: [String: Any] = ["id": id, "ok": ok]

            if ok {
                if let wsID = reply["workspace_id"] as? String { record["workspace_id"] = wsID }
                record["workspace_name"] = wsName
                let path = reply["path"] as? String
                if let path { record["path"] = path }

                if !json { print("deleted workspace \(wsName)") }

                if prune {
                    if let path {
                        let (removed, message) = pruneWorktree(path: path)
                        record["worktree_pruned"] = removed
                        if !removed { record["worktree_error"] = message }
                        if !json {
                            if removed { print("  \(message)") } else { fputs("Warning: \(message)\n", stderr) }
                        }
                    } else {
                        let message = "workspace \(wsName) had no panes; no directory to prune"
                        record["worktree_pruned"] = false
                        record["worktree_error"] = message
                        if !json { fputs("Warning: \(message)\n", stderr) }
                    }
                }
            } else {
                anyFailed = true
                let err = (reply["error"] as? String) ?? "unknown error"
                record["error"] = err
                // Surface the running-agents count from a guard refusal so
                // `--json` consumers can act on it (the human path already
                // has it in the error string).
                if let activeAgents = reply["active_agents"] as? Int {
                    record["active_agents"] = activeAgents
                }
                if !json { fputs("nex workspace delete: \(err)\n", stderr) }
            }
            results.append(record)
        }

        if json {
            // Compact single-line array to match the CLI's other
            // list-style `--json` output (pane list, graft status, etc).
            if let data = try? JSONSerialization.data(
                withJSONObject: results, options: [.sortedKeys]
            ), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        }
        if anyFailed { exit(1) }

    case "profile":
        if args.contains("--help") || args.contains("-h") {
            printWorkspaceProfileUsage(stream: stdout)
            exit(0)
        }
        guard let nameOrID = args.popFirst() else {
            printWorkspaceProfileUsage(stream: stderr)
            exit(1)
        }
        let clear = popSwitch("--clear", from: &args)
        let profile = args.popFirst()
        // Exactly one of <profile> / --clear.
        if clear == (profile != nil) {
            fputs("workspace profile requires either <profile> or --clear\n", stderr)
            exit(1)
        }
        // Reject trailing tokens — a stray word here would silently pin the
        // workspace to the wrong profile (account) with no feedback.
        if !args.isEmpty {
            fputs("workspace profile: unexpected argument(s): \(args.joined(separator: " "))\n", stderr)
            exit(1)
        }

        var payload: [String: String] = [
            "command": "workspace-profile",
            "name": nameOrID
        ]
        if let profile { payload["profile"] = profile }
        // `--clear` omits `profile` entirely — the server treats a
        // missing/empty profile as "clear the assignment".
        sendJSON(payload)

    default:
        fputs("Unknown workspace action: \(action)\n", stderr)
        fputs("Valid actions: list, create, move, delete, profile\n", stderr)
        exit(1)
    }
}

/// Render `workspace-list` as ID, NAME, GROUP, PANES, ACTIVE. Workspaces
/// keep their sidebar order; `GROUP` is `-` for top-level workspaces and
/// `ACTIVE` marks the currently focused workspace.
func printWorkspaceTable(_ workspaces: [[String: Any]], noHeader: Bool) {
    func shortUUID(_ value: String) -> String {
        guard value.count >= 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    struct Row {
        let id: String
        let name: String
        let group: String
        let panes: String
        let active: String
    }

    let rows: [Row] = workspaces.map { entry in
        Row(
            id: shortUUID((entry["id"] as? String) ?? ""),
            name: (entry["name"] as? String) ?? "",
            group: (entry["group_name"] as? String) ?? "-",
            panes: String((entry["pane_count"] as? Int) ?? 0),
            active: ((entry["is_active"] as? Bool) ?? false) ? "●" : "-"
        )
    }

    let headers = ["ID", "NAME", "GROUP", "PANES", "ACTIVE"]
    var widths = headers.map(\.count)
    for row in rows {
        widths[0] = max(widths[0], row.id.count)
        widths[1] = max(widths[1], row.name.count)
        widths[2] = max(widths[2], row.group.count)
        widths[3] = max(widths[3], row.panes.count)
    }

    func pad(_ value: String, _ width: Int) -> String {
        if value.count >= width { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    if !noHeader {
        print("\(pad(headers[0], widths[0]))  \(pad(headers[1], widths[1]))  \(pad(headers[2], widths[2]))  \(pad(headers[3], widths[3]))  \(headers[4])")
    }
    for row in rows {
        print("\(pad(row.id, widths[0]))  \(pad(row.name, widths[1]))  \(pad(row.group, widths[2]))  \(pad(row.panes, widths[3]))  \(row.active)")
    }
}

func handleGroup(_ args: inout ArraySlice<String>) {
    guard let action = args.popFirst() else {
        fputs("Usage: nex group list|create|rename|delete [...]\n", stderr)
        exit(1)
    }

    switch action {
    case "list":
        let asJSON = popSwitch("--json", from: &args)
        let noHeader = popSwitch("--no-header", from: &args)
        guard args.isEmpty else {
            fputs("Usage: nex group list [--json] [--no-header]\n", stderr)
            exit(1)
        }

        let json = decodeReply(["command": "group-list"], command: "nex group list")
        let groups = (json["groups"] as? [[String: Any]]) ?? []
        if asJSON {
            if let out = try? JSONSerialization.data(withJSONObject: groups, options: [.sortedKeys]),
               let string = String(data: out, encoding: .utf8) {
                print(string)
            }
            return
        }
        printGroupTable(groups, noHeader: noHeader)

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
        fputs("Valid actions: list, create, rename, delete\n", stderr)
        exit(1)
    }
}

/// Render `group-list` as ID, NAME, COLOR, WORKSPACES. Member workspaces
/// retain their sidebar order and display as `name (short-id)` pairs.
func printGroupTable(_ groups: [[String: Any]], noHeader: Bool) {
    struct Row {
        let id: String
        let name: String
        let color: String
        let workspaces: String
    }

    func shortUUID(_ value: String) -> String {
        guard value.count >= 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    let rows: [Row] = groups.map { entry in
        let members = (entry["workspaces"] as? [[String: Any]]) ?? []
        let memberText = members.map { member in
            let id = shortUUID((member["id"] as? String) ?? "")
            let name = (member["name"] as? String) ?? ""
            return name.isEmpty ? id : "\(name) (\(id))"
        }.joined(separator: ", ")
        return Row(
            id: shortUUID((entry["id"] as? String) ?? ""),
            name: (entry["name"] as? String) ?? "",
            color: (entry["color"] as? String) ?? "-",
            workspaces: memberText.isEmpty ? "-" : memberText
        )
    }

    let headers = ["ID", "NAME", "COLOR", "WORKSPACES"]
    var widths = headers.map(\.count)
    for row in rows {
        widths[0] = max(widths[0], row.id.count)
        widths[1] = max(widths[1], row.name.count)
        widths[2] = max(widths[2], row.color.count)
    }

    func pad(_ value: String, _ width: Int) -> String {
        if value.count >= width { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    if !noHeader {
        print("\(pad(headers[0], widths[0]))  \(pad(headers[1], widths[1]))  \(pad(headers[2], widths[2]))  \(headers[3])")
    }
    for row in rows {
        print("\(pad(row.id, widths[0]))  \(pad(row.name, widths[1]))  \(pad(row.color, widths[2]))  \(row.workspaces)")
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

private func isHelpToken(_ token: String) -> Bool {
    token == "-h" || token == "--help" || token == "help"
}

/// File extensions that route to a markdown preview pane.
private let markdownOpenExtensions: Set<String> = [
    "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "markdn"
]

/// File extensions that route to a web pane (WKWebView renders these
/// natively) as a `file://` URL.
private let webOpenExtensions: Set<String> = [
    "html", "htm", "pdf", "svg", "png", "jpg", "jpeg", "gif", "webp"
]

/// Recognised top-level domains that let `nex open` route a *bare*
/// dotted argument (`google.com`, `example.co.uk`) to a web pane. A
/// bare host with a TLD outside this set falls through to the file
/// router (use `nex web open` for obscure TLDs). Deliberately excludes
/// TLDs that collide with common file extensions (`.sh`, `.ai`,
/// `.app`, `.pl`, `.rs`, `.so`, `.cc`, `.zip`, `.mov`, `.md`, ...) so
/// `nex open run.sh` / `nex open notes.md` keep routing by file type.
/// Note: this gate applies only to the *bare dotted* case — an
/// explicit `scheme://`, a `host:port`, `localhost`, and IPv4 literals
/// route to the web regardless of TLD.
private let webOpenCommonTLDs: Set<String> = [
    // Generic
    "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz",
    "name", "pro", "io", "co", "dev", "xyz", "tech", "online", "site",
    "store", "blog", "cloud", "page", "wiki", "news", "email", "me",
    // Country / regional (common, low file-extension collision).
    // Deliberately omit `.pt` (collides with PyTorch checkpoints).
    "us", "uk", "ca", "au", "nz", "de", "fr", "es", "it", "nl", "se",
    "no", "fi", "dk", "ie", "eu", "jp", "cn", "kr", "in", "br", "mx",
    "ru", "ch", "at", "be", "za", "tv", "fm", "gg", "to", "ly",
    "id", "sg", "hk"
]

/// `nex md [--here] <file>` — dedicated markdown command. Opens (or
/// reuses, with `--here`) a markdown preview pane regardless of the
/// file's extension, so it doubles as the escape hatch for forcing a
/// markdown pane on a file `nex open` wouldn't route there.
func handleMarkdown(_ args: inout ArraySlice<String>) {
    if let first = args.first, isHelpToken(first) {
        print("Usage: nex md [--here] <filepath>")
        exit(0)
    }
    let reuse = popSwitch("--here", from: &args)
    guard let filePath = args.popFirst(), !filePath.hasPrefix("-") else {
        fputs("Usage: nex md [--here] <filepath>\n", stderr)
        exit(1)
    }
    let absolutePath = URL(fileURLWithPath: filePath).standardizedFileURL.path
    sendMarkdownOpen(absolutePath: absolutePath, reuse: reuse)
}

/// Decides whether a `nex open` argument is a URL / hostname that
/// should open in a **web pane** rather than routing by file
/// extension. Returns the string to hand to `web-open` (the server
/// normalises a bare host to `https://…`), or `nil` to fall through to
/// local-file routing.
///
/// This is the mirror image of `localFileURL(forWebArg:)`: explicit
/// paths (`/`, `./`, `../`, `~`) and existing local files stay local,
/// while a real `scheme://` URL, a `host:port`, `localhost`, an IPv4
/// literal, or a bare dotted hostname whose final label is a
/// recognised TLD (`webOpenCommonTLDs`) route to the web. A bare word
/// (`README`, `app`), a numeric-suffixed name (`backup.1`), or a
/// dotted name with an unrecognised/file-type TLD (`notes.txt`,
/// `foo.museum`) stays local — `nex web open` remains the escape hatch.
func webTargetForOpenArg(_ arg: String) -> String? {
    let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    // An explicit path or an existing local file is never a web target.
    // `localFileURL` returns non-nil for exactly those cases (and nil
    // for scheme://, host:port, localhost, and bare/dotted names).
    if localFileURL(forWebArg: trimmed) != nil { return nil }

    // Real URL with a scheme (http://, https://, file://, ...).
    if trimmed.contains("://") { return trimmed }

    // Authority = everything before the first path / query / fragment.
    let authority = trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    if authority.isEmpty { return nil }

    // Peel off an optional ":port" (all-digit tail).
    var host = String(authority)
    var hasPort = false
    if let colon = host.lastIndex(of: ":") {
        let port = host[host.index(after: colon)...]
        if !port.isEmpty, port.allSatisfy(\.isNumber) {
            hasPort = true
            host = String(host[..<colon])
        }
    }
    if host.isEmpty { return nil }

    let lowerHost = host.lowercased()

    // localhost / localhost:port.
    if lowerHost == "localhost" { return trimmed }

    // IPv4 literal (1.2.3.4), any port already peeled off above.
    let octets = lowerHost.split(separator: ".", omittingEmptySubsequences: false)
    if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && UInt8($0) != nil }) {
        return trimmed
    }

    // Any explicit host:port is a web target (a file never carries a
    // numeric port suffix).
    if hasPort { return trimmed }

    // Bare dotted hostname: route to the web only when the final label
    // is a recognised TLD. Everything else (bare words, unrecognised or
    // file-type TLDs) falls through to the file router.
    let labels = lowerHost.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
          let tld = labels.last, webOpenCommonTLDs.contains(String(tld)) else {
        return nil
    }
    return trimmed
}

/// `nex open [--here] <path-or-url>` — generic opener. A URL or
/// hostname routes to a web pane (same path as `nex web open`);
/// otherwise it routes a local file by extension:
///   - markdown (.md, ...)        → markdown preview pane
///   - web (.html, .pdf, images)  → web pane via a `file://` URL
///   - anything else              → usage error (use `nex md` or
///                                  `nex web open` explicitly)
func handleOpen(_ args: inout ArraySlice<String>) {
    if let first = args.first, isHelpToken(first) {
        print("Usage: nex open [--here] <path-or-url>")
        print("URLs & hostnames (google.com, https://…, localhost:3000) → web pane.")
        print("Local files route by type: .md/.markdown → markdown pane;")
        print(".html/.htm/.pdf/.svg and images (.png/.jpg/.gif/.webp) → web pane.")
        exit(0)
    }
    let reuse = popSwitch("--here", from: &args)
    guard let arg = args.popFirst(), !arg.hasPrefix("-") else {
        fputs("Usage: nex open [--here] <path-or-url>\n", stderr)
        exit(1)
    }

    // A URL or bare hostname → web pane, same as `nex web open`.
    if let webURL = webTargetForOpenArg(arg) {
        if reuse {
            fputs("nex open: --here is ignored for URLs (web panes always open in a new pane)\n", stderr)
        }
        sendWebOpen(url: webURL)
        return
    }

    let absoluteURL = URL(fileURLWithPath: arg).standardizedFileURL
    let absolutePath = absoluteURL.path
    let ext = absoluteURL.pathExtension.lowercased()

    if markdownOpenExtensions.contains(ext) {
        sendMarkdownOpen(absolutePath: absolutePath, reuse: reuse)
    } else if webOpenExtensions.contains(ext) {
        if reuse {
            fputs("nex open: --here is ignored for web files (web panes always open in a new pane)\n", stderr)
        }
        sendWebOpen(url: absoluteURL.absoluteString)
    } else {
        let shown = ext.isEmpty ? "files without an extension" : "'.\(ext)' files"
        fputs("nex open: don't know how to open \(shown)\n", stderr)
        fputs("       URLs & hostnames (e.g. google.com) open a web pane;\n", stderr)
        fputs("       Markdown (.md, .markdown) opens a preview pane; .html/.htm/.pdf/.svg and\n", stderr)
        fputs("       images (.png/.jpg/.gif/.webp) open a web pane.\n", stderr)
        fputs("       Use `nex md <file>` to force a markdown pane, or `nex web open <url>`.\n", stderr)
        exit(1)
    }
}

/// Shared markdown-open send used by both `nex md` and `nex open`'s
/// markdown route. Fire-and-forget `open` wire command.
private func sendMarkdownOpen(absolutePath: String, reuse: Bool) {
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

/// `nex open`'s web route — shared by the URL/hostname branch and the
/// local web-file (`file://`) branch. Opens a new web pane via the
/// same `web-open` request/response path as `nex web open`, so it
/// prints `open ok: <pane-uuid>`.
private func sendWebOpen(url: String) {
    var payload: [String: Any] = [
        "command": "web-open",
        "url": url
    ]
    if let originPaneID = ProcessInfo.processInfo.environment["NEX_PANE_ID"],
       !originPaneID.isEmpty {
        payload["pane_id"] = originPaneID
    }
    sendWebReplyAndPrintBasic(payload, command: "open")
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

    let json = decodeReply(payload, command: "nex \(command)")

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
    let json = decodeReply(payload, command: "nex graft status")
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

// MARK: - Doctor

/// `nex doctor` — run a sequence of IPC health checks and print
/// pass/fail with concrete repair tips. Added for issue #100 so users
/// have a single command to run when CLI commands stop reaching the
/// running Nex app.
///
/// Exits 0 if every check passes, non-zero if any fail. Pass `--json`
/// for a machine-readable report.
func handleDoctor(_ args: inout ArraySlice<String>) {
    let useJSON = popSwitch("--json", from: &args)

    if let extra = args.first {
        fputs("nex doctor: unexpected argument: \(extra)\n", stderr)
        fputs("Usage: nex doctor [--json]\n", stderr)
        exit(2)
    }

    var report = DoctorReport()
    report.addTransportCheck(transport: transport)
    report.addReachabilityCheck(transport: transport)
    report.addPingCheck()
    report.addProcessCheck(transport: transport)
    report.addVersionCheck(cliVersion: nexVersion)

    if useJSON {
        report.printJSON()
    } else {
        report.printHuman()
    }
    exit(report.exitCode)
}

struct DoctorCheck {
    let name: String
    let status: Status
    let detail: String
    let repair: String?

    enum Status: String {
        case pass = "PASS"
        case warn = "WARN"
        case fail = "FAIL"
        case skip = "SKIP"
    }

    func asJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "status": status.rawValue.lowercased(),
            "detail": detail
        ]
        if let repair { dict["repair"] = repair }
        return dict
    }
}

struct DoctorReport {
    private(set) var checks: [DoctorCheck] = []
    /// `pingPID` and `pingVersion` are populated by the ping check so
    /// the version / process checks downstream can reuse them.
    private var pingPID: Int?
    private var pingVersion: String?

    var exitCode: Int32 {
        checks.contains { $0.status == .fail } ? 1 : 0
    }

    mutating func append(_ check: DoctorCheck) {
        checks.append(check)
    }

    mutating func addTransportCheck(transport: Transport) {
        switch transport {
        case .unix(let path):
            append(DoctorCheck(
                name: "transport",
                status: .pass,
                detail: "Unix socket at \(path)",
                repair: nil
            ))
        case .tcp(let host, let port):
            append(DoctorCheck(
                name: "transport",
                status: .pass,
                detail: "TCP \(host):\(port) (from NEX_SOCKET)",
                repair: nil
            ))
        }
    }

    mutating func addReachabilityCheck(transport: Transport) {
        switch transport {
        case .unix(let path):
            var st = stat()
            if stat(path, &st) != 0 {
                append(DoctorCheck(
                    name: "socket",
                    status: .fail,
                    detail: "Unix socket file \(path) does not exist.",
                    repair: "Is Nex running? Launch the Nex app and re-run `nex doctor`."
                ))
            } else {
                append(DoctorCheck(
                    name: "socket",
                    status: .pass,
                    detail: "socket file exists",
                    repair: nil
                ))
            }
        case .tcp(let host, _):
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, nil, &hints, &result)
            if rc != 0 {
                append(DoctorCheck(
                    name: "resolve",
                    status: .fail,
                    detail: "cannot resolve host \"\(host)\"",
                    repair: "Check the hostname in NEX_SOCKET. From a dev container use `tcp:host.docker.internal:<port>`."
                ))
            } else {
                if result != nil { freeaddrinfo(result) }
                append(DoctorCheck(
                    name: "resolve",
                    status: .pass,
                    detail: "hostname resolves",
                    repair: nil
                ))
            }
        }
    }

    /// Round-trip `ping` over the configured transport. This is the
    /// single check that actually exercises the same dispatch path the
    /// real CLI commands use; if `ping` works and `pane list` doesn't
    /// the app is wedged in a specific reducer path rather than the
    /// socket layer.
    mutating func addPingCheck() {
        lastTransportFailure = nil
        let payload: [String: Any] = ["command": "ping"]
        // 2-second timeout — fast enough that a wedged app fails the
        // check promptly without making healthy callers wait.
        let reply = sendJSONAndReadReply(payload, readTimeoutOverride: 2)
        if reply == nil {
            // Transport failed. Emit a fail tied to the captured
            // failure category so the user gets the same repair tip
            // they would from a real failed command.
            let cmd = "nex doctor"
            let (line, repair): (String, String)
            if let f = lastTransportFailure {
                (line, repair) = describeTransportFailure(f, command: cmd)
            } else {
                line = "\(cmd): transport failure (no diagnostic captured)."
                repair = "Re-run with more verbose tooling, or restart Nex."
            }
            append(DoctorCheck(
                name: "ping",
                status: .fail,
                detail: line,
                repair: repair
            ))
            return
        }
        guard let data = reply, !data.isEmpty else {
            append(DoctorCheck(
                name: "ping",
                status: .fail,
                detail: "connected, but Nex closed the connection before replying — likely a pre-ping (<v0.26) Nex, or the app is wedged.",
                repair: "Rebuild and relaunch Nex if you're on a recent main; if `ping` still fails, restart the app."
            ))
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["ok"] as? Bool) == true
        else {
            append(DoctorCheck(
                name: "ping",
                status: .fail,
                detail: "received malformed reply (\(data.count) bytes).",
                repair: "Restart Nex. If reproducible, file an issue with the raw bytes."
            ))
            return
        }
        pingPID = json["pid"] as? Int
        pingVersion = json["version"] as? String
        append(DoctorCheck(
            name: "ping",
            status: .pass,
            detail: "round-trip ok (app pid \(pingPID.map(String.init) ?? "?"))",
            repair: nil
        ))
    }

    /// Cross-check `ping` against `pgrep` for `Nex.app`. Useful when
    /// `ping` fails — if the process is still up, the app is wedged in
    /// the reducer or main actor; if no process, Nex genuinely isn't
    /// running and the user should launch it.
    ///
    /// Skipped for TCP transport: the running Nex is on a remote host
    /// (dev container, SSH tunnel, etc.) and we can't see its process
    /// list. A FAIL here would be misleading when ping is passing.
    mutating func addProcessCheck(transport: Transport) {
        if case .tcp = transport {
            append(DoctorCheck(
                name: "process",
                status: .skip,
                detail: "skipped (TCP transport — running Nex is on a remote host).",
                repair: nil
            ))
            return
        }
        // Use `ps -axo pid,comm` rather than pgrep: on macOS, pgrep's
        // matching against argv/comm is inconsistent across sandbox
        // contexts (Claude Code's bash sandbox, login shells, agent
        // contexts), but `ps -axo` consistently lists every visible
        // process with its executable path. Filter rows where the comm
        // path ends in `Nex.app/Contents/MacOS/Nex`.
        let ps = runProcess("/bin/ps", args: ["-axo", "pid=,comm="])
        let pids: [Int] = ps.stdout
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                let pidStr = String(parts[0])
                let comm = String(parts[1])
                guard comm.hasSuffix("Nex.app/Contents/MacOS/Nex") else { return nil }
                return Int(pidStr)
            }
        if pids.isEmpty {
            append(DoctorCheck(
                name: "process",
                status: .fail,
                detail: "no running Nex.app process found",
                repair: "Launch Nex from /Applications (or wherever you installed it), then re-run `nex doctor`."
            ))
            return
        }
        if let pingPID, !pids.contains(pingPID) {
            append(DoctorCheck(
                name: "process",
                status: .warn,
                detail: "found pids \(pids), but ping replied from pid \(pingPID) — multiple Nex instances?",
                repair: "Quit the stale instances (`kill <pid>`) and keep one running."
            ))
            return
        }
        append(DoctorCheck(
            name: "process",
            status: .pass,
            detail: "Nex.app running (pids: \(pids.map(String.init).joined(separator: ", ")))",
            repair: nil
        ))
    }

    /// Compare the running app's version against the bundled CLI's
    /// version. Drift here is the usual cause of "no response from
    /// Nex (upgrade required)" — typically after a `git pull` without
    /// relaunching the app, or after copying the CLI from a different
    /// install.
    mutating func addVersionCheck(cliVersion: String) {
        guard let appVersion = pingVersion else {
            // Skip silently if ping failed; the ping fail already
            // captures the actionable bit.
            append(DoctorCheck(
                name: "version",
                status: .skip,
                detail: "skipped (ping did not return a version)",
                repair: nil
            ))
            return
        }
        if appVersion == cliVersion {
            append(DoctorCheck(
                name: "version",
                status: .pass,
                detail: "CLI \(cliVersion) matches app \(appVersion)",
                repair: nil
            ))
        } else {
            append(DoctorCheck(
                name: "version",
                status: .warn,
                detail: "CLI is \(cliVersion); app is \(appVersion).",
                repair: "Rebuild Nex (or relaunch from the latest build) so the bundled CLI matches the running app."
            ))
        }
    }

    func printHuman() {
        for c in checks {
            print("[\(c.status.rawValue)] \(c.name): \(c.detail)")
            if let r = c.repair, c.status != .pass {
                print("        → \(r)")
            }
        }
        let fails = checks.count(where: { $0.status == .fail })
        let warns = checks.count(where: { $0.status == .warn })
        if fails == 0, warns == 0 {
            print("\nAll checks passed.")
        } else {
            print("\nSummary: \(fails) fail(s), \(warns) warn(s).")
        }
    }

    func printJSON() {
        let payload: [String: Any] = [
            "ok": exitCode == 0,
            "checks": checks.map { $0.asJSON() }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        } else {
            print("{\"ok\":false,\"error\":\"failed to serialise doctor report\"}")
        }
    }
}

/// Minimal subprocess runner — captures stdout, stderr, and exit code.
/// `doctor` uses it for `ps`; `workspace delete --prune-worktree` uses
/// it to shell out to `git worktree remove` (and to resolve the
/// worktree root), surfacing git's own stderr in the warning it prints.
struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

func runProcess(_ path: String, args: [String]) -> ProcessResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    task.standardOutput = stdoutPipe
    task.standardError = stderrPipe
    do {
        try task.run()
        // Drain stdout AND stderr concurrently. The subprocess can
        // block writing to either pipe once the OS buffer fills
        // (~16 KB on macOS); a sequential drain that reads stdout
        // first deadlocks if the child writes >16 KB to stderr and
        // then exits cleanly, because the child can't close stderr
        // until the parent drains it, and the parent is blocked
        // reading stdout until the child closes that. `ps -axo` on a
        // busy workstation is in this size range so this isn't
        // theoretical.
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        group.enter()
        queue.async {
            stdoutData = stdoutHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            stderrData = stderrHandle.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        task.waitUntilExit()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return ProcessResult(stdout: stdout, stderr: stderr, exitCode: task.terminationStatus)
    } catch {
        return ProcessResult(stdout: "", stderr: "\(error.localizedDescription)", exitCode: -1)
    }
}

/// Best-effort removal of the git worktree backing a just-deleted
/// workspace (`nex workspace delete --prune-worktree`). `path` is the
/// deleted workspace's directory (a shell pane's *current* cwd); we
/// resolve it to the worktree root via `git rev-parse --show-toplevel`
/// (so a pane cwd'd into a subdirectory still works), then run
/// `git worktree remove` from the *main* worktree so git isn't invoked
/// from inside the tree it's removing. Deliberately non-forcing: git
/// refuses a dirty or locked worktree and the primary checkout, and a
/// non-repo path fails to resolve — every failure is returned as a
/// message the caller prints as a `Warning:` (git's own stderr is
/// folded in). The workspace stays deleted regardless. Returns
/// `(removed, message)`.
func pruneWorktree(path: String) -> (removed: Bool, message: String) {
    let env = "/usr/bin/env"
    let top = runProcess(env, args: ["git", "-C", path, "rev-parse", "--show-toplevel"])
    guard top.exitCode == 0 else {
        let detail = top.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, "not a git worktree, skipped prune: \(path)" + (detail.isEmpty ? "" : " (\(detail))"))
    }
    let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    // Resolve the main worktree so `git worktree remove` runs from
    // outside the target. `--git-common-dir` is `<main>/.git`; its
    // parent is the main worktree. Fall back to the root itself if the
    // lookup fails (older git / unusual layout).
    let common = runProcess(env, args: ["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    let runDir: String
    if common.exitCode == 0 {
        let commonDir = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        runDir = (commonDir as NSString).deletingLastPathComponent
    } else {
        runDir = root
    }

    let remove = runProcess(env, args: ["git", "-C", runDir, "worktree", "remove", root])
    if remove.exitCode == 0 {
        return (true, "removed worktree: \(root)")
    }
    let detail = remove.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return (false, "git worktree remove failed for \(root)" + (detail.isEmpty ? "" : ": \(detail)"))
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
case "md":
    handleMarkdown(&args)
case "diff":
    handleDiff(&args)
case "graft":
    handleGraft(&args)
case "web":
    handleWeb(&args)
case "doctor":
    handleDoctor(&args)
default:
    fputs("Unknown command: \(subcommand)\n", stderr)
    printUsage()
    exit(1)
}
