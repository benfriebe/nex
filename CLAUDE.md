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

# Run all tests
xcodebuild -scheme NexTests -destination 'platform=macOS' -skipMacroValidation test

# Run a single test class or method
xcodebuild -scheme NexTests -destination 'platform=macOS' -skipMacroValidation \
  -only-testing:NexTests/PaneLayoutTests test
xcodebuild -scheme NexTests -destination 'platform=macOS' -skipMacroValidation \
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
- **Edit mode** (`MarkdownEditorView`): `NSTextView` (plain text, monospace 13pt) in an `NSScrollView`. Auto-saves to disk with 500ms debounce.
- **Toggle**: ⌘E switches between view and edit mode (only when a markdown pane is focused). Header button also toggles.
- **Background**: both views receive `ghosttyConfig.backgroundColor` / `backgroundOpacity` so they match terminal panes. The pane container also has a matching background fill for any gaps.
- **Git branch**: detected at open time via `gitService.getCurrentBranch` on the file's parent directory.

### Persistence — GRDB
- `DatabaseService` — manages SQLite via GRDB's `DatabasePool` (prod) or `DatabaseQueue` (tests, in-memory).
- `PersistenceService` — debounced (500ms) full-state serialization. Clears and re-inserts all records on each save. Tables: `WorkspaceRecord`, `PaneRecord`, `RepoRecord`, `RepoAssociationRecord`, `AppStateRecord`.
- DB location: `~/Library/Application Support/Nex/nex.db`

### Agent monitoring & CLI
- `SocketServer` — Unix domain socket at `/tmp/nex.sock` + optional TCP listener on `127.0.0.1:<port>`. Receives newline-delimited JSON from the `nex` CLI. Messages use `"command"` key. Commands: `start`, `stop`, `error`, `notification`, `session-start`, `pane-split`, `pane-create`, `pane-close`, `pane-name`, `pane-send`, `pane-move`, `pane-move-to-workspace`, `pane-list`, `workspace-create`, `workspace-move`, `group-create`, `group-rename`, `group-delete`, `layout-cycle`, `layout-select`, `open`. Group icon management is deliberately UI-only (context menu); there is no `group-set-icon` wire command.
- **Request/response framing**: most commands are fire-and-forget (server reads, acts, drops the FD). `pane-list` is the first command that returns data — the server allocates a `SocketServer.ReplyHandle` for it, the reducer writes a single newline-terminated JSON line via `reply.send(...)`, then `reply.close()` cancels the client's dispatch source (EOF on the CLI side). The allowlist of reply-producing commands lives in `replyCommandAllowlist`; every other command is byte-identical on the wire.
- **TCP transport**: enabled via `tcp-port = <port>` in `~/.config/nex/config`. Binds to `127.0.0.1` only (no auth needed — SSH tunnels handle remote security). Use cases: dev containers connect via `host.docker.internal:<port>`, remote agents connect via SSH reverse tunnel (`ssh -R <port>:localhost:<port> remote`).
- `SocketMessage` — enum representing all wire messages (agent lifecycle + pane commands + workspace + group commands).
- **Name-or-ID resolution** (`State.resolveGroup` / `State.resolveWorkspace`): commands like `workspace-move`, `group-rename`, `group-delete` accept either a UUID string or a case-sensitive name. UUID wins when it matches; names must be unique to resolve (ambiguous → no-op).
- `nex` CLI — standalone Swift CLI in `Tools/nex-cli/`. Compiled as a post-build script and bundled into `Contents/Helpers/`. Subcommand structure:
  - `nex event stop|start|error|notification|session-start [--message ...] [--title ...] [--body ...]`
  - `nex pane split|create|close|name|send|move|move-to-workspace [options]`
  - `nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]` — only command that returns data; prints a human-readable table by default, JSON array with `--json`
  - `nex workspace create [--name ...] [--path ...] [--color ...] [--group <name>]`
  - `nex workspace move <name-or-id> (--group <name> | --top-level) [--index N]`
  - `nex group create <name> [--color blue]`
  - `nex group rename <name-or-id> <new-name>`
  - `nex group delete <name-or-id> [--cascade]` — without `--cascade`, children promote to top level
  - `nex layout cycle|select <name>`
  - `nex open <filepath>`
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
