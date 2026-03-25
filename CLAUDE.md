# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
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
- `SettingsFeature` — user preferences (worktree base path, appearance)

### Terminal rendering — libghostty
- `GhosttyApp` — singleton wrapping `ghostty_app_t`. Initializes the runtime, dispatches action callbacks (title changes, pwd changes, close, desktop notifications) via `NotificationCenter`.
- `GhosttyConfig` / `GhosttyConfigClient` — reads user's `~/.config/ghostty/config`
- `SurfaceView` — `NSView` subclass hosting a `ghostty_surface_t`. Handles keyboard/mouse input, text input protocol, Metal rendering.
- `SurfaceManager` — singleton owning all `SurfaceView` instances by pane UUID. Thread-safe via `NSLock`. Surfaces persist across workspace switches (removed from view hierarchy but kept alive so PTY processes continue).

### Pane layout
- `PaneLayout` — recursive enum (`leaf(UUID)` | `split(direction, ratio, first, second)` | `empty`). Handles splitting, removing, moving panes, frame computation, and divider positioning.
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
- `SocketServer` — Unix domain socket at `/tmp/nex.sock`. Receives newline-delimited JSON from the `nex` CLI. Messages use `"command"` key. Commands: `start`, `stop`, `error`, `notification`, `session-start`, `pane-split`, `pane-create`, `pane-close`, `pane-name`, `pane-send`, `workspace-create`.
- `SocketMessage` — enum representing all wire messages (agent lifecycle + pane commands + workspace commands).
- `nex` CLI — standalone Swift CLI in `Tools/nex-cli/`. Compiled as a post-build script and bundled into `Contents/Helpers/`. Subcommand structure:
  - `nex event stop|start|error|notification|session-start [--message ...] [--title ...] [--body ...]`
  - `nex pane split|create|close|name|send [options]`
  - `nex workspace create [--name ...] [--path ...] [--color ...]`
- `StatusBarController` — menu bar icon + popover showing running/waiting agents across workspaces.
- `NotificationService` — desktop notifications with "Open"/"Dismiss" actions.

### Dependencies (TCA DependencyKey pattern)
All services are registered as TCA dependencies: `surfaceManager`, `persistenceService`, `gitService`, `socketServer`, `notificationService`, `statusBarController`, `ghosttyConfig`. Tests use `testValue` (e.g., in-memory DB, no-op managers).

## Key Conventions

- **Swift 6 concurrency**: use `nonisolated(unsafe)` for mutable state protected by `NSLock`. Use `@preconcurrency` for Obj-C protocol conformances.
- **XcodeGen**: `project.yml` is the source of truth. Never edit `Nex.xcodeproj` directly — regenerate with `xcodegen generate --spec project.yml`.
- **libghostty**: prebuilt static library at `lib/libghostty.a`, header at `ghostty/include/ghostty.h`. Bridging header at `Nex/Ghostty/Ghostty-Bridging-Header.h`.
- **Test guard**: `NexApp.isTestMode` prevents ghostty initialization during test runs.
- **TCA testing**: `TestStore` closure receives pre-action state; mutate to expected post-state. Use `@Dependency(\.uuid)` with `.constant()` for predictable IDs. Test suites need `@MainActor`.

## Code Style

- SwiftFormat config: 4-space indent, no trailing commas, inline `patternlet`. See `.swiftformat`.
- SwiftLint: relaxed rules (no line/file/function length limits, no nesting limit). See `.swiftlint.yml`.
- The `ghostty/` submodule is excluded from linting and formatting.
