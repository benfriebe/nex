# Nex

A Mac-native terminal workspace multiplexer for polyrepo development with AI coding agents.

Nex gives you named, persistent workspaces with free-form pane splits, multi-repo worktree management, an in-app browser that agents can drive, and first-class lifecycle monitoring for Claude Code. Switching workspaces is instant. Agents get noticed when they need you.

> Built on [libghostty](https://github.com/ghostty-org/ghostty) for terminal rendering. Targets macOS 14+. Written in Swift 6 + SwiftUI + [TCA](https://github.com/pointfreeco/swift-composable-architecture).

## Highlights

- **Workspaces, groups, and labels.** Organise work by context, colour-coded, with a sidebar filter that searches names and labels.
- **Free-form pane splits + five tmux-style preset layouts.** Cycle layouts with `Cmd+Shift+Space`.
- **Five pane types.** Terminal, markdown (preview + editor), git diff, scratchpad, and a full in-app web browser.
- **Claude Code integration.** Status indicators on every pane, menu-bar counts, dock badge, and desktop notifications when an agent finishes or asks a question.
- **Multi-repo worktree management.** Register your repos once, then attach one or more worktrees to a workspace. Optional native `graft` mirrors worktree changes back to the parent checkout in real time.
- **A scriptable companion CLI (`nex`).** Spawn panes, send keystrokes, capture terminal output, open diffs, drive the web pane, and orchestrate multi-agent workflows from anywhere.
- **Customisable everything.** Keybindings, global hotkey, focus-follows-mouse, theme, background opacity, all editable in Settings or via `~/.config/nex/config`.
- **Persistent.** Workspaces, panes, layouts, and repo associations survive restarts.

## Install

### From a release (recommended)

1. Download the latest `Nex-X.Y.Z.dmg` from [Releases](https://github.com/benfriebe/nex/releases/latest).
2. Drag `Nex.app` into `/Applications`.
3. Run the post-install helper to install the `nex` CLI and wire up Claude Code hooks:

   ```bash
   /Applications/Nex.app/Contents/Resources/scripts/install-hooks.sh
   ```

   This symlinks `nex` into `/usr/local/bin` and adds Stop / Notification / SessionStart / UserPromptSubmit hooks to `~/.claude/settings.json`. Restart any running Claude Code sessions afterwards.

Auto-updates are delivered via Sparkle. The CLI symlink heals itself on every launch so it always points at the running app bundle.

### From source

```bash
git clone --recurse-submodules git@github.com:benfriebe/nex.git
cd nex
brew install xcodegen swiftlint swiftformat
xcodegen generate --spec project.yml
xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation build
```

`-skipMacroValidation` is required because TCA uses Swift macros. A prebuilt `lib/libghostty.a` is checked in; see [`CLAUDE.md`](CLAUDE.md) for rebuild instructions.

## Quick start

1. Launch Nex. Press `Cmd+N` to create your first workspace.
2. Open **Settings > Repositories** and add the repos you work in (one-time setup, or scan a directory recursively).
3. In the new workspace, the inspector lets you attach a repo and optionally create a fresh worktree.
4. Split panes with `Cmd+D` (right) or `Cmd+Shift+D` (down). Drag dividers to resize.
5. Run `claude` in any pane. The pane header lights up while the agent thinks; the menu-bar icon shows running and waiting counts across all workspaces.
6. Open `Cmd+P` for the command palette, `Cmd+I` for the inspector, `Cmd+Shift+S` for the sidebar.

## Core concepts

### Workspaces

The unit of context. Each workspace has its own pane layout, repo associations, and running processes. Switching workspaces is instant because terminal surfaces are kept alive in memory (PTYs keep running) and just removed from the view hierarchy.

Right-click any workspace in the sidebar to rename, recolour, label, or delete. Multi-select with `Cmd`-click or `Shift`-click and bulk-rename, recolour, or delete.

### Groups

Workspaces can live inside named, colour-coded groups (folders, effectively). Drag to reorder, nest, or promote to the top level. Cascade-delete a group to remove its workspaces in one go, or delete without cascade to promote the children back to the top level. Right-click an empty group to create a workspace directly inside it.

### Labels and the sidebar filter

Tag any workspace with one or more labels from the inspector. The filter input at the top of the sidebar searches workspace names AND labels live, so `Cmd+Shift+S` (sidebar), type, and jump.

## Pane types

A workspace can mix any pane type in the same split layout. Move panes between splits with `Ctrl+Shift+Arrow`, zoom with `Cmd+Shift+Return`, close with `Cmd+W`, reopen with `Cmd+Shift+T`.

### Terminal

Powered by libghostty. Inherits your existing Ghostty config from `~/.config/ghostty/config`: font, theme, scrollback, key handling. Pane headers show working directory and current git branch (sub-second updates via a `.git/HEAD` watcher). Cmd+click a path to open it.

### Markdown

Open `.md` files via `Cmd+O` or drag-and-drop onto the window.

- Styled preview via WKWebView with light/dark detection.
- Live file watching: external edits (vim, VS Code) update the preview in place.
- YAML front-matter renders as a styled two-column table at the top.
- Fenced code blocks get a hover-revealed copy button: one click copies the block to the clipboard and flashes a checkmark.
- Toggle to a plain-text editor with 500ms auto-save (`Cmd+E`).
- `Cmd+F` find, `Cmd+=` / `Cmd+-` / `Cmd+0` font zoom, clickable URLs, task-list checkboxes.

### Diff

Open a git diff in a pane: `nex diff [<path>]` from the CLI, the inspector plus/minus button, or the `open_diff` action (bindable, default unbound).

- GitHub-style colours, line-by-line classifier.
- Each file collapses into a `<details>` block with a sticky header that pins as you scroll through its hunks.
- Refresh on focus, or hit the header refresh button.

### Scratchpad

In-memory plain-text pane for jotting notes that should NOT touch disk. Created with `Cmd+Shift+N`. Contents vanish when the pane closes.

### Web pane (in-app browser)

A full WebKit browser pane with multi-tab support and an actuator surface for agents.

- `Cmd+L` to focus the URL bar, `Cmd+T` new tab, `Cmd+W` close tab, `Cmd+Shift+]` / `[` cycle tabs.
- Private mode per pane (`nex web private on`) with isolated storage.
- An agent in a neighbouring pane can drive the browser via `nex web` (see CLI section): click, type, scroll, capture screenshots, dump DOM, exec JS, wait for selectors, batch-inspect, drain the console buffer, arm an element picker.

## AI agent integration

When Claude Code is running in a pane, Nex tracks its lifecycle via the four hooks installed in `~/.claude/settings.json`:

| Hook | What Nex does |
| --- | --- |
| `UserPromptSubmit` (`nex event start`) | Pane shows yellow "running" indicator |
| `Stop` (`nex event stop`) | Pane returns to idle; desktop notification if the user is not focused on the pane |
| `Notification` (`nex event notification`) | Pane shows blue "waiting for input"; dock badge increments; notification fires |
| `SessionStart` (`nex event session-start`) | Pane attaches to the new session ID |

Where the signal surfaces:

- **Pane headers** colour-code agent status (idle, running, waiting, error).
- **Menu bar icon** shows running and waiting counts across all workspaces. Click for a popover listing active panes; click a row to jump to it.
- **Dock badge** shows how many agents are waiting for input.
- **Desktop notifications** include "Open" and "Dismiss" actions and route you to the right pane.
- **Quit confirmation** lists running agents before letting `Cmd+Q` exit.

Manual setup (skip if `install-hooks.sh` did it):

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "nex event stop" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "nex event notification" }] }],
    "SessionStart": [{ "matcher": "startup|resume|clear|compact", "hooks": [{ "type": "command", "command": "nex event session-start" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "nex event start" }] }]
  }
}
```

## Git and worktrees

### Repo registry

**Settings > Repositories** lets you register every repo Nex should know about, either individually or by scanning a directory recursively. Registered repos are available when creating workspaces.

### Worktrees

When creating a workspace you can attach one or more registered repos and optionally create a fresh worktree per repo. The base path is configurable in **Settings > General** (default `~/nex/worktrees/<repo>`). Use `<repo>` as a placeholder for the repo root, e.g. `<repo>/.claude/worktrees/<branch>`.

### Graft (worktree-to-root mirroring)

Toggle graft on a repo association from the inspector to mirror the worktree's working-tree changes back into the parent checkout in real time. Useful when you want to leave your IDE pointed at the main checkout while an agent works in a worktree. State, including checkpoint SHA and pre-graft branch, is captured so toggling off restores the parent to where it was. Orphaned breadcrumbs from interrupted sessions are detected on launch and surfaced as a recovery banner.

```bash
nex graft start   # attach the current pane's worktree to its parent repo
nex graft status  # human-readable, or --json for tooling
nex graft stop
```

### Live git status

Pane headers and the sidebar show the current branch with sub-second updates via a `.git/HEAD` watcher (no polling). The inspector shows added / modified / deleted counts.

## The `nex` CLI

`nex` is a small Swift CLI installed at `/usr/local/bin/nex` by the post-install helper. It speaks newline-delimited JSON over a Unix domain socket at `/tmp/nex.sock` (or TCP if configured).

```bash
nex --help          # full usage
nex --version
```

### Pane control

```bash
nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>]
nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>]
nex pane close  [--target <name-or-uuid>] [--workspace <name-or-uuid>]
nex pane name <name>
nex pane send  [--bare] --target <name-or-uuid> [--workspace <name-or-uuid>] <text...>
nex pane send-key --target <name-or-uuid> [--workspace <name-or-uuid>] <key>
nex pane capture [--target <name-or-uuid>] [--lines N] [--scrollback]
nex pane list    [--workspace <name-or-id> | --current] [--json] [--no-header]
nex pane move    [left|right|up|down]
nex pane move-to-workspace --to-workspace <name-or-uuid> [--create]
nex pane sync    on|off|toggle|status [--workspace <name-or-uuid>] [--json]
nex pane sync    exclude|include --target <name-or-uuid> [--workspace <name-or-uuid>]
nex pane id
```

`pane send` writes text then presses Enter; `pane send --bare` writes without Enter so you can compose multi-step input (`send --bare "ls /tm"` then `send-key tab`). `pane send-key` accepts `enter`, `tab`, `escape`, `space`, `backspace`, arrows, and `ctrl-c`. `pane capture` reads another pane's visible viewport (or full screen with `--scrollback`). `pane sync` is the tmux-style synchronise-input toggle: while on, a keystroke in any terminal pane is mirrored to every other terminal pane in the workspace; `sync exclude` opts a pane out of the group. New panes auto-join the active group; `Settings > Keybindings` exposes the `toggle_sync_input` action (default unbound) and there's a per-pane header button.

### Workspaces, groups, layouts

```bash
nex workspace create [--name "..."] [--path /dir] [--color blue] [--group <name>]
nex workspace move   <name-or-id> (--group <name> | --top-level) [--index N]
nex group create     <name> [--color blue]
nex group rename     <name-or-id> <new-name>
nex group delete     <name-or-id> [--cascade]
nex layout cycle | select <name>
```

### Files, diffs, graft

```bash
nex open  [--here] <path>     # markdown preview or terminal cd, --here reuses the calling pane
nex diff  [<path>]            # opens a diff pane for the current repo
nex graft start | stop | status [--json]
```

### Diagnostics

When `nex` commands stop reaching the app, run the doctor first:

```bash
nex doctor [--json]
```

It runs five named checks (`transport`, `socket`/`resolve`, `ping`, `process`, `version`) and prints a `[PASS|FAIL|WARN]` line plus a concrete repair tip for each failure: `ping` round-trips a real socket command, `process` distinguishes "Nex isn't running" from "Nex is wedged", and `version` flags CLI/app drift. Exits 0 when everything passes. Every other CLI error now prints a paired `Error: … / Repair: …` message; fire-and-forget event hooks stay exit-0 but emit a `Warning:` (silence with `NEX_SILENT=1`).

### Web pane automation

The web pane exposes a full set of semantic verbs so an agent can drive a real browser without screenshots-and-OCR. Selectors use `css:` or `xpath:` prefixes. Every verb except `web open` accepts `[--target <name-or-uuid>] [--workspace <name-or-uuid>]` to address a specific pane; omitted, they resolve relative to the calling pane via `NEX_PANE_ID`. Label targets called from outside a Nex pane need explicit `--workspace`.

Infrastructure (open / navigate / tabs / capture / private mode / cookies):

```bash
nex web open      [--private] <url>              # always creates a NEW pane
nex web navigate  <url>                          # redirect the active tab in an existing pane
nex web url | back | forward
nex web reload    [--hard]
nex web capture   [--mode meta|text|screenshot]
nex web tabs      [--json] [--no-header]
nex web tab-new   [<url>] [--no-focus]
nex web tab-select <ref>
nex web tab-close  <ref>
nex web private   on|off
nex web cookies   list|clear|delete [...]
```

Agent-facing inspection + automation:

```bash
nex web click  <selector> [--double] [--right] [--at x,y]
nex web type   <selector> <text> [--submit] [--no-replace]
nex web text   <selector> [--max-bytes N]
nex web attr   <selector> <attribute>
nex web count | exists <selector>
nex web dom    <selector> [--max-bytes N]
nex web wait   (--selector <sel> | --url-match <substr-or-regex>) [--for visible|hidden|exists|count=N|text=X] [--timeout 10]
nex web select <selector> <value-or-label>
nex web scroll <selector> [--top|--bottom|--smooth]
nex web hover  <selector>
nex web key    <key-name> [--selector <sel>]
nex web exec   (--file <path> | <js>) [--timeout 30]
nex web console        [--since N] [--level log|debug|info|warn|error] [--clear] [--json]
nex web inspect        [--send-to <pane>] [--submit] [--disarm]
nex web inspect-result [--clear] [--json]
```

### Remote / containerised usage

Set `tcp-port = <port>` in `~/.config/nex/config` to bind a TCP listener on `127.0.0.1`. Then point the CLI at it:

```bash
# From a dev container:
NEX_SOCKET=tcp:host.docker.internal:19400 nex pane list

# Over SSH (forward Nex's socket back to your laptop):
ssh -R 19400:localhost:19400 remote-host
# then on the remote:
NEX_SOCKET=tcp:127.0.0.1:19400 nex event stop
```

Loopback only by design. Use SSH tunnels for remote auth.

## Keybindings

All shortcuts are listed and rebindable in **Settings > Keybindings** with a visual key recorder. The same map is editable as text in `~/.config/nex/config` using Ghostty-style syntax:

```
keybind = super+shift+x=split_right
keybind = ctrl+alt+right=focus_next_pane
keybind = super+d=unbind
```

Defaults at a glance:

| Action | Default |
| --- | --- |
| New workspace | `Cmd+N` |
| New group | `Cmd+Shift+G` |
| New scratchpad | `Cmd+Shift+N` |
| Command palette | `Cmd+P` (`w:` / `p:` to scope to workspaces or panes) |
| Open markdown file | `Cmd+O` |
| Switch to workspace 1 to 9 | `Cmd+1` to `Cmd+9` |
| Next / previous workspace | `Cmd+Opt+Down` / `Cmd+Opt+Up` |
| Toggle sidebar / inspector | `Cmd+Shift+S` / `Cmd+I` |
| Split right / down | `Cmd+D` / `Cmd+Shift+D` |
| Close pane | `Cmd+W` |
| Reopen closed pane | `Cmd+Shift+T` |
| Focus next / previous pane | `Cmd+]` / `Cmd+[` (also `Cmd+Opt+Arrow`) |
| Move pane in direction | `Ctrl+Shift+Arrow` |
| Toggle zoom | `Cmd+Shift+Return` |
| Cycle layout | `Cmd+Shift+Space` |
| Toggle markdown edit | `Cmd+E` |
| Markdown font zoom | `Cmd+=` / `Cmd+-` / `Cmd+0` |
| Find in pane | `Cmd+F` |
| Rename active workspace | `Cmd+Shift+R` |

### Global hotkey

A single system-wide hotkey to bring Nex forward from any app. Configure in **Settings > Keybindings > Global** or:

```
global-hotkey = opt+shift+x
global-hotkey-hide-on-repress = true
```

No Accessibility permission is required. Only works while Nex is running.

## Configuration

`~/.config/nex/config` follows Ghostty's `key = value` syntax. General settings:

```
focus-follows-mouse = true
focus-follows-mouse-delay = 80
theme = Tokyo Night
tcp-port = 19400
global-hotkey = opt+shift+x
global-hotkey-hide-on-repress = true
```

Plus any number of `keybind = ...` lines.

**Settings panes:**

- **General.** Worktree base path, focus-follows-mouse delay, new-group placement.
- **Appearance.** Background opacity and tint.
- **Repositories.** Repo registry; scan a directory or add one-by-one.
- **Keybindings.** All actions with conflict detection and per-action reset.

## Persistence

State lives at `~/Library/Application Support/Nex/nex.db` (SQLite via GRDB). Workspaces, panes, layouts, repo associations, and app state are debounced-serialised on every change and restored on launch.

## Running tests

```bash
xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation test

# Or a single suite:
xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation \
  -only-testing:NexTests/PaneLayoutTests test
```

`make check` runs format-check, lint, build, and test in one shot.

## Issues and contributions

Bugs and feature requests live in [GitHub Issues](https://github.com/benfriebe/nex/issues). PRs welcome.

See [`CLAUDE.md`](CLAUDE.md) for architecture, reducer hierarchy, dependency wiring, and the full pane-command wire protocol.
