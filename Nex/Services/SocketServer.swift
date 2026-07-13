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
    /// A Claude Code session ended (SessionEnd hook: the agent process
    /// exited, the user logged out, or `/clear` retired the old id).
    /// Carries the ending `sessionID` so the reducer only clears the
    /// pane's tracked id when it still matches — see `sessionEnded`
    /// in `WorkspaceFeature`. Excluded from the session_id dual-fire
    /// in `parseMessagesWithCommands` so it can't re-attach the id it
    /// is meant to drop.
    case sessionEnded(paneID: UUID, sessionID: String)
    // Pane commands
    case paneSplit(paneID: UUID?, direction: PaneLayout.SplitDirection?, path: String?, name: String?, target: String?, workspace: String?)
    case paneCreate(paneID: UUID?, path: String?, name: String?, target: String?, workspace: String?)
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
    case paneName(paneID: UUID?, target: String?, workspace: String?, name: String)
    /// Send keystrokes to a pane resolved by `target` (label or UUID).
    /// Label lookups default to the sender's own workspace; pass
    /// `workspace` (name-or-UUID) to address a pane in another workspace
    /// or to disambiguate when the same label is reused across
    /// workspaces. The reducer replies with a structured success/error
    /// payload (request/response — see `replyCommandAllowlist`).
    /// `bare` = true → write `text` to the PTY without the trailing
    /// Enter keystroke `pane send` normally appends. Pair with
    /// `paneSendKey` to compose multi-step interactive input
    /// (e.g. `pane send --bare "ls /tm"` then `pane send-key tab`
    /// to trigger autocomplete). Default false preserves the
    /// pre-#98 contract.
    case paneSend(paneID: UUID?, target: String, text: String, workspace: String?, bare: Bool)
    /// Send a single named keystroke (Enter, Tab, Escape, ...) to a
    /// pane resolved by `target`. `key` is one of the names in
    /// `GhosttySurface.namedKeyAliases`. `paneID` is optional (mirrors
    /// `pane-close` / `pane-capture`) so external scripts without a
    /// `NEX_PANE_ID` can still address a pane by UUID or by label
    /// when paired with `--workspace`. Workspace scoping mirrors
    /// `paneSend`. Reply contract is the same: structured success or
    /// `{ok:false,error:...}` (issue #98).
    case paneSendKey(paneID: UUID?, target: String, key: String, workspace: String?)
    case paneMove(paneID: UUID, direction: PaneLayout.Direction)
    case paneMoveToWorkspace(paneID: UUID, toWorkspace: String, create: Bool)
    /// Workspace commands
    case workspaceList
    // `worktree` (issue #222): when non-nil, create a git worktree named
    // this and open the new workspace's first pane in it. `branch` is the
    // branch name (defaults to `worktree`); `updateMain` fetches + branches
    // off `origin/<default>`; `repo` is the source repo path (defaults to
    // the CLI's cwd, always sent by the CLI when `worktree` is set).
    case workspaceCreate(name: String?, path: String?, color: WorkspaceColor?, group: String?, profile: String? = nil, worktree: String? = nil, branch: String? = nil, updateMain: Bool = false, repo: String? = nil)
    case workspaceMove(nameOrID: String, group: String?, index: Int?)
    /// Delete a single workspace by name-or-id. Request/response
    /// (`replyCommandAllowlist`) — the CLI loops one request per id for
    /// bulk `nex workspace delete a b c`, and reads back the deleted
    /// workspace's directory so `--prune-worktree` can remove it.
    /// `force` (from `--force`/`-y`) bypasses the running-agents guard:
    /// without it, deleting a workspace that still has active agents is
    /// refused (mirrors the app-quit warning).
    case workspaceDelete(nameOrID: String, force: Bool)
    /// `nex workspace profile <name-or-id> (<profile> | --clear)`.
    /// `profile` nil = clear. Fire-and-forget (matches `workspace-move`).
    case workspaceProfile(nameOrID: String, profile: String?)
    /// Group commands. Icon-setting is deliberately UI-only: the
    /// curated palette + emoji picker lives in the context menu.
    case groupList
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
    /// Read another pane's terminal contents as plain text. `paneID`
    /// comes from `NEX_PANE_ID` (no-flag form); `target` carries
    /// `--target <name-or-uuid>`. `workspace` narrows label resolution.
    /// `lines` caps the output to the last N lines after read; `scrollback`
    /// extends the read region from the visible viewport to the full screen.
    /// Replies with `{"ok":true,"text":"..."}` or `{"ok":false,"error":...}`
    /// (request/response — see `replyCommandAllowlist`).
    case paneCapture(paneID: UUID?, target: String?, workspace: String?, lines: Int?, includeScrollback: Bool)
    /// `nex pane sync (on|off|toggle|status)` (issue #121).
    /// `action` is one of `"on"`, `"off"`, `"toggle"`, `"status"`.
    /// `paneID` (from `NEX_PANE_ID`) scopes the request to the
    /// caller's workspace when `workspace` is unset. `status` is
    /// read-only and never mutates state. Request/response — see
    /// `replyCommandAllowlist`.
    case paneSync(paneID: UUID?, workspace: String?, action: String)
    /// `nex pane sync exclude|include` — adjust the per-workspace
    /// exclusion set. `target` resolves a pane via the same rules as
    /// `paneSend` / `paneClose` (label or UUID, with `--workspace`
    /// scoping for labels). Idempotent: excluding an already-excluded
    /// pane (or vice versa) is a no-op success.
    case paneSyncExclude(paneID: UUID?, target: String, workspace: String?, excluded: Bool)
    /// `nex graft start` — begin worktree-to-root mirroring. `paneID`
    /// comes from `NEX_PANE_ID` and scopes resolution to the caller's
    /// workspace when neither `workspace` nor `repo` is supplied.
    /// Request/response — see `replyCommandAllowlist`.
    case graftStart(workspace: String?, repo: String?, paneID: UUID?)
    /// `nex graft stop` — stop active sessions in scope.
    case graftStop(workspace: String?, repo: String?, paneID: UUID?)
    /// `nex graft status` — list active sessions across all workspaces.
    case graftStatus

    /// `nex ping` — IPC health check. Request/response. Replies with
    /// `{"ok":true,"version":"<short>","build":"<build>","pid":<n>}`
    /// where `version` is `CFBundleShortVersionString` and `build` is
    /// `CFBundleVersion`. Used by `nex doctor` to verify the running
    /// app can dispatch socket commands round-trip, and as a cheap
    /// version probe so the CLI can warn when the installed binary
    /// and the running app drift.
    case ping

    // Web pane commands (Phase 1). `web` is a first-class top-level
    // CLI verb (not a `pane` subcommand), so the wire names follow
    // suit: `web-open` / `web-url` / etc.

    /// Open a new `.web` pane with the given URL. `paneID` (from
    /// `NEX_PANE_ID`) is informational; opening always creates a new
    /// pane in the active workspace, mirroring `nex diff`.
    case webOpen(paneID: UUID?, url: String, isPrivate: Bool)
    /// Navigate the active tab of the resolved web pane to `url`.
    /// Companion to `webOpen` for the "reuse an existing pane" case;
    /// for "new tab" callers use `webTabNew` instead.
    case webNavigate(paneID: UUID?, target: String?, workspace: String?, url: String)
    /// Read the active tab's current URL + title for the resolved pane.
    case webURL(paneID: UUID?, target: String?, workspace: String?)
    case webBack(paneID: UUID?, target: String?, workspace: String?)
    case webForward(paneID: UUID?, target: String?, workspace: String?)
    case webReload(paneID: UUID?, target: String?, workspace: String?, hard: Bool)
    /// `mode` is one of `meta`, `text`, `screenshot`. `meta` is the
    /// cheap default — URL + title + byte counts; `text` returns the
    /// visible page text; `screenshot` returns a PNG (inline base64
    /// under 1 MB, else a `/tmp` path).
    case webCapture(paneID: UUID?, target: String?, workspace: String?, mode: String)

    // Tab commands

    /// List the open tabs of the resolved web pane.
    case webTabs(paneID: UUID?, target: String?, workspace: String?)
    /// Open a new tab in the resolved web pane. `url` may be empty
    /// (blank tab). `makeActive` defaults to true.
    case webTabNew(paneID: UUID?, target: String?, workspace: String?, url: String, makeActive: Bool)
    /// Close a tab. `tabRef` is either a tab UUID or a numeric index.
    /// Resolving to the only tab in the pane returns `{ok:false}`
    /// rather than implicitly closing the pane — callers can use
    /// `pane close` for that.
    case webTabClose(paneID: UUID?, target: String?, workspace: String?, tabRef: String)
    case webTabSelect(paneID: UUID?, target: String?, workspace: String?, tabRef: String)

    // Phase 3 — console + inspector

    /// Drain the console ring buffer of the resolved web pane.
    /// `since` is the last seq the caller has already seen (0 = full
    /// buffer). `level` filters to a single severity. `clear` empties
    /// the buffer after the read so the next call starts fresh.
    case webConsole(
        paneID: UUID?, target: String?, workspace: String?,
        since: UInt64, level: String?, clear: Bool
    )
    /// Arm the picker for the resolved pane's active tab. `sendTo`
    /// is an optional pane target (label or UUID) into which the
    /// next click's payload gets pasted. `submit` controls whether
    /// the paste ends with an Enter keystroke (default: false).
    /// `disarm` disarms an existing arm without picking.
    case webInspect(
        paneID: UUID?, target: String?, workspace: String?,
        sendTo: String?, submit: Bool, disarm: Bool
    )
    /// Drain the per-pane inspect-result queue without arming.
    case webInspectResult(
        paneID: UUID?, target: String?, workspace: String?, clear: Bool
    )

    // Phase 5 — private mode + cookies

    /// Set the resolved web pane's private mode flag. The reducer
    /// destroys the coordinator so the host rebuilds tabs against
    /// the new data store. Idempotent.
    case webPrivate(
        paneID: UUID?, target: String?, workspace: String?, enabled: Bool
    )
    /// List cookies for the resolved web pane's data store, grouped
    /// by domain. Read-only.
    case webCookiesList(paneID: UUID?, target: String?, workspace: String?)
    /// Drop cookies (and other site data when `--all`) for the
    /// resolved web pane's data store. `domain` scopes deletion to
    /// cookies whose domain matches; omitting it clears everything.
    case webCookiesClear(
        paneID: UUID?, target: String?, workspace: String?,
        domain: String?, all: Bool
    )
    /// Delete cookies matching `name` (and optional `domain` scope)
    /// from the resolved web pane's data store.
    case webCookiesDelete(
        paneID: UUID?, target: String?, workspace: String?,
        name: String, domain: String?
    )

    // Actuator commands (Phase B) — semantic verbs over the in-page
    // `window.__nexAct` namespace.

    /// `nex web click <selector> [--double] [--right] [--at x,y]` —
    /// synthesise a pointer+mouse click sequence on the first element
    /// matching `selector`.
    case webClick(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String, double: Bool, right: Bool, atX: Double?, atY: Double?
    )
    /// `nex web type <selector> <text> [--submit] [--no-replace]` —
    /// set the value of a typable element via the prototype native
    /// setter and dispatch input + change events. Optional Enter
    /// keystroke + form.requestSubmit when `submit` is true.
    case webType(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String, text: String, submit: Bool, replace: Bool
    )

    // Actuator read verbs (Phase C). Wire keys are prefixed `web-q-`
    // (q for query) so future allowlist tuning + audit grep can
    // distinguish reads from actions at a glance.

    /// `nex web text <selector> [--max-bytes N]`.
    case webQText(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String, maxBytes: Int?
    )
    /// `nex web attr <selector> <attribute>`.
    case webQAttr(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String, attribute: String
    )
    /// `nex web count <selector>` — number of smallest-enclosing
    /// matches.
    case webQCount(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String
    )
    /// `nex web exists <selector>` — boolean. CLI exits 0/1 from the
    /// `found` field rather than the `ok` flag.
    case webQExists(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String
    )
    /// `nex web dom <selector> [--max-bytes N]` — outerHTML.
    case webQDom(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String, maxBytes: Int?
    )

    /// `nex web wait` — server-side polling (Phase D). Exactly one of
    /// `selector` / `urlMatch` is required at the server; the CLI
    /// enforces this client-side, so a wire payload with neither
    /// reaches the JS-side validator and surfaces a structured error.
    ///
    /// `forCondition` is the literal `--for` token (`visible`,
    /// `hidden`, `exists`, `count=N`, `text=X`, `url-match`); the JS
    /// side parses the `count=N`/`text=X` suffix.
    case webWait(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String?, urlMatch: String?,
        forCondition: String?, timeoutMs: Int
    )

    // Actuator long-tail verbs (Phase E).

    /// `nex web select <selector> <value-or-label>` — set the value
    /// of a `<select>` element. Matches options by `value` first,
    /// then by visible label.
    case webSelect(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String, valueOrLabel: String
    )
    /// `nex web scroll <selector> [--top|--bottom|--smooth]` —
    /// `block` is one of `start`/`center`/`end`; `behavior` is
    /// `instant` or `smooth`. CLI flags map to these directly.
    case webScroll(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String, block: String, behavior: String
    )
    /// `nex web hover <selector>` — synthetic hover.
    case webHover(
        paneID: UUID?, target: String?, workspace: String?,
        selector: String
    )
    /// `nex web key <key-name> [--selector <sel>]` — dispatch a
    /// named keystroke to `selector` (or `document.activeElement`
    /// when `selector` is nil).
    case webKey(
        paneID: UUID?, target: String?, workspace: String?,
        keyName: String, selector: String?
    )

    /// `nex web exec` — author JS evaluated inside an async IIFE with
    /// `$`/`$$`/`nex` aliases bound to the actuator.
    case webExec(
        paneID: UUID?, target: String?, workspace: String?,
        script: String
    )
}

/// Commands that expect a single-line JSON reply followed by EOF. For any
/// command outside this allowlist the server does not allocate a
/// `ReplyHandle` and the wire behaviour is byte-identical to the
/// pre-request/response protocol.
private let replyCommandAllowlist: Set<String> = [
    "workspace-list", "group-list",
    "pane-list", "pane-close", "pane-capture", "pane-send", "pane-send-key",
    "pane-split", "pane-create", "pane-name",
    "pane-sync", "pane-sync-exclude",
    "workspace-create", "workspace-delete",
    "graft-start", "graft-stop", "graft-status",
    "ping",
    "web-open", "web-navigate", "web-url", "web-back",
    "web-forward", "web-reload", "web-capture",
    "web-tabs", "web-tab-new", "web-tab-close", "web-tab-select",
    "web-console", "web-inspect", "web-inspect-result",
    "web-private", "web-cookies-list", "web-cookies-clear", "web-cookies-delete",
    "web-click", "web-type",
    "web-q-text", "web-q-attr", "web-q-count", "web-q-exists", "web-q-dom",
    "web-wait",
    "web-select", "web-scroll", "web-hover", "web-key",
    "web-exec"
]

/// Unix domain socket server that listens for structured JSON messages
/// from the `nex` CLI tool. Agent hooks (Claude Code, Codex)
/// fire `nex` which sends events here.
///
/// Wire format (newline-terminated JSON):
/// ```
/// {"command":"stop","pane_id":"<uuid>"}\n
/// {"command":"error","pane_id":"<uuid>","message":"..."}\n
/// {"command":"pane-split","pane_id":"<uuid>","direction":"horizontal"}\n
/// {"command":"pane-capture","target":"worker","lines":50}\n
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

        /// Convenience for the common reply path: send then close.
        func sendAndClose(_ json: [String: Any]) {
            sendImpl(json)
            closeImpl()
        }

        /// Convenience for the common error path: send `{ok:false,error:...}`
        /// then close.
        func error(_ message: String) {
            sendImpl(["ok": false, "error": message])
            closeImpl()
        }

        /// Identity compare on id only - the closures aren't comparable
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
        /// `pane-send-key` — name of the keystroke to deliver
        /// (e.g. "enter", "tab"). See `GhosttySurface.namedKeyAliases`.
        var key: String?
        /// `pane-send` — when true, write text without appending Enter.
        var bare: Bool?
        // Group/workspace-management fields
        var newName: String?
        var cascade: Bool?
        /// `workspace-delete --force`/`-y` — bypass the running-agents guard.
        var force: Bool?
        var index: Int?
        var group: String?
        /// `workspace-create --profile` / `workspace-profile` — the
        /// workspace-profile name to assign (empty = clear).
        var profile: String?
        // Request/response — `pane-list` filters
        var workspace: String?
        var scope: String?
        /// `nex open --here` → replace originating pane in place.
        var reuse: Bool?
        /// `nex diff` — repo root and optional file/directory scope.
        var repoPath: String?
        var targetPath: String?
        /// `pane-capture` filters
        var lines: Int?
        var scrollback: Bool?
        /// `graft-start` / `graft-stop` — repo name or path scope.
        var repo: String?
        /// `web-open` / `web-url` etc. — destination URL or
        /// (for capture) the visible-text/screenshot/meta mode.
        var url: String?
        var mode: String?
        /// `web-reload --hard`.
        var hard: Bool?
        /// `web-tab-close` / `web-tab-select` — tab UUID or numeric
        /// index. Parser keeps it as a raw string; the reducer
        /// resolves to a concrete UUID by trying UUID(uuidString:)
        /// first, then Int parsing for index.
        var tab: String?
        /// `web-tab-new --no-focus` → false.
        var makeActive: Bool?
        /// `web-console --since`. Default 0 = full buffer.
        var since: UInt64?
        /// `web-console --level`. Optional severity filter.
        var level: String?
        /// `web-console --clear`, `web-inspect-result --clear`.
        var clear: Bool?
        /// `web-inspect --send-to <pane-target>`.
        var sendTo: String?
        /// `web-inspect --submit`. Default false (paste only).
        var submit: Bool?
        /// `web-inspect --disarm`.
        var disarm: Bool?
        /// `web-open --private`, `web-private on|off`. Treated as a
        /// tri-state on `web-open` (nil = no flag → default false);
        /// `web-private` requires it.
        var isPrivate: Bool?
        /// `web-cookies-*` — RFC 6265 domain. Optional on clear,
        /// optional on delete (scopes to a single host when present).
        var domain: String?
        /// `web-cookies-clear --all` extends deletion to caches +
        /// local storage + indexed db.
        var all: Bool?
        /// `web-click` / `web-type` — actuator selector string. Raw
        /// (`css:`/`text:`/`role:`/auto-detect); the JS side parses.
        var selector: String?
        /// `web-click --double`.
        var double: Bool?
        /// `web-click --right`.
        var right: Bool?
        /// `web-click --at x,y` — element-local offsets. Both must be
        /// present to apply; otherwise the centre of the bounding box
        /// is used.
        var atX: Double?
        var atY: Double?
        /// `web-type --no-replace` → false. When omitted the typed
        /// text replaces existing content (matches Playwright `fill`).
        var replace: Bool?
        /// `web-q-text` / `web-q-dom` — byte-budget cap. nil = JS default.
        var maxBytes: Int?
        /// `web-q-attr` — attribute name to read.
        var attribute: String?
        /// `web-wait` — match condition. Literal value of the `--for`
        /// flag (visible, hidden, exists, count=N, text=X, url-match).
        /// JS-side parses count=/text= suffixes.
        var forCondition: String?
        /// `web-wait --url-match` — substring or /regex/flags.
        var urlMatch: String?
        /// `web-wait --timeout` (milliseconds). 0 / nil → JS default 10000.
        var timeoutMs: Int?
        /// `web-select` — option value or visible label.
        var valueOrLabel: String?
        /// `web-scroll` — scrollIntoView block: start|center|end.
        var block: String?
        /// `web-scroll` — scrollIntoView behavior: instant|smooth.
        var behavior: String?
        /// `web-exec` — author-supplied JS body.
        var script: String?
        /// `pane-sync` — one of `on`, `off`, `toggle`, `status`.
        var action: String?
        /// `pane-sync-exclude` — true to exclude the target pane,
        /// false to re-include. Required for that command.
        var excluded: Bool?
        /// `workspace-create --worktree <name>` (issue #222) — the worktree
        /// / branch folder name to create and open the first pane in.
        var worktree: String?
        /// `workspace-create --branch <name>` — branch name for the new
        /// worktree (defaults to `worktree` when omitted).
        var branch: String?
        /// `workspace-create --update-main` — fetch + branch the worktree
        /// off `origin/<default>` rather than the current HEAD.
        var updateMain: Bool?

        enum CodingKeys: String, CodingKey {
            case command
            case paneID = "pane_id"
            case message, title, body
            case sessionID = "session_id"
            case direction, path, name, color, target, text, key, bare
            case newName = "new_name"
            case cascade, force, index, group, profile
            case workspace, scope
            case reuse
            case repoPath = "repo_path"
            case targetPath = "target_path"
            case lines, scrollback
            case repo
            case url, mode, hard
            case tab
            case makeActive = "make_active"
            case since, level, clear
            case sendTo = "send_to"
            case submit, disarm
            case isPrivate = "private"
            case domain, all
            case selector, double, right
            case atX = "at_x"
            case atY = "at_y"
            case replace
            case maxBytes = "max_bytes"
            case attribute
            case forCondition = "for"
            case urlMatch = "url_match"
            case timeoutMs = "timeout_ms"
            case valueOrLabel = "value_or_label"
            case block, behavior
            case script
            case action, excluded
            case worktree, branch
            case updateMain = "update_main"
        }
    }

    /// Shared scope extraction for pane-addressing commands (the
    /// `pane-*` and `web-*` families). They all follow the same shape
    /// on the wire (paneID from NEX_PANE_ID and/or --target with
    /// optional --workspace) and reject when neither paneID nor target
    /// is present. Commands whose `target` is mandatory guard the
    /// returned optional `target` at the call site; commands that
    /// accept `workspace` alone as an anchor (pane-split / pane-create)
    /// do their own extraction and don't use this helper.
    private static func parsePaneTarget(
        _ wire: WireMessage
    ) -> (paneID: UUID?, target: String?, workspace: String?)? {
        let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
        let target = (wire.target?.isEmpty == true) ? nil : wire.target
        let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
        guard paneID != nil || target != nil else { return nil }
        return (paneID, target, workspace)
    }

    /// Parse a single JSON message into a (SocketMessage, WireMessage) tuple.
    /// Returns nil if the data is invalid or the command is unrecognized.
    static func parseWireMessage(_ data: Data) -> (SocketMessage, WireMessage)? {
        guard let wire = try? JSONDecoder().decode(WireMessage.self, from: data) else { return nil }

        // workspace-create, workspace-move, group-*, open don't
        // require pane_id.
        if wire.command == "workspace-create" {
            let color = wire.color.flatMap { WorkspaceColor(rawValue: $0) }
            // Empty-string profile is normalised to nil (= no profile);
            // `.setProfile` normalises again as the backstop.
            let profile = (wire.profile?.isEmpty == true) ? nil : wire.profile
            // Worktree fields (issue #222). Empty strings normalise to nil so
            // a serialised-but-unset field can't accidentally trigger the
            // worktree path or an empty branch name.
            let worktree = (wire.worktree?.isEmpty == true) ? nil : wire.worktree
            let branch = (wire.branch?.isEmpty == true) ? nil : wire.branch
            let repo = (wire.repo?.isEmpty == true) ? nil : wire.repo
            return (.workspaceCreate(
                name: wire.name,
                path: wire.path,
                color: color,
                group: wire.group,
                profile: profile,
                worktree: worktree,
                branch: branch,
                updateMain: wire.updateMain ?? false,
                repo: repo
            ), wire)
        }

        if wire.command == "workspace-list" {
            return (.workspaceList, wire)
        }

        if wire.command == "workspace-move" {
            guard let nameOrID = wire.name, !nameOrID.isEmpty else { return nil }
            // `group` nil = top-level; empty-string is normalised to
            // nil so callers that serialise a cleared field don't
            // accidentally target a group with an empty name.
            let group = (wire.group?.isEmpty == true) ? nil : wire.group
            return (.workspaceMove(nameOrID: nameOrID, group: group, index: wire.index), wire)
        }

        if wire.command == "workspace-delete" {
            guard let nameOrID = wire.name, !nameOrID.isEmpty else { return nil }
            return (.workspaceDelete(nameOrID: nameOrID, force: wire.force ?? false), wire)
        }

        if wire.command == "workspace-profile" {
            guard let nameOrID = wire.name, !nameOrID.isEmpty else { return nil }
            // Empty/missing profile = clear the assignment.
            let profile = (wire.profile?.isEmpty == true) ? nil : wire.profile
            return (.workspaceProfile(nameOrID: nameOrID, profile: profile), wire)
        }

        if wire.command == "group-list" {
            return (.groupList, wire)
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
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.paneClose(paneID: scope.paneID, target: scope.target, workspace: scope.workspace), wire)
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

        if wire.command == "pane-capture" {
            // Mirrors `pane-close`: at least one of `pane_id` / `target` must
            // be present; the reducer resolves `target` to a concrete pane.
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.paneCapture(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                lines: wire.lines,
                includeScrollback: wire.scrollback ?? false
            ), wire)
        }

        if wire.command == "graft-start" {
            let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
            let repo = (wire.repo?.isEmpty == true) ? nil : wire.repo
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            return (.graftStart(workspace: workspace, repo: repo, paneID: paneID), wire)
        }

        if wire.command == "graft-stop" {
            let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
            let repo = (wire.repo?.isEmpty == true) ? nil : wire.repo
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            return (.graftStop(workspace: workspace, repo: repo, paneID: paneID), wire)
        }

        if wire.command == "graft-status" {
            return (.graftStatus, wire)
        }

        if wire.command == "ping" {
            return (.ping, wire)
        }

        if wire.command == "web-open" {
            guard let url = wire.url, !url.isEmpty else { return nil }
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            return (.webOpen(paneID: paneID, url: url, isPrivate: wire.isPrivate ?? false), wire)
        }

        if wire.command == "web-navigate" {
            guard let scope = parsePaneTarget(wire),
                  let url = wire.url, !url.isEmpty else { return nil }
            return (.webNavigate(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                url: url
            ), wire)
        }

        if wire.command == "web-url" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webURL(paneID: scope.paneID, target: scope.target, workspace: scope.workspace), wire)
        }

        if wire.command == "web-back" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webBack(paneID: scope.paneID, target: scope.target, workspace: scope.workspace), wire)
        }

        if wire.command == "web-forward" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webForward(paneID: scope.paneID, target: scope.target, workspace: scope.workspace), wire)
        }

        if wire.command == "web-reload" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webReload(
                paneID: scope.paneID, target: scope.target, workspace: scope.workspace,
                hard: wire.hard ?? false
            ), wire)
        }

        if wire.command == "web-capture" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            let mode = (wire.mode?.isEmpty == true) ? "meta" : (wire.mode ?? "meta")
            return (.webCapture(
                paneID: scope.paneID, target: scope.target, workspace: scope.workspace, mode: mode
            ), wire)
        }

        if wire.command == "web-tabs" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webTabs(paneID: scope.paneID, target: scope.target, workspace: scope.workspace), wire)
        }

        if wire.command == "web-tab-new" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webTabNew(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                url: wire.url ?? "",
                makeActive: wire.makeActive ?? true
            ), wire)
        }

        if wire.command == "web-tab-close" {
            guard let scope = parsePaneTarget(wire),
                  let tabRef = wire.tab, !tabRef.isEmpty else { return nil }
            return (.webTabClose(
                paneID: scope.paneID, target: scope.target, workspace: scope.workspace, tabRef: tabRef
            ), wire)
        }

        if wire.command == "web-tab-select" {
            guard let scope = parsePaneTarget(wire),
                  let tabRef = wire.tab, !tabRef.isEmpty else { return nil }
            return (.webTabSelect(
                paneID: scope.paneID, target: scope.target, workspace: scope.workspace, tabRef: tabRef
            ), wire)
        }

        if wire.command == "web-console" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webConsole(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                since: wire.since ?? 0,
                level: (wire.level?.isEmpty == true) ? nil : wire.level,
                clear: wire.clear ?? false
            ), wire)
        }

        if wire.command == "web-inspect" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webInspect(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                sendTo: (wire.sendTo?.isEmpty == true) ? nil : wire.sendTo,
                submit: wire.submit ?? false,
                disarm: wire.disarm ?? false
            ), wire)
        }

        if wire.command == "web-inspect-result" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webInspectResult(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                clear: wire.clear ?? false
            ), wire)
        }

        if wire.command == "web-private" {
            guard let scope = parsePaneTarget(wire),
                  let enabled = wire.isPrivate else { return nil }
            return (.webPrivate(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                enabled: enabled
            ), wire)
        }

        if wire.command == "web-cookies-list" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webCookiesList(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace
            ), wire)
        }

        if wire.command == "web-cookies-clear" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            return (.webCookiesClear(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                domain: (wire.domain?.isEmpty == true) ? nil : wire.domain,
                all: wire.all ?? false
            ), wire)
        }

        if wire.command == "web-cookies-delete" {
            guard let scope = parsePaneTarget(wire),
                  let name = wire.name, !name.isEmpty else { return nil }
            return (.webCookiesDelete(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                name: name,
                domain: (wire.domain?.isEmpty == true) ? nil : wire.domain
            ), wire)
        }

        if wire.command == "web-click" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty else { return nil }
            return (.webClick(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                double: wire.double ?? false,
                right: wire.right ?? false,
                atX: wire.atX,
                atY: wire.atY
            ), wire)
        }

        if wire.command == "web-type" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty,
                  let text = wire.text else { return nil }
            return (.webType(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                text: text,
                submit: wire.submit ?? false,
                replace: wire.replace ?? true
            ), wire)
        }

        if wire.command == "web-q-text" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty else { return nil }
            return (.webQText(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                maxBytes: wire.maxBytes
            ), wire)
        }

        if wire.command == "web-q-attr" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty,
                  let attribute = wire.attribute, !attribute.isEmpty else { return nil }
            return (.webQAttr(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                attribute: attribute
            ), wire)
        }

        if wire.command == "web-q-count" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty else { return nil }
            return (.webQCount(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector
            ), wire)
        }

        if wire.command == "web-q-exists" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty else { return nil }
            return (.webQExists(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector
            ), wire)
        }

        if wire.command == "web-q-dom" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty else { return nil }
            return (.webQDom(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                maxBytes: wire.maxBytes
            ), wire)
        }

        if wire.command == "web-select" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty,
                  let valueOrLabel = wire.valueOrLabel else { return nil }
            return (.webSelect(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                valueOrLabel: valueOrLabel
            ), wire)
        }

        if wire.command == "web-scroll" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty else { return nil }
            let block = wire.block.flatMap { $0.isEmpty ? nil : $0 } ?? "center"
            let behavior = wire.behavior.flatMap { $0.isEmpty ? nil : $0 } ?? "instant"
            return (.webScroll(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                block: block,
                behavior: behavior
            ), wire)
        }

        if wire.command == "web-hover" {
            guard let scope = parsePaneTarget(wire),
                  let selector = wire.selector, !selector.isEmpty else { return nil }
            return (.webHover(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector
            ), wire)
        }

        if wire.command == "web-key" {
            guard let scope = parsePaneTarget(wire),
                  let keyName = wire.key, !keyName.isEmpty else { return nil }
            let selector = (wire.selector?.isEmpty == true) ? nil : wire.selector
            return (.webKey(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                keyName: keyName,
                selector: selector
            ), wire)
        }

        if wire.command == "web-exec" {
            guard let scope = parsePaneTarget(wire),
                  let script = wire.script, !script.isEmpty else { return nil }
            return (.webExec(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                script: script
            ), wire)
        }

        if wire.command == "web-wait" {
            guard let scope = parsePaneTarget(wire) else { return nil }
            let selector = (wire.selector?.isEmpty == true) ? nil : wire.selector
            let urlMatch = (wire.urlMatch?.isEmpty == true) ? nil : wire.urlMatch
            // Exactly one of selector / urlMatch must be present. The
            // CLI catches both-missing and both-present before sending,
            // but the wire validates too so misuse from other clients
            // surfaces as a clean rejection — otherwise both-present
            // would silently pick whichever the JS default rule lands
            // on, ignoring the other field.
            switch (selector, urlMatch) {
            case (nil, nil), (.some, .some): return nil
            default: break
            }
            let forCondition = (wire.forCondition?.isEmpty == true)
                ? nil : wire.forCondition
            // 0/nil flows through; the JS `wait` body owns the default.
            let timeoutMs = wire.timeoutMs ?? 0
            return (.webWait(
                paneID: scope.paneID,
                target: scope.target,
                workspace: scope.workspace,
                selector: selector,
                urlMatch: urlMatch,
                forCondition: forCondition,
                timeoutMs: timeoutMs
            ), wire)
        }

        if wire.command == "pane-sync" {
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
            guard let action = wire.action, !action.isEmpty else { return nil }
            return (.paneSync(paneID: paneID, workspace: workspace, action: action), wire)
        }

        if wire.command == "pane-sync-exclude" {
            guard let scope = parsePaneTarget(wire), let target = scope.target,
                  let excluded = wire.excluded else { return nil }
            return (.paneSyncExclude(
                paneID: scope.paneID, target: target, workspace: scope.workspace, excluded: excluded
            ), wire)
        }

        if wire.command == "pane-send-key" {
            // Mirrors `pane-close` / `pane-capture`: `paneID` (from
            // NEX_PANE_ID, when set) scopes label resolution to the
            // caller's workspace; without it, the reducer's
            // `resolvePaneTarget` requires either a UUID target or
            // an explicit `--workspace`. `target` and `key` are
            // both required and non-empty.
            guard let scope = parsePaneTarget(wire), let target = scope.target,
                  let key = wire.key, !key.isEmpty else { return nil }
            return (.paneSendKey(paneID: scope.paneID, target: target, key: key, workspace: scope.workspace), wire)
        }

        // `pane-send` / `pane-split` / `pane-create` / `pane-name` are
        // parsed here — before the mandatory-paneID guard below — so they
        // work from a shell with no NEX_PANE_ID (issue #117). `paneID`
        // (the caller's pane, when set) only scopes label resolution;
        // routing is by `--target` (UUID = global, label = needs scope)
        // and/or `--workspace`. Mirrors `pane-close` / `pane-send-key`.
        if wire.command == "pane-send" {
            guard let scope = parsePaneTarget(wire), let target = scope.target,
                  let text = wire.text, !text.isEmpty else { return nil }
            return (.paneSend(
                paneID: scope.paneID, target: target, text: text,
                workspace: scope.workspace, bare: wire.bare ?? false
            ), wire)
        }

        if wire.command == "pane-split" {
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            let target = (wire.target?.isEmpty == true) ? nil : wire.target
            let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
            // Need at least one anchor: the caller pane, an explicit
            // target pane, or a workspace to split within.
            guard paneID != nil || target != nil || workspace != nil else { return nil }
            let dir = wire.direction.flatMap { PaneLayout.SplitDirection(rawValue: $0) }
            return (.paneSplit(
                paneID: paneID, direction: dir, path: wire.path,
                name: wire.name, target: target, workspace: workspace
            ), wire)
        }

        if wire.command == "pane-create" {
            let paneID = wire.paneID.flatMap { UUID(uuidString: $0) }
            let target = (wire.target?.isEmpty == true) ? nil : wire.target
            let workspace = (wire.workspace?.isEmpty == true) ? nil : wire.workspace
            // `create` can legitimately run with only `--workspace`
            // (no anchor pane), so accept workspace as a sufficient hint.
            guard paneID != nil || target != nil || workspace != nil else { return nil }
            return (.paneCreate(
                paneID: paneID, path: wire.path, name: wire.name,
                target: target, workspace: workspace
            ), wire)
        }

        if wire.command == "pane-name" {
            // Need either the caller pane or an explicit target to rename.
            guard let scope = parsePaneTarget(wire),
                  let name = wire.name, !name.isEmpty else { return nil }
            return (.paneName(paneID: scope.paneID, target: scope.target, workspace: scope.workspace, name: name), wire)
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
        case "session-end":
            guard let sessionID = wire.sessionID, !sessionID.isEmpty else { return nil }
            socketMessage = .sessionEnded(paneID: paneID, sessionID: sessionID)
        // pane-split / pane-create / pane-name / pane-send are parsed
        // before the mandatory-paneID guard above (issue #117).
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
            // itself is already session-start, to avoid a duplicate, or
            // session-end, whose whole purpose is to *drop* the id — a
            // dual-fire would immediately re-attach it).
            if wire.command != "session-start", wire.command != "session-end",
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
