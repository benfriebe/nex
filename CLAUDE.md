# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build libghostty (required once, or after ghostty submodule changes)
# The lib/ directory is gitignored -- you must build it locally.
cd ghostty && zig build -Dapp-runtime=none -Doptimize=ReleaseFast -Demit-macos-app=false && cd ..
mkdir -p lib
cp $(find ghostty ghostty/.zig-cache -path "*/macos-*/libghostty.a" -type f | head -1) lib/libghostty.a

# Generate Xcode project (required after changing project.yml)
xcodegen generate --spec project.yml

# Build (also serves as typecheck — there is no separate typecheck step)
xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation build

# Run all tests (the `Nex` scheme's testTargets wiring routes the run
# into the `NexTests` target — there is no standalone `NexTests` scheme)
xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation test

# Run a single test class or method
xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation \
  -only-testing:NexTests/PaneLayoutTests test
xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation \
  -only-testing:NexTests/PaneLayoutTests/testSplitHorizontal test

# Lint & format
swiftlint lint                # lint check
swiftlint lint --fix          # auto-fix lint issues
swiftformat .                 # format code
swiftformat --lint .          # format check (no write)

# Run all checks (format-check → lint → build → test)
make check
```

`-skipMacroValidation` is required because TCA uses Swift macros.

## Architecture

**SwiftUI + TCA (Composable Architecture)** app targeting macOS 14+, Swift 6.

### Reducer hierarchy
- `AppReducer` — top-level state: workspace list, repo registry, socket messages (agent lifecycle + pane/workspace commands), git status, external indicators (menu bar/dock badge)
- `WorkspaceFeature` — per-workspace: panes, layout tree, focus, splits, agent status. Connected via `.forEach(\.workspaces, action: \.workspaces)`
- `SettingsFeature` — user preferences (worktree base path, appearance, keybindings)

### Terminal rendering — libghostty
- `GhosttyApp` — singleton wrapping `ghostty_app_t`. Initializes the runtime, dispatches action callbacks (title changes, pwd changes, close, desktop notifications) via `NotificationCenter`.
- `GhosttyConfig` / `GhosttyConfigClient` — reads user's `~/.config/ghostty/config`
- `SurfaceView` — `NSView` subclass hosting a `ghostty_surface_t`. Handles keyboard/mouse input, text input protocol, Metal rendering.
- `SurfaceManager` — singleton owning all `SurfaceView` instances by pane UUID. Thread-safe via `NSLock`. Surfaces persist across workspace switches (removed from view hierarchy but kept alive so PTY processes continue).

### Pane layout
- `PaneLayout` — recursive enum (`leaf(UUID)` | `split(direction, ratio, first, second)` | `empty`). Handles splitting, removing, moving panes, frame computation, and divider positioning.
- `PredefinedLayout` — enum of five tmux-style layouts (even-horizontal, even-vertical, main-horizontal, main-vertical, tiled). `buildLayout(for: [UUID])` generates the tree; first UUID is the "main" pane. Cycled via `⌘⇧Space` or `nex layout cycle`.
- `Pane` — model with id, working directory, git branch, agent status, Claude session ID.
- `PaneGridView` / `SurfaceContainerView` — SwiftUI views that render the layout tree and embed `SurfaceView` via `NSViewRepresentable`.

### Markdown panes
- **Entry points**: ⌘O (file picker filtered to `.md`), drag-and-drop a `.md` file onto the window, Finder **Open With → Nex** (or double-click when Nex is the default `.md` handler), or the `nex md [--here] <file>` / `nex open <file>` CLI commands. ⌘O and drag-drop route through `AppReducer.openFileAtPath`; the CLI `open`/`md` wire command routes through `AppReducer.openFile`. All converge on `WorkspaceFeature.openMarkdownFile`. The GUI entry points stay markdown-only; the CLI `nex open` routes a URL/hostname to a web pane and otherwise routes a local file by extension (see the CLI section), while `nex md` always opens a markdown pane.
- **Finder "Open With" (issue #197)**: `Info.plist` declares markdown via `CFBundleDocumentTypes` (role Editor, `LSHandlerRank` `Alternate` — appears in *Open With* and settable as default, without hijacking an existing default handler) + `UTImportedTypeDeclarations` importing `net.daringfireball.markdown` (extensions `md`/`markdown`). `NexAppDelegate.application(_:open:)` forwards each opened markdown file URL to `FileOpenGate` (an `@MainActor` AppKit→store bridge mirroring `QuitGate`), which `NexApp.onAppear` wires to `.openFileAtPath` — the same path as drag-drop. Two-stage cold-launch queue: `FileOpenGate` buffers files that arrive before `.onAppear` wires the store; `AppReducer.State.pendingFileOpens` parks files that arrive before the async state load sets `activeWorkspaceID`, drained by `.flushPendingFileOpens` from `.stateLoaded` (transient — not persisted).
- **View mode** (`MarkdownPaneView`): `WKWebView` with `drawsBackground=false`. File content is parsed via swift-markdown → `MarkdownHTMLRenderer` → full HTML document with CSS (light/dark). Live file watching via `DispatchSource` detects writes, renames, and deletes (vim-style save). Scroll position is preserved across reloads.
- **Code-block copy button**: `MarkdownHTMLRenderer` wraps every fenced code block in a container with a hover-revealed `.code-copy-btn`, and `MarkdownCodeCopyScript` (injected into the preview) posts the raw code text through the `copyCodeBlock` WKWebView script-message handler, which writes it to `NSPasteboard.general`. The button flashes a checkmark via a `.copied` class for 1.5s and swaps its `aria-label` to "Copied" for assistive tech. A re-entry guard ignores repeat clicks during the copied window.
- **Front-matter**: if a file begins with a `---`-fenced YAML block, `FrontMatterExtractor` pulls it out before swift-markdown parsing and `FrontMatterRenderer` emits a styled two-column table at the top of the preview. Parsing uses Yams; malformed YAML falls back to a styled raw block, and blocks larger than 64 KiB are skipped (rendered as plain markdown) to guard against pathological input.
- **Edit mode** (`MarkdownEditorView`): `NSTextView` (plain text, monospace 13pt) in an `NSScrollView`. Auto-saves to disk with 500ms debounce.
- **Toggle**: ⌘E switches between view and edit mode (only when a markdown pane is focused). Header button also toggles.
- **Background**: both views receive `ghosttyConfig.backgroundColor` / `backgroundOpacity` so they match terminal panes. The pane container also has a matching background fill for any gaps.
- **Git branch**: detected at open time via `gitService.getCurrentBranch` on the file's parent directory.

### Diff panes
- **Entry points**: `nex diff [<path>]` from the CLI, the bindable `open_diff` action (default unbound), or the "plusminus" button next to a repo association in the workspace inspector. All route through `AppReducer.openDiffPath` → `WorkspaceFeature.openDiffPane`.
- **Renderer** (`DiffHTMLRenderer`): pure-Swift line-by-line classifier — emits `<div class="line line-{add|del|hunk|context|file-header}">` with GitHub-style colors and the same dark-mode detection as `MarkdownHTMLRenderer`. Each `diff --git` opens a `<details class="file" open>` block with a sticky `<summary>` (the file path); clicking the summary toggles collapse, and `position: sticky` keeps the current file's header pinned while scrolling through its hunks. Empty diff → "No changes" placeholder.
- **View** (`DiffPaneView`): `WKWebView` mirroring `MarkdownPaneView` minus edit mode and file watching. Refreshes when the pane regains focus and when the header refresh button (`arrow.clockwise`) bumps a per-pane `refreshToken` tracked in `PaneGridView`.
- **Inputs**: `pane.workingDirectory` is the repo path; `pane.filePath` is the optional file/dir scope passed to `git diff -- <path>`. No `--staged` / ref-range support yet.
- **Git invocation**: new `gitService.getDiff(repoPath:targetPath:)` shells out via the existing `runGit` helper. Errors render as a placeholder line in the pane.

### Synchronise input (tmux-style)
- **Entry points**: the default-unbound `toggle_sync_input` keybinding, a per-pane header button, and `nex pane sync on|off|toggle|status|exclude|include`. When active, a keystroke in any synced pane is mirrored to every other synced pane in the same workspace.
- **State** (`WorkspaceFeature.State`): `isSyncInputActive: Bool` + `syncInputExcluded: Set<UUID>`. The computed `syncedPaneIDs` is the broadcast group: only `.shell` panes, minus the excluded set, and only when ≥2 qualify (so a lone terminal never "syncs" to itself). `syncInputExcluded` is cleared on every transition of `isSyncInputActive`, so `sync exclude` must run *after* `sync on`.
- **Actions**: `toggleSyncInput`, `setSyncInputActive(Bool)`, `setSyncInputExcluded(paneID:excluded:)`. Every reducer path that mutates `panes` or the sync fields calls `refreshSyncGroup`, which pushes the current `syncedPaneIDs` into `SurfaceManager.setSyncGroup(workspaceID:paneIDs:)`.
- **Broadcast** (`SurfaceManager`): holds `syncGroups: [UUID: Set<UUID>]` (per workspace). `SurfaceView.sendKey` calls `broadcastKey(from:key:)`, which mirrors the libghostty key event to every sibling in the source's group (best-effort; dead surfaces are skipped). `isSyncing(paneID:)` backs the header badge.

### Persistence — GRDB
- `DatabaseService` — manages SQLite via GRDB's `DatabasePool` (prod) or `DatabaseQueue` (tests, in-memory).
- `PersistenceService` — debounced (500ms) full-state serialization. Clears and re-inserts all records on each save. Tables: `WorkspaceRecord`, `PaneRecord`, `RepoRecord`, `RepoAssociationRecord`, `AppStateRecord`.
- DB location: `~/Library/Application Support/Nex/nex.db`

### Agent monitoring & CLI
- `SocketServer` — Unix domain socket at `/tmp/nex.sock` + optional TCP listener on `127.0.0.1:<port>`. Receives newline-delimited JSON from the `nex` CLI. Messages use `"command"` key. Commands: `start`, `stop`, `error`, `notification`, `session-start`, `session-end`, `pane-split`, `pane-create`, `pane-close`, `pane-name`, `pane-send`, `pane-send-key`, `pane-sync`, `pane-sync-exclude`, `pane-move`, `pane-move-to-workspace`, `pane-list`, `pane-capture`, `workspace-create`, `workspace-move`, `group-create`, `group-rename`, `group-delete`, `layout-cycle`, `layout-select`, `open`, `diff`, `ping` (plus the `web-*` family for the web pane). Group icon management is deliberately UI-only (context menu); there is no `group-set-icon` wire command.
- **Request/response framing**: most commands are fire-and-forget (server reads, acts, drops the FD). Commands in `replyCommandAllowlist` (currently `pane-list`, `pane-close`, `pane-capture`, `pane-send`, `pane-send-key`, `pane-sync`, `pane-sync-exclude`, `ping`, and the `web-*` verbs) return structured JSON — the server allocates a `SocketServer.ReplyHandle`, the reducer writes a single newline-terminated JSON line via `reply.send(...)`, then `reply.close()` cancels the client's dispatch source (EOF on the CLI side). Success payloads are `{"ok":true, ...}`; failures are `{"ok":false,"error":"<message>"}` and the CLI exits non-zero. Reply handlers must gracefully accept `reply: nil` for the legacy fire-and-forget path.
- **`ping` command**: request/response health check. The reducer's `handlePing` replies with `{"ok":true,"version":"<short>","build":"<build>","pid":<n>}` — used by `nex doctor` to verify the running app can dispatch socket commands round-trip, and as a cheap version probe so the CLI can flag CLI/app drift.
- **TCP transport**: enabled via `tcp-port = <port>` in `~/.config/nex/config`. Binds to `127.0.0.1` only (no auth needed — SSH tunnels handle remote security). Use cases: dev containers connect via `host.docker.internal:<port>`, remote agents connect via SSH reverse tunnel (`ssh -R <port>:localhost:<port> remote`).
- `SocketMessage` — enum representing all wire messages (agent lifecycle + pane commands + workspace + group commands).
- **Name-or-ID resolution** (`State.resolveGroup` / `State.resolveWorkspace`): commands like `workspace-move`, `group-rename`, `group-delete` accept either a UUID string or a case-sensitive name. UUID wins when it matches; names must be unique to resolve (ambiguous → no-op).
- `nex` CLI — standalone Swift CLI in `Tools/nex-cli/`. Compiled as a post-build script and bundled into `Contents/Helpers/`. Subcommand structure:
  - `nex event stop|start|error|notification|session-start|session-end [--message ...] [--title ...] [--body ...]` — `session-end` (Claude Code SessionEnd hook) clears the pane's tracked `claudeSessionID` when it still matches the ending session, so an exited agent session is not `claude --resume`d on next launch (issue #178)
  - `nex pane split|create|close|name|send|move|move-to-workspace [options]` — `split`, `create`, and `close` all accept `--target <name-or-uuid>` to address a specific pane; with `--target`, `close` works without `NEX_PANE_ID`. `close` rejects bare positional arguments and unknown options with a usage error — addressing a pane other than the caller always goes through `--target`, so a typo can never silently close the calling pane. `close` and `send` also accept `--workspace <name-or-id>` to narrow label resolution to a single workspace (disambiguates cross-workspace label collisions)
  - **Outside-Nex pane commands**: `pane send`, `pane split`, `pane create`, and `pane name` no longer require `NEX_PANE_ID` — they work from a plain shell (e.g. OpenACP) like `send-key` / `close` / `capture` already did. The CLI no longer calls `requirePaneID()` for them; it includes `pane_id` only when the env var is set (to scope label resolution to the caller's workspace), and routes by `--target` (UUID = global, label needs `NEX_PANE_ID` or `--workspace`). On the server these four commands are parsed *before* the mandatory-`paneID` guard in `parseWireMessage` (mirroring `pane-close`), so their `SocketMessage` cases carry `paneID: UUID?`. `pane create` / `pane split` also accept `--workspace <name-or-id>` to choose the destination workspace: when `--workspace` is given *without* `--target` it wins outright — even over the caller's forwarded `NEX_PANE_ID` — so a pane in workspace alpha can run `nex pane create --workspace beta` (the handler short-circuits to `resolveWorkspace` before the caller-pane branch; `--target` still keeps precedence so `--target X --workspace Y` scopes X's label to Y, and the caller's pane is the anchor only when neither flag is given). `pane create` into an *empty* workspace lays out the first pane via `.createPane`, which carries the caller-supplied id plus `--name` (label) and `--path` (working directory) so the acked pane actually has them; the populated case threads the same minted id through `splitPane` / `splitPaneAtPath`, so `split` / `create` always return the *real* new pane id. The reducer handlers (`handlePaneSplit` / `handlePaneCreate`) reuse those existing `WorkspaceFeature.Action`s (extended with defaulted `newPaneID:` / `label:` / `workingDirectory:` parameters so all existing call sites are unchanged) rather than adding a new case. All four are request/response — add `--json` for a machine-readable reply; `pane name`'s new label is the sole positional and stray args are rejected. (Note: a changed enum-case signature with a stale call site in the large `ContentView.body` surfaces as a misleading "unable to type-check this expression in reasonable time" error pointing at `body` rather than the call site — grep all call sites when you change a `SocketMessage` / `WorkspaceFeature.Action` case.)
  - `nex pane close` / `send` / `split` / `create` / `name` are request/response: the CLI blocks on a `{"ok":true|false,"error":...}` reply and exits non-zero on failure (unknown/ambiguous target, unknown workspace, etc). `send` / `name` replies include the resolved `pane_id`; `split` / `create` replies include the *newly created* pane's `pane_id` (plus `workspace_id`, `workspace_name`, `label?`).
  - `nex pane send-key --target <name-or-uuid> [--workspace <name-or-id>] <key>` — request/response. Delivers a single named keystroke (`enter`, `return`, `tab`, `escape`/`esc`, `space`, `backspace`, `up`, `down`, `left`, `right`, `ctrl-c`) outside any bracketed-paste envelope. Companion to `pane send` for TUI targets that opt into bracketed-paste (Claude Code, vim, etc): `pane send "text"` then `pane send-key enter` is the reliable submit path. Callable from outside a Nex pane (no `NEX_PANE_ID` required) — mirrors `pane close` / `pane capture`; UUID targets work globally, label targets need either `NEX_PANE_ID` or `--workspace`. Unknown key names are rejected with a structured error before the surface is touched. The byte-mapped keys (enter/tab/escape/space/backspace/ctrl-c) go through the libghostty key-event path with `mods=NONE` and `text=<byte>` so the raw byte hits the PTY's line discipline (e.g. ctrl-c → `\x03` → SIGINT); arrow keys leave `text=nil` so libghostty translates the keycode based on terminal mode (DECCKM `\eOA` vs `\e[A`).
  - `nex pane send --bare` — write text to the target pane without appending Enter. Pair with `pane send-key` for compositional input (e.g. `pane send --bare "ls /tm"` then `pane send-key tab` to trigger autocomplete; or type a partial sequence then send `escape`). Default behaviour (no `--bare`) is unchanged: text is followed by an Enter keystroke just like before.
  - **Label resolution scope**: label lookups for `pane send` / `pane send-key` / `pane close` / `pane capture` always require an explicit workspace scope — either implicit via `NEX_PANE_ID` (caller's own workspace) or explicit via `--workspace <name-or-id>`. A bare label with neither is rejected (no global fallback) so callers can't silently route to a pane in an unintended workspace. UUID lookups remain global.
  - `nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]` — also request/response; prints a human-readable table by default (columns `ID`, `LABEL`, `TYPE`, `WORKSPACE`, `STATUS`, `SESSION`, `CWD`, where `TYPE` is the pane kind: `shell` / `markdown` / `scratchpad` / `diff` / `web`, and `SESSION` is the truncated agent session id or `-` when none is attached), JSON array with `--json` (the JSON key is `agent_session_id`, full UUID)
  - `nex pane capture [--target <name-or-uuid>] [--workspace <name-or-id>] [--lines N] [--scrollback]` — request/response. Reads another pane's terminal contents and prints them to stdout. Without `--target`, captures the current pane (requires `NEX_PANE_ID`). `--scrollback` extends the read region from the visible viewport to the full screen. Rejects non-terminal panes (markdown / scratchpad / diff) with a typed error. Symmetric counterpart to `pane send` — unblocks orchestrator panes that need to read worker output without the worker cooperating
  - `nex pane id` — prints current `NEX_PANE_ID` (exit 0) or exits 1 if not set. Local only; doesn't touch the socket. Useful as a cheap in-Nex check
  - `nex pane sync on|off|toggle|status` and `nex pane sync exclude|include --target <name-or-uuid>`: tmux-style synchronise-input toggle (request/response, `--json` for a machine-readable reply). `on`/`off`/`toggle` flip workspace-wide input mirroring; `status` is a read-only snapshot; `exclude`/`include` opt a single pane out of (or back into) the active sync group. Scope defaults to the caller's workspace via `NEX_PANE_ID`; pass `--workspace <name-or-id>` to drive another workspace. See "Synchronise input" below for the dispatch path.
  - `nex workspace create [--name ...] [--path ...] [--color ...] [--group <name>]`
  - `nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]`
  - `nex group create <name> [--color blue]`
  - `nex group rename <name-or-id> <new-name>`
  - `nex group delete <name-or-id> [--cascade]` — without `--cascade`, children promote to top level
  - `nex layout cycle|select <name>`
  - `nex open [--here] <path-or-url>` — generic opener that routes **in the CLI**, reusing existing wire commands. A **URL or hostname** argument opens a web pane (same `web-open` path as `nex web open`, prints `open ok: <uuid>`): a real `scheme://` URL, a `host:port`, `localhost[:port]`, an IPv4 literal, or a bare dotted hostname whose final label is a recognised TLD (`webOpenCommonTLDs`) — so `nex open google.com`, `nex open https://example.com`, `nex open localhost:3000` Just Work. Otherwise it routes a **local file** by (lowercased) extension: markdown extensions (`md`, `markdown`, `mdown`, `mkd`, `mkdn`, `mdwn`, `markdn`) send the `open` command → markdown pane; web extensions (`html`, `htm`, `pdf`, `svg`, `png`, `jpg`, `jpeg`, `gif`, `webp`) build a `file://` URL and send `web-open` → web pane; any other extension is a usage error pointing at `nex md` / `nex web open`. The file-vs-host split is decided by `webTargetForOpenArg(_:)` — the mirror of `localFileURL(forWebArg:)`: explicit paths (`/`, `./`, `../`, `~`) and existing local files always stay local (so `./google.com` is a file, and a bare word like `README` / an unrecognised or file-type TLD like `notes.txt` / `foo.museum` falls through to the file router — use `nex web open` for those). `--here` (reuse the calling pane) applies to the markdown route only — it's ignored with a stderr note for URLs and web files, which always open a new pane. The routing tables live in `markdownOpenExtensions` / `webOpenExtensions` / `webOpenCommonTLDs` in `Tools/nex-cli/nex.swift`.
  - `nex md [--here] <filepath>` — dedicated markdown command; always opens (or `--here`-reuses) a markdown preview pane regardless of extension. Same `open` wire command as `nex open`'s markdown route; the escape hatch for forcing a markdown pane on a non-`.md` file.
  - `nex diff [<path>]` — opens a diff pane for the CLI's current working directory (or scoped to `<path>`). The diff pane refreshes on focus and via the header refresh button.
  - `nex web open|navigate|tab-new <url>` resolve **local file paths** to `file://` URLs CLI-side (issue #177): the `localFileURL(forWebArg:)` helper in `Tools/nex-cli/nex.swift` converts an argument that is path-shaped (`/`, `./`, `../`, `~` prefix), or a **bare name matching a regular file _with an extension_** in the cwd, into a percent-encoded `file://` URL (expanding `~`, resolving against cwd). Bare hostnames (`example.com`), single-label hosts that collide with a cwd directory (`app`, `web`, `api`), extensionless names, and real URLs pass through untouched — the existence branch deliberately excludes directories and extensionless names so it can't hijack a dev hostname (review of #177); `./name` forces a local path. Server-side, `WebPaneCoordinator.load(_:into:)` loads `file://` URLs via `loadFileURL(_:allowingReadAccessTo:)` (parent dir) so a local HTML file's sibling assets resolve; remote URLs use a normal `URLRequest` load. The app is not sandboxed (`Nex.entitlements` → `app-sandbox` is `false`), so the directory read grant works without a security-scoped bookmark.
  - `nex doctor [--json]` — IPC health check. Runs five named checks (`transport`, `socket`/`resolve`, `ping`, `process`, `version`) and prints pass/fail/warn with concrete repair tips. Use when CLI commands stop reaching the app: `ping` exercises the same dispatch path as a real CLI command, `process` distinguishes "Nex isn't running" from "Nex is wedged", and `version` flags CLI/app drift. Exits 0 on all-pass.
- **CLI transport selection**: `NEX_SOCKET` env var selects transport. Absent = Unix socket (`/tmp/nex.sock`). `tcp:<host>:<port>` = TCP (e.g., `NEX_SOCKET=tcp:host.docker.internal:19400`).
- **Categorised transport errors**: `Tools/nex-cli/nex.swift` classifies socket failures into a `TransportFailure` enum (`unixSocketMissing`, `unixConnectRefused`, `tcpConnectFailed`, `emptyReply`, etc.) and prints an `Error: …\nRepair: …` pair at each call site via `printTransportFailure`. Fire-and-forget commands (Claude Code hooks etc.) preserve exit code 0 but now print a `Warning: …` stderr line — set `NEX_SILENT=1` to suppress entirely. `nex event …` (the hook entrypoint) auto-suppresses the warning to avoid spamming user terminals on every Stop/Notification fire; set `NEX_VERBOSE_HOOKS=1` to surface them. `lastTransportFailure` is reset at the start of every send call so chained CLI commands (e.g. `nex doctor` running ping then ps) can't carry stale diagnostics between calls.
- `StatusBarController` — menu bar icon + popover showing running/waiting agents across workspaces.
- `NotificationService` — desktop notifications with "Open"/"Dismiss" actions.

### Keybindings
- **Config file**: `~/.config/nex/config` — Ghostty-style `key = value` syntax. General settings: `focus-follows-mouse`, `focus-follows-mouse-delay`, `theme`, `tcp-port`. Keybindings: `keybind = super+d=split_right`. Parsed by `ConfigParser`, loaded by `KeybindingService`.
- **Data model** (`KeyBinding.swift`): `KeyTrigger` (keyCode + modifiers), `NexAction` (48 bindable actions, including the web-pane verbs and the default-unbound `open_diff` / `toggle_sync_input`), `KeyBindingMap` (trigger → action dictionary with sorted lookups).
- **Two dispatch layers**: SwiftUI `Commands` (`NexCommands`) handles menu bar shortcuts; `PaneShortcutMonitor` (NSEvent local monitor) handles pane-context shortcuts. Both read from `AppReducer.State.keybindings`.
- **Settings UI** (`KeybindingsSettingsView`): table grouped by category with key recorder sheet, per-action reset, and reset-all. Changes are persisted to the config file.
- **Conditional shortcuts**: `toggle_markdown_edit` only fires for markdown panes, `close_search` only when search is active, `close_pane` deletes workspace when it's the last pane.

### Dependencies (TCA DependencyKey pattern)
All services are registered as TCA dependencies: `surfaceManager`, `persistenceService`, `gitService`, `socketServer`, `notificationService`, `statusBarController`, `ghosttyConfig`. Tests use `testValue` (e.g., in-memory DB, no-op managers).

## Key Conventions

- **Swift 6 concurrency**: use `nonisolated(unsafe)` for mutable state protected by `NSLock`. Use `@preconcurrency` for Obj-C protocol conformances.
- **XcodeGen**: `project.yml` is the source of truth. Never edit `Nex.xcodeproj` directly — regenerate with `xcodegen generate --spec project.yml`.
- **libghostty**: prebuilt static library at `lib/libghostty.a`, header at `ghostty/include/ghostty.h`. Bridging header at `Nex/Ghostty/Ghostty-Bridging-Header.h`.
- **Test guard**: `NexApp.isTestMode` prevents ghostty initialization during test runs.
- **TCA testing**: `TestStore` closure receives pre-action state; mutate to expected post-state. Use `@Dependency(\.uuid)` with `.constant()` for predictable IDs. Test suites need `@MainActor`.

## Release Process

1. Bump version in `Nex/Info.plist` (both `CFBundleShortVersionString` and `CFBundleVersion`)
2. Commit: `chore: bump version to X.Y.Z`
3. Push to `main`
4. Create and push tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
5. GitHub Actions handles archive, sign, notarize, DMG, and appcast update
6. Update release notes via `gh release edit` with a proper changelog

Do NOT run `make release`, `make archive`, or `make dmg` locally.

## Code Style

- SwiftFormat config: 4-space indent, no trailing commas, inline `patternlet`. See `.swiftformat`.
- SwiftLint: relaxed rules (no line/file/function length limits, no nesting limit). See `.swiftlint.yml`.
- The `ghostty/` submodule is excluded from linting and formatting.
