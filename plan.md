# Nexus — Design Plan

**A Mac-native workspace multiplexer for polyrepo development with AI agents**

---

## Vision

Nexus is a Mac-native terminal workspace manager built for developers running multiple AI coding agents in parallel across a polyrepo. The core primitive is a **workspace** — a named, persistent context that bundles a free-form terminal layout, one or more git worktrees (across multiple repos), a set of running processes and agents, and a notification routing configuration. Switching workspaces is instant and deterministic. Agents get noticed when they need you.

Nexus is a **primitive, not a framework** — it doesn't dictate how you code, which agent you use, or how you structure your repos. It gives you the switching, the visibility, and the alerting.

---

## Core Concepts

### Workspace

The top-level unit in Nexus. A workspace is:

- A **named context** with an optional description and color label
- A collection of **terminal panes** in a free-form split layout (user-defined, persisted)
- Zero or more **repo/worktree associations** (a workspace can span multiple repos)
- A set of **tracked processes** (shells, agents, dev servers — anything running in its panes)
- A **notification profile** (what to alert on, how urgently)

Workspaces are lightweight and fast to create. They range from a single shell reviewing a PR to four terminals across three repos running parallel Claude Code agents.

### Pane

A terminal emulator surface inside a workspace. Panes can be split freely — horizontal or vertical — with no depth limit. Each pane has:

- Its own PTY process (shell, agent, or any CLI tool)
- A **type tag**: `shell`, `agent:claude`, `agent:codex`, `server`, `log` (used for notification routing and visual differentiation)
- An optional **label** shown in the pane header
- A **status indicator**: idle / running / waiting-for-input / error

### Repo Registry

A global list of all repos Nexus knows about (~63 repos in your case). Each registry entry stores:

- Local path on disk
- Remote URL (for display and GitHub integration)
- Friendly name / alias

Repos are added once and then available to associate with any workspace. Quick-add via fuzzy search. Repos do not need to be open — the registry is just a known list.

### Worktree Association

A workspace can associate **any number of repo+worktree pairs**. Each association is:

- A registry repo
- A specific worktree path within that repo (or the main working tree)
- An optional branch label for display

When you create a new workspace, you can create new worktrees (in one or multiple repos), link existing ones, or associate none at all. Nexus does not force worktree creation — you choose per workspace.

### Agent Process

Any pane running Claude Code or OpenAI Codex CLI gets first-class treatment. Nexus watches its PTY output stream for signals:

- **OSC 9/99/777 escape sequences** (used by Claude Code, cmux, and others for notifications)
- **Prompt pattern matching** (regex-based detection of "Do you want to proceed?" and similar)
- **Silence detection** (process has produced no output for N seconds — likely waiting)
- **Exit codes** (clean exit, error exit)

These signals drive the notification system.

---

## Application Architecture

### Tech Stack

| Layer | Technology | Rationale |
|---|---|---|
| App framework | Swift + SwiftUI | App lifecycle, windows, menus, settings |
| Window layout | HStack (sidebar + pane grid) | Manual layout avoids NavigationSplitView toolbar chrome |
| Terminal surfaces | AppKit (`NSView`) | Fine-grained control for rendering and keyboard events |
| Terminal emulation | libghostty (via C-ABI) | GPU-accelerated, VT-compliant|
| Rendering | Metal | GPU-accelerated text and UI rendering via libghostty |
| PTY management | `openpty()` via Darwin | Standard macOS PTY, avoids `forkpty()` fork-safety issues |
| State management | The Composable Architecture (TCA) | Unidirectional flow, composable reducers |
| Persistence | SQLite via GRDB.swift | Workspace state, repo registry, layout snapshots |
| Notifications | `UNUserNotificationCenter` + `NSStatusItem` | Full macOS notification stack |
| CLI companion | Swift ArgumentParser binary (`nexus`) | Scriptable workspace/pane control, agent hook integration |
| Auto-update | Sparkle | Standard Mac app update mechanism |

### Process Model

```
Nexus.app
├── Main process (SwiftUI)
│   ├── WorkspaceStore (TCA) — all workspace/pane state
│   ├── RepoRegistry — SQLite-backed list of known repos
│   ├── NotificationRouter — routes agent signals to alert tiers
│   ├── AgentWatcher — per-pane PTY stream observer
│   └── StatusBarController — NSStatusItem for menu bar
│
├── PTY processes (one per pane, forked children)
│   └── Shell / Claude Code / Codex CLI / any process
│
└── nexus CLI (companion binary, communicates via Unix socket)
    └── /tmp/nexus.sock — JSON protocol (create, switch, notify, status)
```

### State Model (TCA)

```swift
struct AppState {
    var workspaces: IdentifiedArrayOf<Workspace>
    var activeWorkspaceID: Workspace.ID?
    var repoRegistry: IdentifiedArrayOf<Repo>
    var notificationSettings: NotificationSettings
}

struct Workspace {
    var id: UUID
    var name: String
    var color: WorkspaceColor
    var panes: IdentifiedArrayOf<Pane>
    var layout: PaneLayout          // serialized split tree
    var repoAssociations: [RepoAssociation]
    var agentCount: Int             // derived
    var waitingCount: Int           // derived — agents needing input
}

struct Pane {
    var id: UUID
    var label: String?
    var type: PaneType              // .shell / .agent(AgentKind) / .server / .log
    var title: String?              // live terminal title from OSC 0/2
    var status: PaneStatus          // .idle / .running / .waitingForInput / .error (Phase 3)
    var workingDirectory: String    // live CWD from OSC 7
    var lastActivityAt: Date
}

struct RepoAssociation {
    var repoID: Repo.ID
    var worktreePath: String
    var branchName: String?
}
```

---

## UI Design

### Window Layout

```
┌─────────────────────────────────────────────────────────────┐
│ ● ● ●   Nexus                              [status bar icon] │
├──────────┬──────────────────────────────────────────────────┤
│          │                                                   │
│ WORK-    │                                                   │
│ SPACES   │         Active Workspace — Pane Area              │
│          │         (free-form splits, user-controlled)       │
│ ● auth   │                                                   │
│   2 panes│                                                   │
│   2 repos│                                                   │
│          │                                                   │
│ ● api-v2 │                                                   │
│   3 panes│                                                   │
│   1 repo │                                                   │
│          │                                                   │
│ 🟡 PR #82│                                                   │
│   1 pane │                                                   │
│          │                                                   │
│ ⚠ infra  │                                                   │
│   4 panes│                                                   │
│   3 repos│                                                   │
│          │                                                   │
│  [+ New] │                                                   │
└──────────┴──────────────────────────────────────────────────┘
```

### Workspace Sidebar

- Vertical list of all workspaces, ordered by last-accessed
- Each row shows: color dot, name, pane count, repo count
- Status indicators: 🟢 all idle, 🟡 agent running, ⚠ agent waiting for input, 🔴 error
- Badge count on tab shows number of agents waiting for input
- Click to switch instantly (layout and all PTY sessions are preserved)
- Right-click context menu: rename, duplicate, delete, view repos

### Pane Area

- Free-form splits via keyboard shortcuts and drag handles (no predetermined layouts)
- Each pane has a slim header bar: label | type badge | status dot | cwd (truncated) | close button
- Agent panes get a distinct header color and animated status indicator
- Pane status dot pulses amber when waiting for input
- Right-click pane header: rename, change type, split right, split down, close

### New Workspace Flow

1. Press `⌘N` or click `[+ New]` in sidebar
2. Sheet slides up: enter name, pick color label
3. Optional: associate repos
   - Fuzzy search across all 63 registered repos
   - For each added repo: choose existing worktree, create new worktree (enter branch name), or just associate root
4. Workspace opens with one empty shell pane in the associated directory (or `~` if none)

### Workspace Inspector (⌘I)

Slide-in panel showing the current workspace's full context:

- Name, color, creation date
- Repo associations — each shows repo name, worktree path, branch, quick-open button
- Running processes — list of all panes with PID, uptime, status
- Git status summary per associated repo (branch, dirty files, ahead/behind)

---

## Notification System

### Four-Tier Architecture

Notifications are dispatched based on **app focus state** and **alert tier**.

**Tier 1 — Always visible (in-app)**
- Pane header status dot changes color: grey (idle) / blue (running) / amber (waiting) / red (error)
- Workspace sidebar badge: amber number badge showing count of waiting agents in that workspace
- Sidebar row color shifts amber when any agent is waiting

**Tier 2 — App unfocused, gentle**
- Menu bar `NSStatusItem` icon changes: Nexus icon with a small amber dot overlay
- Menu bar popover (click to expand) shows a list of waiting agents with workspace names
- Dock badge: count of total agents across all workspaces waiting for input

**Tier 3 — App unfocused, urgent (needs input)**
- macOS `UNUserNotificationCenter` banner: "Nexus — [workspace name]: Claude Code is waiting for your input"
- Notification has two action buttons: **Open** (switches to that workspace) and **Dismiss**
- Dock icon bounces once (`NSApp.requestUserAttention(.informationalRequest)`)

**Tier 4 — Critical (permission prompt or blocking error)**
- Same as Tier 3 but with `.criticalRequest` (sustained dock bounce)
- Notification is persistent (does not auto-dismiss)
- Sound: distinct from Tier 3

### Signal Detection

How Nexus knows an agent needs input:

1. **OSC escape sequences** — Claude Code emits OSC 9;9 (and variants) when it wants notification. Nexus parses these from the raw PTY byte stream before they reach the terminal renderer.
2. **Prompt pattern matching** — configurable regex list, defaults include patterns like `Do you want to`, `Press Enter to`, `[y/n]`, `[Yes/No]`. User can add custom patterns per agent type.
3. **Silence + cursor position** — if an agent pane has produced no output for 8 seconds AND the VT cursor is on a line ending with a prompt character, treat as potential waiting state (lower confidence, shown as Tier 1 only).
4. **Claude Code hooks** — the `nexus` CLI provides a `nexus notify` command usable as a Claude Code hook: `claude --notify-command "nexus notify --workspace current --level input"`. This is the most reliable path and should be documented as the recommended setup.

### Anti-Fatigue Rules

- **De-duplicate**: if a pane fires a waiting signal and is already in "waiting" state, no new notification is emitted
- **Focus suppression**: Tier 2/3/4 notifications are suppressed when Nexus is the frontmost app AND the relevant workspace is active
- **Cooldown**: minimum 30 seconds between Tier 3 notifications for the same pane (configurable)
- **Completion ≠ Waiting**: "agent finished" and "agent needs input" are distinct signals with distinct UI treatment. Completion gets a subtle Tier 1 indicator only (green flash). Only genuine input requests escalate.

---

## Git Worktree Integration

### Multi-Repo Worktree Model

Each workspace can hold multiple repo associations. For a workspace spanning repos A, B, and C:

```
Workspace: "auth-overhaul"
├── Repo: api-service     → /repos/api-service/.worktrees/auth-overhaul  (branch: feat/auth-overhaul)
├── Repo: web-app         → /repos/web-app/.worktrees/auth-overhaul       (branch: feat/auth-overhaul)
└── Repo: shared-types    → /repos/shared-types (main tree)               (branch: main, read-only)
```

### Worktree Operations (built into Workspace Inspector)

- **Create worktree** — runs `git worktree add <path> -b <branch>` for a repo, configures the path, opens a pane cd'd there
- **Link existing worktree** — file picker pointed at the repo's worktree directory
- **Remove association** — detaches repo from workspace (does not delete the worktree)
- **Prune worktrees** — runs `git worktree prune` across all repos in the workspace

### Worktree Naming Convention (default, overridable)

```
<repo-root>/.worktrees/<workspace-name>
```

This keeps all worktrees co-located and predictably named. Configurable in settings.

### Git Status in Sidebar

Each workspace row in the sidebar shows a compact git summary:
- Green dot: all associated repos clean
- Amber dot: uncommitted changes in one or more repos
- Number badge: count of repos with changes

---

## Repo Registry

### Setup

On first launch, Nexus asks for a root directory. It scans for `.git` directories up to 3 levels deep and pre-populates the registry. For your 63 repos, this scan runs once and takes a few seconds.

### Registry UI (Preferences > Repositories)

- List of all registered repos with path, remote, last-accessed date
- Add repo manually (file picker or paste path)
- Scan directory again to pick up new repos
- Remove from registry (does not delete files)
- Set friendly alias for display in workspace sidebar

### Quick-Add to Workspace

When adding a repo to a workspace, a fuzzy search picker shows all 63 repos. Type a few characters to filter. Common repos surface first based on recent use.

---

## CLI Companion: `nexus`

The `nexus` binary installs to `/usr/local/bin/nexus` and communicates with the running app via `/tmp/nexus.sock` (JSON protocol). Designed for use in agent hooks, shell scripts, and automation.

### Commands

```bash
# Workspace management
nexus workspace list                          # List all workspaces with status
nexus workspace new --name "feat-x"           # Create workspace
nexus workspace switch "feat-x"               # Switch active workspace
nexus workspace status                        # JSON status of current workspace

# Pane control
nexus pane new --split right --cmd "claude"   # Open new pane with command
nexus pane list                               # List panes in current workspace
nexus pane focus <pane-id>                    # Focus a specific pane

# Notifications (for use in agent hooks)
nexus notify --level input                    # Signal: agent needs input
nexus notify --level done                     # Signal: agent completed task
nexus notify --level error --msg "Build fail" # Signal: error with message

# Repo/worktree
nexus repo list                               # List registry
nexus worktree add --repo api-service \
  --branch feat-x                             # Create + associate worktree
```

### Claude Code Hook Integration

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "command": "nexus notify --level input" }
    ],
    "PostToolUse": [
      { "matcher": "Bash", "command": "nexus notify --level done" }
    ]
  }
}
```

---

## Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| New workspace | ⌘N |
| Switch workspace (by number) | ⌘1 through ⌘9 |
| Switch to next/prev workspace | ⌘⇧] / ⌘⇧[ |
| Fuzzy-switch workspace | ⌘K |
| Split pane right | ⌘D |
| Split pane down | ⌘⇧D |
| Close pane | ⌘W |
| Focus next pane | ⌘⌥→ |
| Focus prev pane | ⌘⌥← |
| Open Workspace Inspector | ⌘I |
| Open Preferences | ⌘, |
| Jump to next waiting agent | ⌘⇧A |
| Toggle sidebar | ⌘⇧S |

---

## Build Phases

This is a solo build. The plan is sequenced so each phase ships something useful and each subsequent phase builds on a stable foundation.

---

### Phase 1 — Core Terminal + Workspace Switching ✅
**Goal**: A working terminal multiplexer with named workspaces. Nothing agent-specific yet.

- [x] Mac app skeleton: SwiftUI sidebar + AppKit terminal surface
- [x] libghostty integration (went straight to libghostty, skipped SwiftTerm)
- [x] PTY management via libghostty (openpty + process launching handled internally)
- [x] Free-form pane splits (horizontal + vertical, keyboard-driven + header buttons)
- [x] Workspace creation, naming, color labels
- [x] Workspace switching with full state persistence (layout + PTY sessions survive background)
- [x] SQLite persistence via GRDB (debounced PersistenceService + DatabaseService with migrations)
- [x] Basic keyboard shortcuts (⌘D split right, ⌘⇧D split down, ⌘W close, ⌘1-9 workspace switch, ⌘⇧S toggle sidebar)
- [x] Live pane titles via OSC 0/2 title + OSC 7 CWD tracking from ghostty action callbacks
- [x] Resizable sidebar with drag handle
- [x] Click-to-focus pane headers with split/close buttons
- [x] Settings window
- [x] Bell suppression + doCommand(by:) fix for NSBeep on action keys

**Deliverable**: Replace your current terminal workflow. Can run shells and normal CLI tools across multiple named workspaces.

---

### Phase 2 — Repo Registry + Worktree Association ✅
**Goal**: Workspaces understand your repos.

- [x] Repo registry (scan root dir on setup, manual add/remove)
- [x] Associate repos to workspaces (with fuzzy search picker)
- [x] Worktree creation and linking per workspace
- [x] Multi-repo worktree support per workspace
- [x] Workspace Inspector panel (repos, panes, git status)
- [x] Git status summary in sidebar (clean/dirty indicator)
- [x] Worktree naming convention + configurable base path

**Deliverable**: Create a workspace, associate 2–3 repos, create worktrees — all from one place.

---

### Phase 3 — Agent Awareness + Notifications
**Goal**: Nexus knows when agents are running and when they need you.

- Pane type tagging (agent:claude, agent:codex, shell, etc.)
- PTY stream watcher: OSC escape sequence parsing
- Prompt pattern matching (configurable regex)
- Silence + cursor detection (low-confidence fallback)
- Pane status model (idle/running/waiting/error) with visual indicators
- Tier 1 in-app indicators: pane header dots, sidebar badges
- Tier 2 menu bar status item (`NSStatusItem` with dynamic icon)
- Tier 3/4 macOS notifications (`UNUserNotificationCenter`) with action buttons
- Dock badge count
- Anti-fatigue rules (dedup, cooldown, focus suppression)
- `nexus notify` CLI command + Claude Code hook documentation

**Deliverable**: Run 4 Claude Code agents, go do something else, get notified exactly when you're needed.

---

### Phase 4 — CLI Companion + Polish
**Goal**: Nexus is fully scriptable and feels like a finished Mac app.

- Full `nexus` CLI binary with Unix socket protocol
- All workspace/pane/repo commands
- Preferences window (notification settings, worktree paths, prompt patterns, repo registry)
- Workspace templates (save current layout as a template for reuse)
- Improved sidebar: drag to reorder, group by project, archive
- Sparkle auto-update integration
- Onboarding flow (first launch repo scan, hook setup guide)
- Menu bar app mode (optional — hide dock icon, live in menu bar only)

**Deliverable**: Nexus is your daily driver. Everything is scriptable and configurable.

---

### Phase 5 — Quality of Life
**Goal**: The features that make it genuinely great to use daily.

- Cross-workspace agent status overview (global "waiting agents" view)
- Workspace search/filter in sidebar
- Terminal scrollback search within panes
- pane broadcast mode (type in one pane, send to all panes — useful for running a command across all repo worktrees simultaneously)
- Quick worktree cleanup (archive workspace + prune all associated worktrees)
- GitHub PR association per workspace (show PR status in inspector)
- `nexus` CLI shell completions (zsh, fish)

---

## Resolved Questions

**1. libghostty vs SwiftTerm** — Resolved: went straight to libghostty for Phase 1. Zig toolchain and C interop were manageable. GPU rendering and VT compliance worth the upfront cost.

**2. Session persistence model** — Resolved: restore layout and cwd, launch fresh shells on reopen. True session persistence deferred to Phase 5.

## Open Questions

**1. Notification opt-in per workspace**
Some workspaces (e.g. a quick PR review terminal) don't need agent notifications at all. The workspace should have a notification profile setting: "all", "agents only", or "off". Implement in Phase 3.

**2. Codex CLI signal detection**
OpenAI Codex CLI's exact escape sequence and prompt patterns need to be verified against the current CLI version before the Phase 3 watcher is built. This is a small research spike before Phase 3 starts.

---

## Reference: Ecosystem Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Terminal engine | libghostty | GPU-accelerated, VT-compliant, used from Phase 1 |
| State management | TCA | testable concurrent state |
| Persistence | SQLite/GRDB | Better than UserDefaults for workspace state; simpler than CoreData |
| IPC | Unix domain socket (JSON) | simple, scriptable, no framework dependency |
| Notification detection | OSC sequences + regex + silence | Layered approach handles all agent types including future ones |
| Worktree convention | `<repo>/.worktrees/<workspace-name>` | Co-located, predictable, easy to clean up |
| Build tooling | Xcode + Swift Package Manager | Standard Mac app toolchain; no Electron/web layer |