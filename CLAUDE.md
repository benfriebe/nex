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
- **Entry points**: ⌘O (file picker filtered to `.md`) or drag-and-drop a `.md` file onto the window. Both route through `AppReducer.openFileAtPath` → `WorkspaceFeature.openMarkdownFile`.
- **View mode** (`MarkdownPaneView`): `WKWebView` with `drawsBackground=false`. File content is parsed via swift-markdown → `MarkdownHTMLRenderer` → full HTML document with CSS (light/dark). Live file watching via `DispatchSource` detects writes, renames, and deletes (vim-style save). Scroll position is preserved across reloads.
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

### Persistence — GRDB
- `DatabaseService` — manages SQLite via GRDB's `DatabasePool` (prod) or `DatabaseQueue` (tests, in-memory).
- `PersistenceService` — debounced (500ms) full-state serialization. Clears and re-inserts all records on each save. Tables: `WorkspaceRecord`, `PaneRecord`, `RepoRecord`, `RepoAssociationRecord`, `AppStateRecord`.
- DB location: `~/Library/Application Support/Nex/nex.db`

### Agent monitoring & CLI
- `SocketServer` — Unix domain socket at `/tmp/nex.sock` + optional TCP listener on `127.0.0.1:<port>`. Receives newline-delimited JSON from the `nex` CLI. Messages use `"command"` key. Commands: `start`, `stop`, `error`, `notification`, `session-start`, `pane-split`, `pane-create`, `pane-close`, `pane-name`, `pane-send`, `pane-move`, `pane-move-to-workspace`, `pane-list`, `pane-capture`, `workspace-create`, `workspace-move`, `group-create`, `group-rename`, `group-delete`, `layout-cycle`, `layout-select`, `open`, `diff`. Group icon management is deliberately UI-only (context menu); there is no `group-set-icon` wire command.
- **Request/response framing**: most commands are fire-and-forget (server reads, acts, drops the FD). Commands in `replyCommandAllowlist` (currently `pane-list`, `pane-close`, `pane-capture`) return structured JSON — the server allocates a `SocketServer.ReplyHandle`, the reducer writes a single newline-terminated JSON line via `reply.send(...)`, then `reply.close()` cancels the client's dispatch source (EOF on the CLI side). Success payloads are `{"ok":true, ...}`; failures are `{"ok":false,"error":"<message>"}` and the CLI exits non-zero. Reply handlers must gracefully accept `reply: nil` for the legacy fire-and-forget path.
- **TCP transport**: enabled via `tcp-port = <port>` in `~/.config/nex/config`. Binds to `127.0.0.1` only (no auth needed — SSH tunnels handle remote security). Use cases: dev containers connect via `host.docker.internal:<port>`, remote agents connect via SSH reverse tunnel (`ssh -R <port>:localhost:<port> remote`).
- `SocketMessage` — enum representing all wire messages (agent lifecycle + pane commands + workspace + group commands).
- **Name-or-ID resolution** (`State.resolveGroup` / `State.resolveWorkspace`): commands like `workspace-move`, `group-rename`, `group-delete` accept either a UUID string or a case-sensitive name. UUID wins when it matches; names must be unique to resolve (ambiguous → no-op).
- `nex` CLI — standalone Swift CLI in `Tools/nex-cli/`. Compiled as a post-build script and bundled into `Contents/Helpers/`. Subcommand structure:
  - `nex event stop|start|error|notification|session-start [--message ...] [--title ...] [--body ...]`
  - `nex pane split|create|close|name|send|move|move-to-workspace [options]` — `split`, `create`, and `close` all accept `--target <name-or-uuid>` to address a specific pane; with `--target`, `close` works without `NEX_PANE_ID`. `close` also accepts `--workspace <name-or-id>` to narrow label resolution to a single workspace (disambiguates cross-workspace label collisions)
  - `nex pane close` is request/response: the CLI blocks on a `{"ok":true|false,"error":...}` reply and exits non-zero on failure (unknown/ambiguous target, unknown workspace, etc). The no-flag form still reads a reply but behaves identically to the old fire-and-forget form from the user's perspective.
  - `nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]` — also request/response; prints a human-readable table by default, JSON array with `--json`
  - `nex pane capture [--target <name-or-uuid>] [--workspace <name-or-id>] [--lines N] [--scrollback]` — request/response. Reads another pane's terminal contents and prints them to stdout. Without `--target`, captures the current pane (requires `NEX_PANE_ID`). `--scrollback` extends the read region from the visible viewport to the full screen. Rejects non-terminal panes (markdown / scratchpad / diff) with a typed error. Symmetric counterpart to `pane send` — unblocks orchestrator panes that need to read worker output without the worker cooperating
  - `nex pane id` — prints current `NEX_PANE_ID` (exit 0) or exits 1 if not set. Local only; doesn't touch the socket. Useful as a cheap in-Nex check
  - `nex workspace create [--name ...] [--path ...] [--color ...] [--group <name>]`
  - `nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]`
  - `nex group create <name> [--color blue]`
  - `nex group rename <name-or-id> <new-name>`
  - `nex group delete <name-or-id> [--cascade]` — without `--cascade`, children promote to top level
  - `nex layout cycle|select <name>`
  - `nex open <filepath>`
  - `nex diff [<path>]` — opens a diff pane for the CLI's current working directory (or scoped to `<path>`). The diff pane refreshes on focus and via the header refresh button.
- **CLI transport selection**: `NEX_SOCKET` env var selects transport. Absent = Unix socket (`/tmp/nex.sock`). `tcp:<host>:<port>` = TCP (e.g., `NEX_SOCKET=tcp:host.docker.internal:19400`).
- `StatusBarController` — menu bar icon + popover showing running/waiting agents across workspaces.
- `NotificationService` — desktop notifications with "Open"/"Dismiss" actions.

### Keybindings
- **Config file**: `~/.config/nex/config` — Ghostty-style `key = value` syntax. General settings: `focus-follows-mouse`, `focus-follows-mouse-delay`, `theme`, `tcp-port`. Keybindings: `keybind = super+d=split_right`. Parsed by `ConfigParser`, loaded by `KeybindingService`.
- **Data model** (`KeyBinding.swift`): `KeyTrigger` (keyCode + modifiers), `NexAction` (26 bindable actions), `KeyBindingMap` (trigger → action dictionary with sorted lookups).
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
