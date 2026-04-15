# Nex

A Mac-native terminal workspace multiplexer for polyrepo development with AI agents.

Nex gives you named, persistent terminal workspaces with free-form split layouts, git worktree management across multiple repos, and first-class monitoring for AI coding agents like Claude Code. Switching workspaces is instant. Agents get noticed when they need you.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16+ with Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [Zig](https://ziglang.org/) 0.13+ (only if rebuilding libghostty)

## Installation

### From a release

1. Download `Nex.zip` from the latest release
2. Unzip and move `Nex.app` to `/Applications`
3. Run the hook installer to enable Claude Code integration:

```bash
/Applications/Nex.app/Contents/Resources/scripts/install-hooks.sh
```

This installs the `nex` CLI to `/usr/local/bin` and configures Claude Code hooks in `~/.claude/settings.json`.

### Building from source

Clone the repo with submodules:

```bash
git clone --recurse-submodules https://github.com/anthropics/nex2.git
cd nex2
```

Generate the Xcode project and build:

```bash
xcodegen generate --spec project.yml
xcodebuild -scheme Nex -skipMacroValidation build
```

The `-skipMacroValidation` flag is required for TCA's Swift macros.

#### Rebuilding libghostty

A prebuilt `lib/libghostty.a` is included. To rebuild from the ghostty submodule:

```bash
cd ghostty
zig build -Dapp-runtime=none -Doptimize=ReleaseFast
```

Then copy the output (the exact hash path will vary):

```bash
cp .zig-cache/o/<hash>/libghostty-fat.a ../lib/libghostty.a
```

## Setup

### Claude Code hooks

Nex monitors Claude Code sessions through hooks. The install script configures these automatically, but you can set them up manually by adding the following to `~/.claude/settings.json`:

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

Restart any running Claude Code sessions after configuring hooks.

### Ghostty config

Nex uses [libghostty](https://github.com/ghostty-org/ghostty) for terminal rendering and inherits your Ghostty configuration from `~/.config/ghostty/config`. Font, colors, scrollback, and other terminal settings are read from there.

### Repo registry

Open **Settings > Repositories** to add repos Nex should know about. You can scan a directory to discover repos recursively, or add them individually. Registered repos are available when creating workspaces and associating worktrees.

## Usage

### Workspaces

Workspaces are the core unit in Nex. Each workspace is a named context with its own terminal layout, repo associations, and running processes. Right-click a workspace in the sidebar to rename it, change its color, or delete it.

### Panes

Each workspace contains one or more terminal panes in a split layout. Drag split dividers to resize. Pane headers show the working directory and current git branch. Panes can be split, closed, moved, zoomed, and focused via keyboard shortcuts.

### Markdown panes

Open a markdown file with the open file shortcut or drag-and-drop a `.md` file onto the window. The file renders in a styled preview with live file watching — edits from external tools (Vim, VS Code, etc.) update the preview automatically. Toggle to a plain-text editor with auto-save (500ms debounce). Scroll position is preserved when toggling between modes. Markdown panes support the same layout operations as terminal panes — splitting, closing, dragging, and reopening.

### UI panels

The sidebar shows workspaces. The inspector shows repo associations, worktree info, and git status for the current workspace.

### Agent monitoring

When Claude Code runs in a Nex pane, pane headers update to reflect agent status (idle, running, waiting for input, error). Nex surfaces this information in several ways:

- **Desktop notifications** when an agent finishes or needs input, with "Open" and "Dismiss" actions
- **Menu bar icon** showing counts of running and waiting agents
- **Menu bar popover** listing active panes by workspace — click to switch
- **Dock badge** showing how many agents are waiting for input

Notifications clear automatically when you focus the app.

### Worktrees

Workspaces can be associated with git worktrees across multiple repos. When creating a workspace, pick repos from the registry and optionally create new worktrees. The base path for worktrees is configurable in **Settings > General** (defaults to `~/nex/worktrees/<repo>`). Use the `<repo>` placeholder to substitute the repository root (e.g., `<repo>/.claude/worktrees`).

### Keyboard shortcuts

All keyboard shortcuts are viewable and customizable in **Settings > Keybindings**. They can also be configured via a config file at `~/.config/nex/config` using Ghostty-style syntax:

```
keybind = super+shift+x=split_right
keybind = super+d=unbind
keybind = ctrl+alt+right=focus_next_pane
```

You can also edit keybindings in **Settings > Keybindings** with a visual key recorder.

Available actions: `new_workspace`, `open_file`, `switch_to_workspace_1`–`9`, `toggle_sidebar`, `toggle_inspector`, `split_right`, `split_down`, `close_pane`, `focus_next_pane`, `focus_previous_pane`, `next_workspace`, `previous_workspace`, `toggle_markdown_edit`, `toggle_zoom`, `reopen_closed_pane`, `toggle_search`, `close_search`, `cycle_layout`, `move_pane_left`, `move_pane_right`, `move_pane_up`, `move_pane_down`.

### Settings

Open settings with `Cmd+,`. Available options:

- **General**: Worktree base path
- **Appearance**: Background opacity, background color
- **Repositories**: Manage the repo registry
- **Keybindings**: View and customize keyboard shortcuts

## Data

Nex stores its database at `~/Library/Application Support/Nex/nex.db`. All workspaces, panes, layouts, and repo associations are persisted there and restored on launch.

## Running tests

```bash
xcodebuild -scheme NexTests -skipMacroValidation test
```
