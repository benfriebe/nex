---
name: nex-agentic
description: >
  Use the Nex terminal multiplexer and its CLI to orchestrate multi-agent
  development workflows. Enables spawning named child panes, starting Claude
  agents in them, farming out parallel work, coordinating results via markdown
  files and direct pane messaging, AND driving / observing a web app from an
  agent via the `nex web` pane (open URL, capture page text or screenshot,
  drain console buffer, arm element picker to paste structured payloads into
  an agent pane). Trigger when: the user asks to "spawn agents", "fan out
  work", "create worker panes", "orchestrate panes", "use nex to coordinate",
  "multi-agent", "farm out tasks", or any variation of parallelizing work
  across Nex panes. Also trigger when an agent needs to "drive the browser",
  "watch the page console", "capture a screenshot of the app", "pick an
  element from the page", or coordinate with the web pane in any way.
---

# Nex Agentic Development Skill

Orchestrate multi-agent development workflows using the Nex terminal
multiplexer. Spawn named child panes, start Claude agents in them, distribute
work, and collect results.

## Prerequisites

You must be running inside a Nex pane. Verify with:

```bash
nex pane id
```

Exit 0 with the pane UUID on stdout means you're in Nex; exit 1 with
empty output means you're not, and every other `nex` command below will
silently no-op. This command is purely local (no socket, no shell `$`
expansion) so it allowlists cleanly as `Bash(nex pane id)`.

## Required up-front questions

Before spawning any panes, confirm two choices with the user. Skip a
question only if the answer is unambiguous from the invoking prompt
(e.g. "spawn headless workers with --dangerously-skip-permissions").
Otherwise ask via `AskUserQuestion` — do not assume defaults.

1. **Execution mode** — headless or interactive?
   - **Headless** (`claude -p "<prompt>"`): non-interactive, runs to
     completion, exits when done. Best for fan-out: workers write
     result files, coordinator polls. Default for most automation.
   - **Interactive** (`claude` then `pane send` the prompt): Claude
     stays open in the pane for follow-ups. Use when the user wants to
     supervise, iterate, or intervene mid-task.

2. **Permission mode** — which `--permission-mode` flag?
   - `default` — prompt on each tool use (safest; requires the user to
     babysit each worker)
   - `acceptEdits` — auto-accept file edits, still prompt on Bash/other
   - `plan` — planning only, no writes
   - `auto` — auto-approves all tool calls with background safety
     checks. Covers Bash/Edit/Read/web, unlike `acceptEdits` which is
     file-writes only. Good middle ground for trusted fan-outs that
     still want some guardrails
   - `bypassPermissions` (aka `--dangerously-skip-permissions`) — full
     autonomy, no prompts, no checks. Common for trusted fan-outs in
     worktrees or sandboxed VMs
   - `dontAsk` — auto-denies any tool not pre-approved via
     `/permissions` or an allowlist. Strictest mode for unattended
     orchestration with an explicit whitelist; non-whitelisted calls
     silently fail

Ask both in a single `AskUserQuestion` call with two questions. Record
the answers and reuse them for every worker spawn in the session unless
the user changes them.

Once chosen, the worker-start command shape is:

```bash
# Headless
nex pane send --target worker-1 claude -p --permission-mode <mode> "<prompt>"

# Interactive
nex pane send --target worker-1 claude --permission-mode <mode>
sleep 2
nex pane send --target worker-1 "<prompt>"
```

## Nex CLI Reference

The `nex` CLI communicates with the Nex app over a Unix socket at `/tmp/nex.sock`.

### Pane Commands

```bash
# Split a pane (creates a new pane alongside). Works from outside Nex
# via --target (UUID = global, label needs scope) or --workspace.
# Request/response: prints the new pane id, exits non-zero on failure.
nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--json]

# Create a new pane (alias for horizontal split). Works from outside Nex
# via --workspace (or --target's workspace). Request/response: prints the
# new pane id, exits non-zero on failure.
nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--json]

# Close current pane
nex pane close

# Set a label on a pane (visible as pill badge in title bar). Without
# --target, renames the calling pane; with --target, renames any pane.
nex pane name [--target <name-or-uuid>] [--workspace <name-or-uuid>] <label>

# Send text to another pane (typed into its PTY + Enter)
# Label resolution is scoped to the sender's own workspace by default.
# Pass --workspace <name-or-id> to target another workspace
# or to disambiguate a label collision; UUID targets are always global.
# `--bare` writes the text without appending Enter — pair with
# `pane send-key` for compositional flows (autocomplete with `tab`,
# escape sequences, partial input, paste-safe structured content).
nex pane send [--bare] [--json] --target <label-or-uuid> [--workspace <name-or-uuid>] <command...>

# List panes (only command that returns data — use for reconciliation)
nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]

# Read another pane's terminal contents as text (viewport, or full
# scrollback with --scrollback). WITHOUT --target it captures the CALLING
# pane — always pass --target to read a worker. The target is flag-only:
# a bare `nex pane capture <uuid>` is rejected, not treated as --target.
nex pane capture [--target <name-or-uuid>] [--workspace <name-or-uuid>] [--lines N] [--scrollback]

# Move a pane to another workspace (creates it with --create).
nex pane move-to-workspace --to-workspace <name-or-uuid> [--create]

# Print current pane's UUID (local; no socket). Exit 1 if not in Nex.
nex pane id
```

### `nex doctor` — when CLI commands stop working

If `nex` commands suddenly start failing with `Error: nex …: cannot reach
Nex …` or `no response from Nex`, run `nex doctor` first.
It runs five named checks and prints `[PASS|FAIL|WARN] <name>: <detail>`
plus a concrete repair line for any failure:

- `transport` — Unix socket path or TCP destination in use.
- `socket` / `resolve` — file exists on disk (Unix) or hostname resolves (TCP).
- `ping` — round-trip a `ping` command and parse the JSON reply.
- `process` — `pgrep` for `Nex.app`. If `ping` failed but the process is up,
  the app is wedged (restart it); if no process, Nex isn't running.
- `version` — CLI version vs running-app version. Warn on drift (rebuild Nex).

Pass `--json` for a machine-readable report. Exit 0 if all checks pass,
non-zero if any failed. Use this as the first triage step before
restarting the app.

Every CLI error now emits an `Error: …\nRepair: …` pair pointing at the
matching repair step. Fire-and-forget commands (`nex event …`, hooks)
print a `Warning: …` to stderr but still exit 0 so Claude Code Stop
hooks etc. don't break — set `NEX_SILENT=1` to suppress entirely.
`nex event …` (the Claude Code hook entrypoint) suppresses the warning
by default to avoid stderr spam when Nex is closed; set
`NEX_VERBOSE_HOOKS=1` to surface them again.

### `pane list` — reconcile with live state

`pane list` is the only Nex command that returns data. Use it whenever a
coordinator needs to know what panes actually exist right now — panes can
be closed by the user, crash, or be moved between workspaces. `pane send`
exits non-zero with a structured error on a missing/ambiguous target,
but checking `pane list` first lets a coordinator skip
sends to dead workers and surface a clearer message.

```bash
# Human-readable (default)
nex pane list

# JSON for scripts — stable shape, exit code encodes success
nex pane list --json

# Only panes in the current pane's workspace (requires NEX_PANE_ID)
nex pane list --current

# Only panes in a named workspace
nex pane list --workspace nex
```

Each JSON entry includes: `id`, `label`, `type` (`shell` / `markdown` /
`scratchpad` / `diff` / `web`), `title`, `workspace_id`, `workspace_name`,
`working_directory`, `git_branch`, `status` (`idle`/`running`/
`waitingForInput`), `agent_session_id`, `is_focused`,
`is_active_workspace`, `created_at`, `last_activity_at`.

Exit codes: `0` on success (including empty list), `1` on usage error,
transport failure, or `ok: false` from the server. Empty output with
exit `1` and `"upgrade required"` on stderr means the running Nex is
older than v0.20 and doesn't support `pane list`.

Common recipes:

```bash
# All labels of your workers
nex pane list --json | jq -r '.[].label | select(startswith("worker-"))'

# Which workers are still alive?
alive=$(nex pane list --json | jq -r '.[].label')
for w in worker-1 worker-2 worker-3; do
  echo "$alive" | grep -qx "$w" && echo "$w: alive" || echo "$w: gone"
done

# Agent status across a fan-out
nex pane list --json | jq -r '.[] | select(.label | startswith("worker-"))
  | "\(.label)\t\(.status)"'

# Find a specific pane's UUID before a `pane send`
uuid=$(nex pane list --json | jq -r '.[] | select(.label == "build") | .id')
```

### Event Commands (Agent Lifecycle)

```bash
nex event start                    # Signal agent started
nex event stop                     # Signal agent stopped
nex event error --message "..."    # Signal error
nex event notification --title "..." --body "..."  # Desktop notification
nex event session-start            # Attach the pane to a Claude session id (SessionStart hook)
nex event session-end              # Detach the session id so an exited session isn't resumed (SessionEnd hook)
```

`session-start` / `session-end` read the `session_id` from the hook's
stdin JSON and are wired to Claude Code's `SessionStart` / `SessionEnd`
hooks by `install-hooks.sh`. `session-end` clears the pane's tracked
session id (only when it still matches the ending session) so Nex does
not `claude --resume` a session that has already exited.

### Workspace Commands

```bash
# Create a workspace (request/response). Replies with the new workspace's
# id — `created workspace <name> (<uuid>)`, or the raw {ok,workspace_id,
# workspace_name,group?} object with --json — so a coordinator can capture
# the id to target it later. --group creates the group if missing.
nex workspace create [--name "..."] [--path /dir] [--color blue|green|red|yellow|purple|orange|pink|gray] [--group <name>] [--json]

# Delete one or more workspaces by name-or-id (request/response). Deletes
# outright — no CLI prompt — closing any remaining panes. Refuses to
# delete the last remaining workspace. Exits non-zero if any delete fails.
#   --force / -y      delete even if the workspace has RUNNING AGENTS.
#                     Without it, a workspace with active agents
#                     (running/waiting panes) is refused (mirrors the
#                     app-quit warning); the reply carries `active_agents`.
#                     In the GUI this is a "Delete anyway?" dialog with a
#                     "Don't ask again" checkbox instead.
#   --prune-worktree  also `git worktree remove` the deleted workspace's
#                     directory. Best-effort + non-forcing: git refuses a
#                     dirty/locked worktree or the main checkout (a Warning,
#                     not a failure). An *empty* workspace has no directory
#                     to prune — delete it before closing its panes if you
#                     want the worktree reclaimed automatically.
#   --json            compact per-id result array: each row has `id` (the
#                     arg as typed), `ok`, and on success `workspace_id`,
#                     `workspace_name`, `path?`, `worktree_pruned?`,
#                     `worktree_error?` — or `error` on failure.
# Exit code reflects DELETES only: a prune that git refuses is a Warning,
# not a failure, so the command still exits 0 if the workspace was deleted.
nex workspace delete <name-or-id> [<name-or-id> ...] [--force|-y] [--prune-worktree] [--json]
```

### File Commands

Open a file in the right pane type — handy for surfacing a worker's
output (a rendered report, a diff, an HTML artifact) to the human
without leaving Nex. Relative paths resolve against the caller's cwd,
and the pane lands in the caller's workspace (via `NEX_PANE_ID`).

```bash
# Generic opener: a URL/hostname opens a web pane; otherwise routes a
# local file by its extension.
#   URL / hostname                          → web pane
#     (scheme://, host:port, localhost[:port], IPv4, or a bare dotted
#      host with a known TLD: google.com, https://x.com, localhost:3000)
#   .md / .markdown / .mdown / .mkd / ...   → markdown preview pane
#   .html / .htm / .pdf / .svg / images     → web pane (file:// URL)
#   anything else                           → usage error, no pane
# Explicit paths (./x, /x, ~/x) and existing files stay local, so
# `./google.com` is a file; a bare word (README) or an unknown/file-type
# TLD (notes.txt, foo.museum) is NOT a host — use `nex web open` for those.
# --here reuses the calling pane (markdown route only). Request/response
# on the web/URL route (prints `open ok: <pane-uuid>`); fire-and-forget
# on the markdown route.
nex open [--here] <path-or-url>

# Always open a markdown preview pane, whatever the extension. The
# escape hatch for forcing markdown on a file `nex open` would reject
# (a .log, a .txt) or render as web (a .html you want to read as source).
nex md [--here] <file>

# Open a git diff pane for the cwd repo (or scoped to <path>). Refreshes
# on focus and via the header refresh button.
nex diff [<path>]
```

So a worker that just wrote `report.html` can `nex open report.html`
to render it in a web pane, or `nex open summary.md` to drop a
live-reloading markdown preview beside the terminal — no manual
`file://` or pane-type juggling. The same command also opens a live
site: `nex open localhost:3000` or `nex open example.com` drops the
app into a web pane without reaching for the longer `nex web open`.

### Web Pane Commands

A `web` pane is a full in-pane browser with URL bar, multi-tab
strip, console capture, an element picker, private mode, and a
cookies editor. The CLI surface is the orchestration angle: an
agent in pane A can drive or observe a web app in pane B with
semantic verbs over the same DOM that the picker sees.

The agent-driving surface splits into four layers. Reach for the
lowest layer that solves your problem; `exec` is the escape hatch.

| Layer | Verbs | Use when |
|---|---|---|
| **Action** | `click`, `type`, `select`, `scroll`, `hover`, `key` | mutate the page |
| **Query** | `text`, `attr`, `count`, `exists`, `dom` | read state |
| **Wait** | `wait` | block until DOM / URL transition fires |
| **Exec** | `exec` | compose actuator calls + custom logic in one call |

#### Infrastructure (pane + tabs + capture + cookies)

```bash
# Create a new web pane in the active workspace.
# `web open` always creates a NEW pane; --target / --workspace are rejected.
# Use `web navigate` to redirect an existing pane, or `web tab-new` for a new tab.
# `open`, `navigate`, and `tab-new` resolve LOCAL FILE PATHS: an explicit path
# (./x, ../x, /x, ~/x) or a bare name matching a file-with-extension in the cwd
# becomes a file:// URL, so `nex web open report.html` works without hand-building
# file://. Bare hostnames (example.com) and single-label hosts (app, api) stay
# URLs — use ./name to force a local path.
nex web open [--private] <url>

# Redirect the active tab of an existing web pane to <url>
nex web navigate <url> [--target <name-or-uuid>] [--workspace <name-or-uuid>]

# Read the active tab's URL + title
nex web url --target <name-or-uuid> [--workspace <name-or-uuid>]

# Navigate
nex web back    --target <name-or-uuid>
nex web forward --target <name-or-uuid>
nex web reload  --target <name-or-uuid> [--hard]

# Capture page state into a JSON reply
nex web capture --target <name-or-uuid> --mode meta|text|screenshot

# Multi-tab
nex web tabs       --target <name-or-uuid> [--json] [--no-header]
nex web tab-new    --target <name-or-uuid> [<url>] [--no-focus]
nex web tab-close  --target <name-or-uuid> <ref>   # UUID or numeric index
nex web tab-select --target <name-or-uuid> <ref>

# Drain the per-pane console ring buffer (since-cursor, level filter, clear)
nex web console --target <name-or-uuid> [--since N] [--level error|warn|info|log|debug] [--clear] [--json]

# Arm the element picker. With --send-to, the next click pastes a
# sanitised payload (selector, xpath, tag, outer_html, attributes,
# rect, surrounding text, url) into the named pane via `pane send`.
# Default is paste-only — pass --submit if the receiving pane should
# auto-execute (rarely what you want for an agent prompt).
nex web inspect --target <name-or-uuid> [--send-to <pane>] [--submit] [--disarm]
nex web inspect-result --target <name-or-uuid> [--clear] [--json]

# Toggle private mode (rebuilds the coordinator; live JS state lost)
nex web private on|off --target <name-or-uuid>

# Cookies (per-pane data store)
nex web cookies list   --target <name-or-uuid> [--json]
nex web cookies clear  --target <name-or-uuid> [--domain X] [--all]
nex web cookies delete <name> --target <name-or-uuid> [--domain X]
```

#### Action verbs

```bash
nex web click  --target <X> <selector> [--double] [--right] [--at x,y] [--json]
nex web type   --target <X> <selector> <text> [--submit] [--no-replace] [--json]
nex web select --target <X> <selector> <value-or-label> [--json]
nex web scroll --target <X> <selector> [--top|--bottom|--smooth] [--json]
nex web hover  --target <X> <selector> [--json]
nex web key    --target <X> <key-name> [--selector <sel>] [--json]
```

- `click` always synthesises a full pointerdown → mousedown →
  pointerup → mouseup envelope (with real centre coords) so
  libraries that listen for pointer / mouse events (react-dnd,
  framer-motion, custom dropdowns) fire. `--at x,y` overrides the
  centre offset and routes the final click through a synthesised
  `MouseEvent('click')` so listeners read the coords; without
  `--at` the final click goes through `target.click()` (form /
  anchor / disabled semantics intact, but `clientX/Y = 0` on the
  click event itself).
- `type` uses the prototype native setter so React / Vue / Svelte
  controlled inputs accept the write, then dispatches `input` +
  `change`. `--submit` fires Enter and `form.requestSubmit()`.
  `--no-replace` appends instead of overwriting.
- `select` matches `<option>`s by `value` first, then by visible
  label.
- `key` accepts `enter`, `return`, `tab`, `escape`/`esc`, `space`,
  `backspace`, `delete`, `up`/`down`/`left`/`right` (also
  `arrowup` etc.), `home`, `end`, `pageup`, `pagedown`. Without
  `--selector` the keystroke goes to `document.activeElement`.

#### Query verbs

```bash
nex web text   --target <X> <selector> [--max-bytes N] [--json]
nex web attr   --target <X> <selector> <attribute> [--json]
nex web count  --target <X> <selector> [--json]
nex web exists --target <X> <selector>                 # exit 0 = yes, 1 = no
nex web dom    --target <X> <selector> [--max-bytes N] [--json]
```

- `text` clips at 1MB by default and reports `truncated` in the
  envelope; `dom` at 16KB; `attr` at 64KB.
- `attr` distinguishes attribute absent (exit 1, no output) from
  attribute present with empty value (exit 0, empty stdout) via a
  `present` field in `--json` mode.
- `exists` is the cheap one-shot "is it there?" check — exit code
  is the signal, no stdout. For polling, prefer `wait`.

#### Wait

```bash
nex web wait --target <X>
    (--selector <sel> | --url-match <substring-or-regex>)
    [--for visible|hidden|exists|count=N|text=X]
    [--timeout 10]
    [--json]
```

One socket roundtrip blocks until the condition is met or the
timeout fires. Polls inside the page at 100ms — replaces shell
`until ...; do sleep 1; done` loops at significantly lower
overhead (a single 100ms tick past the event vs. the next 1s
sleep boundary).

Conditions:

| `--for` | Meaning |
|---|---|
| `exists` (default with `--selector`) | selector resolves to a non-null element |
| `visible` | element `isConnected` AND `getClientRects().length !== 0` AND `getComputedStyle().visibility !== 'hidden'` (catches `display:none` via the no-rects path; correctly classifies `position:fixed` overlays as visible) |
| `hidden` | element absent OR not visible (above) |
| `count=N` | `findAll(selector).length === N` |
| `text=X` | element matches AND its trimmed `textContent` equals `X` (or matches `/regex/flags`) |
| `url-match` (default with `--url-match`) | `location.href` matches the substring or regex |

Exit 0 on match (prints `matched <condition> in <N> ms`); exit 1
on timeout (`nex web wait: timeout` to stderr; `waited_ms` is in
the `--json` envelope).

#### Selector forms

A single string carries the selector. Four forms, one CLI flag:

| Form | Example | Behaviour |
|---|---|---|
| `css:<sel>` | `css:button.primary` | `document.querySelector(sel)` |
| `text:<exact>` | `text:Add to order` | smallest element whose trimmed `textContent` equals `<exact>` |
| `text:/<pattern>/<flags>` | `text:/^Add to (cart\|order)$/i` | same, regex matching |
| `role:<role>[:name=<name>]` | `role:button:name=Confirm` | first element with the ARIA role (explicit or implicit) and matching accessible name |
| _bare_ | `.foo`, `#bar`, `[data-x]`, `Add to order` | auto: CSS if starts with `. # [ > * :`, otherwise `text:` |

Text matching uses the smallest-enclosing-element rule (Playwright-
style): `text:Submit` on a page with `<button>Submit</button>`
resolves to the button, not `<html>` or `<body>`. Skips `<script>`,
`<style>`, and `<template>` subtrees.

#### Advanced: `web exec` for composition

When you need to compose several actuator calls plus custom JS
logic in one CLI invocation, reach for `exec`:

```bash
nex web exec --target <X> (--file <path> | <js>) [--timeout 30] [--json]
```

The author script runs inside an async wrapper with three aliases
bound:

| Alias | Resolves to |
|---|---|
| `$` | `__nexAct.find` (single element by selector) |
| `$$` | `__nexAct.findAll` |
| `nex` | the full `__nexAct` namespace (`nex.click`, `nex.type`, `nex.wait`, ...) |

A single trailing expression returns its value implicitly. Source
containing `return` / `throw` / `if` / `for` / `while` / `switch`
/ `try` / `do` / `let` / `const` / `var` switches to statement-
body mode where the author owns the explicit `return`.

```bash
# Trivial one-liner
nex web exec --target X 'document.title'

# Reach into framework state
nex web exec --target X 'window.__REDUX__.getState().cart.items.length'

# jQuery-style across the page
nex web exec --target X '$$("li.product").map(e => e.dataset.sku)'

# Compose actuator calls in one socket roundtrip
nex web exec --target X '
  await nex.wait({selector: "text:Add to order", for: "visible"});
  await nex.click("text:Add to order");
  await nex.wait({selector: "[role=alert]", for: "exists"});
  return nex.text("[role=alert]").text;
'
```

Reply envelope matches every other actuator verb: `{ok:true,
result:<json>}` on success; `{ok:false, error:<message>,
js_error:{name, message, line, column}}` on a page-side exception.
`--timeout` extends the CLI's socket read budget (default 30s) so
exec scripts with embedded `nex.wait(...)` calls don't get cut
off; the JS-side `wait` timeout is independent.

All `web` verbs follow the same `--target` / `--workspace`
scoping as `pane send`: label targets need an origin
pane or `--workspace`; UUID targets resolve globally. All are
reply-allowlisted — they return JSON and the CLI exits non-zero on
failure.

**Known limitation.** `WKUserContentController` user-script injection
is unreliable on `data:` URLs (opaque origin). Console capture, the
element picker, and the actuator (`__nexAct.*`, hence every action /
query / wait / exec verb) rely on injected scripts, so reach for a
real `http(s)://` or `file://` URL when validating those paths.
Smoke tests can still use `data:` URLs for navigation, `capture
--mode text`, and tab management.

### Key Behaviors

- **Target resolution** for `pane send` / `pane send-key` / `pane close` /
  `pane capture` / `pane split` / `pane create` / `pane name`:
  UUIDs are matched globally. Labels are scoped to the sender's own
  workspace (via `NEX_PANE_ID`) unless `--workspace <name-or-id>` is
  passed; a bare label without either explicit or implicit scope is
  rejected, so coordinators can't silently route into the
  wrong workspace.
- **Works from outside Nex**: `pane send` / `split` / `create` /
  `name` (like `send-key` / `close` / `capture`) no longer require
  `NEX_PANE_ID`. From a plain shell, address a pane with a UUID `--target`,
  or `--target <label> --workspace <name-or-id>`; `create`/`split` also accept
  `--workspace` alone. These are request/response: success prints the resolved
  (or new) pane id, failure exits non-zero with an actionable error — so an
  orchestrator can tell a real delivery from a no-op. Add `--json` for a
  machine-readable reply.
- **`--name` flag**: names the new pane at creation time so it can be
  immediately targeted by `pane send`.
- **`--target` flag**: on `split`/`create`, specifies which existing pane to
  split by name or UUID (defaults to the current pane via `NEX_PANE_ID`). This
  lets a coordinator split any named pane, not just itself.
- **Silent fallback vs. loud failure**: the fire-and-forget event hooks
  (`nex event …`) still exit 0 when Nex is unreachable. The request/response
  pane commands above instead exit non-zero with an `Error: …` / `Repair: …`
  message when the target can't be resolved or Nex isn't running.
- **`pane send` mechanics**: text is sent directly to the target pane's PTY
  followed by an Enter keypress. If a shell is running, the text executes as a
  shell command. If Claude is running in interactive mode, the text becomes a
  prompt.
- **TUI submit caveat**: when the target opts into bracketed-paste
  mode (Claude Code, vim, ...), the trailing Enter from `pane send` is
  intermittently captured inside the paste envelope and the message lands as
  pasted text without submitting. For interactive Claude/TUI workers, prefer
  the explicit two-step submit:

  ```bash
  nex pane send     --target worker-1 "<prompt>"
  nex pane send-key --target worker-1 enter
  ```

  `pane send-key` accepts `enter`, `return`, `tab`, `escape`/`esc`, `space`,
  `backspace`, `up`/`down`/`left`/`right`, and `ctrl-c`. It uses the same
  `--target` / `--workspace` resolution as `pane send`.

### Broadcasting to every worker pane (`pane sync`)

When you want the same keystrokes (e.g. `/compact`, `clear`, an interrupt)
to land in every worker pane of the workspace at once, toggle tmux-style
synchronise-input:

```bash
nex pane sync on            # mirror keystrokes across this workspace
# ... type in any pane; every other pane in the workspace gets the same input
nex pane sync off           # back to per-pane input

nex pane sync toggle        # flip without caring about the current state
nex pane sync status --json # read-only snapshot, machine-readable
```

Opt a single pane out of the active sync group (handy for a coordinator
pane you don't want broadcasting into):

```bash
nex pane sync exclude --target coordinator
nex pane sync include --target coordinator   # undo
```

Scope defaults to the calling pane's workspace via `NEX_PANE_ID`. Pass
`--workspace <name-or-uuid>` to target another workspace from an
external script. New panes opened while sync is on auto-join the group;
closed panes drop out automatically.

## Multi-Agent Workflow Patterns

### Pattern 1: Fan-Out with Markdown Communication (Recommended)

The coordinator creates named child panes, assigns tasks via markdown files,
and collects results from markdown output files.

#### Step 1: Set up the workspace

```bash
# Name the coordinator pane
nex pane name coordinator

# Create a shared communication directory
mkdir -p .nex-tasks .nex-results
```

#### Step 2: Write task files

Write a markdown file for each worker describing its task:

```bash
# Write task files (use the Write tool, not echo)
# .nex-tasks/worker-1.md
# .nex-tasks/worker-2.md
# etc.
```

Each task file should include:
- Clear description of the work to do
- Input files/context needed
- Expected output format
- Where to write results (e.g., `.nex-results/worker-1.md`)

#### Step 3: Spawn named worker panes

```bash
# Create named worker panes
nex pane split --name worker-1 --direction vertical
nex pane split --name worker-2 --direction horizontal
nex pane split --name worker-3 --direction horizontal
```

**Timing**: add a short delay (1-2 seconds) between spawning panes to allow
each surface to initialize before sending commands.

#### Step 4: Start Claude agents in worker panes

```bash
# Send Claude commands to each worker
sleep 2
nex pane send --target worker-1 claude -p "Read .nex-tasks/worker-1.md and complete the task described. Write your results to .nex-results/worker-1.md"
sleep 1
nex pane send --target worker-2 claude -p "Read .nex-tasks/worker-2.md and complete the task described. Write your results to .nex-results/worker-2.md"
sleep 1
nex pane send --target worker-3 claude -p "Read .nex-tasks/worker-3.md and complete the task described. Write your results to .nex-results/worker-3.md"
```

#### Step 5: Poll for results

```bash
# Wait for result files to appear. Between polls, use `pane list` to
# detect workers that died (user-closed, crashed) so the loop exits
# instead of hanging forever.
WORKERS=(worker-1 worker-2 worker-3)
while true; do
  all_done=true
  for w in "${WORKERS[@]}"; do
    [ -f ".nex-results/$w.md" ] || { all_done=false; break; }
  done
  $all_done && break

  # Abort if any worker pane has vanished.
  alive=$(nex pane list --json | jq -r '.[].label')
  for w in "${WORKERS[@]}"; do
    if ! echo "$alive" | grep -qx "$w" && [ ! -f ".nex-results/$w.md" ]; then
      echo "worker $w disappeared before producing output" >&2
      exit 1
    fi
  done
  sleep 5
done
```

Then read each result file and synthesize.

#### Step 6: Clean up

```bash
# Close worker panes when done
nex pane send --target worker-1 exit
nex pane send --target worker-2 exit
nex pane send --target worker-3 exit
```

### Pattern 2: Direct Messaging Between Panes

For simpler coordination, send commands directly between panes without markdown
files. Best for short, one-off commands.

```bash
# From coordinator, run a build in a named pane
nex pane split --name build
sleep 2
nex pane send --target build make build

# Run tests in another pane
nex pane split --name test
sleep 2
nex pane send --target test make test
```

### Pattern 3: Interactive Agent Swarm

Start multiple Claude agents in interactive mode that can message each other.

```bash
# Coordinator creates workers
nex pane split --name reviewer --direction vertical
nex pane split --name coder --direction horizontal

sleep 2

# Start Claude in each with role context
nex pane send --target reviewer claude
sleep 2
nex pane send --target reviewer "You are a code reviewer. Review any code written to .nex-results/code.md and write your review to .nex-results/review.md"

nex pane send --target coder claude
sleep 2
nex pane send --target coder "You are a coder. Write code for the task in .nex-tasks/feature.md and save it to .nex-results/code.md"
```

### Pattern 4: Agent driving / observing a web app via web pane

The web pane closes the loop where an agent in one pane drives or
observes a web app in another. The action / query / wait verbs
cover the common case; reach for `web exec` only when composing
them with custom logic. Common shapes:

**(a) Drive a flow with semantic verbs.** No JS authoring needed
— the verbs cover the typical "find element, act on it, wait for
the response, read the result" loop. Example: add an item to a
restaurant cart from a fresh session.

```bash
# Open the menu in a private pane so the agent's exploration doesn't
# pollute the user's real cart.
nex web open --private https://example-restaurant.test
WEB=<the-printed-uuid>

# Wait for the menu to render, dismiss the table modal.
nex web wait  --target $WEB --selector "text:Choose your table" --for visible
nex web type  --target $WEB "css:input[type=text]" "5"
nex web click --target $WEB "text:Confirm"

# Wait for the first menu item to be tappable, then add it.
nex web wait  --target $WEB --selector "text:Margherita" --for visible
nex web click --target $WEB "text:Margherita"
nex web wait  --target $WEB --selector "text:Add to order" --for visible
nex web click --target $WEB "text:Add to order"

# Verify the toast.
nex web wait --target $WEB --selector "[role=alert]" --for exists
nex web text --target $WEB "[role=alert]"
# → "Margherita added to your order"
```

**(b) Capture-then-fix loop** — agent runs the app in a web pane,
polls its console for errors, fixes the code, reloads, repeats.

```bash
nex web open http://localhost:3000              # → prints `open ok: <web-uuid>`
nex pane create --name dev-agent
sleep 2
nex pane send --target dev-agent claude --permission-mode acceptEdits

# Agent prompt (typed into dev-agent):
#   "Watch the console buffer of web pane <web-uuid>. Every 10s run
#    `nex web console --target <web-uuid> --json --since $cursor`
#    (track the cursor between polls). When you see a JS error, open
#    the relevant source file and propose a fix. After each edit,
#    `nex web reload --target <web-uuid>` and
#    `nex web wait --target <web-uuid> --selector '#app' --for visible`
#    before re-checking the console."
```

**(c) Compose multi-step flows in one call via `web exec`.** Use
this for branches that depend on intermediate values, framework
state reads, or anything that would otherwise round-trip through
the shell three times.

```bash
nex web exec --target $WEB '
  // Add each available size to the cart until we hit 3 items.
  for (const size of ["Small", "Medium", "Large"]) {
    await nex.click("text:" + size);
    await nex.wait({selector: "[role=alert]", for: "exists", timeout: 3000});
    await nex.wait({selector: "[role=alert]", for: "hidden"});
    const count = $$("li.cart-item").length;
    if (count >= 3) break;
  }
  return $$("li.cart-item").map(e => e.dataset.sku);
'
# → ["s-margherita","m-margherita","l-margherita"]
```

**(d) Click-to-locate-source** — the human clicks an element on
the page, an agent gets the selector + outerHTML and finds the
code that rendered it. Still the right tool when the agent doesn't
know the selector up front and a human is at the keyboard.

```bash
nex web inspect --target <web-uuid> --send-to dev-agent
# → next click on the web page pastes a fenced JSON block into
#   dev-agent's PTY (paste-only by default; agent reads it as input
#   but does NOT auto-submit unless --submit was passed)
```

The pasted payload includes `selector`, `xpath`, `tag`, `id`,
`outer_html` (clipped 16KB), `attributes`, `rect`, surrounding
`text`, `context_html` (clipped 4KB), and `url`. ANSI / C0 control
bytes are stripped before paste so the agent's prompt can't be
smuggled into.

**(e) Headless visual diff** — capture screenshots before/after a
change to gate a deploy.

```bash
nex web capture --target <web-uuid> --mode screenshot
# → JSON reply contains either `png_base64` (small) or `path` to a
#   PNG in the system temp dir (larger). The CLI prints the path.
```

**(f) Sandbox a flaky integration** — open the integration target
in a private web pane so the agent's exploration doesn't pollute
the user's real session.

```bash
nex web open --private https://staging.example.com
# Cookies + caches discarded on quit; tabs blank on restart.
```

**Reach order:** lowest layer that works (see the table at the
top of the Web Pane section); `exec` for composition; `inspect`
when a human is at the keyboard and the agent doesn't know the
selector. The picker auto-disarms on tab switch / close / Escape,
sticky mode is only reachable via the chrome's batch-annotate
panel, and page JS cannot spoof inbound payloads.

## Task File Format

When creating task files for workers, use this structure:

```markdown
# Task: <short description>

## Context
<background information, relevant files, architecture notes>

## Objective
<clear, specific description of what to accomplish>

## Inputs
- <file paths, data sources, or references the worker needs>

## Expected Output
- Write results to: `.nex-results/<worker-name>.md`
- Create/modify source files as described below

## Constraints
- <any boundaries, e.g., "do not modify files outside src/components/">
- <time/scope limits>
```

## Result File Format

Workers should write results in this format:

```markdown
# Result: <task description>

## Status
<completed | partial | failed>

## Summary
<1-3 sentence overview of what was done>

## Changes Made
- <list of files created/modified with brief descriptions>

## Notes
- <any issues encountered, decisions made, or follow-up needed>
```

## Practical Tips

1. **Always name your coordinator pane first** (`nex pane name coordinator`)
   so workers can message back if needed.

2. **Use `claude -p` for workers** (print mode). It runs non-interactively
   with full tool access and exits when done. This is better than interactive
   mode for autonomous workers.

3. **Add delays between pane operations**. The terminal surfaces need time to
   initialize. A 1-2 second sleep between `pane split` and `pane send` prevents
   race conditions.

4. **Use the `.nex-tasks/` and `.nex-results/` convention** for the shared
   communication directory. This keeps agent artifacts organized and
   `.gitignore`-able.

5. **Poll with `sleep` loops for results**, not busy-waits. Check every 5-10
   seconds for result files.

6. **Keep task descriptions self-contained**. Workers run in fresh Claude
   sessions with no shared context. Include all necessary information in the
   task file.

7. **Workers should use absolute paths** or paths relative to the project root
   to avoid working directory confusion.

8. **For large fan-outs (>4 workers)**, create panes in batches to avoid
   overwhelming the terminal. Spawn 3-4, wait for them to complete, then spawn
   the next batch.

## Coordinator Script Template

Here is a complete coordinator script you can adapt:

```bash
#!/bin/bash
# Nex multi-agent coordinator
set -e

PROJECT_DIR="$(pwd)"
TASK_DIR="$PROJECT_DIR/.nex-tasks"
RESULT_DIR="$PROJECT_DIR/.nex-results"
WORKERS=("worker-1" "worker-2" "worker-3")

# Setup
nex pane name coordinator
mkdir -p "$TASK_DIR" "$RESULT_DIR"
rm -f "$RESULT_DIR"/*.md  # Clean previous results

# Task files should already exist in $TASK_DIR/<worker-name>.md

# Spawn workers
for worker in "${WORKERS[@]}"; do
  nex pane split --name "$worker" --direction horizontal
  sleep 2
done

# Start agents
for worker in "${WORKERS[@]}"; do
  nex pane send --target "$worker" "cd $PROJECT_DIR && claude -p 'Read $TASK_DIR/$worker.md and complete the task. Write results to $RESULT_DIR/$worker.md'"
  sleep 1
done

# Wait for all results. Reconcile against live pane state so a worker
# that died (user-closed, crashed) stops the loop instead of hanging.
echo "Waiting for workers to complete..."
while true; do
  all_done=true
  for worker in "${WORKERS[@]}"; do
    [ -f "$RESULT_DIR/$worker.md" ] || { all_done=false; break; }
  done
  $all_done && break

  alive=$(nex pane list --json | jq -r '.[].label')
  for worker in "${WORKERS[@]}"; do
    if ! echo "$alive" | grep -qx "$worker" && [ ! -f "$RESULT_DIR/$worker.md" ]; then
      echo "worker $worker disappeared before producing output" >&2
      exit 1
    fi
  done
  sleep 5
done

echo "All workers complete. Results in $RESULT_DIR/"
```

## Error Handling

- If a worker fails, its result file won't appear. The coordinator should
  implement a timeout (e.g., 5 minutes) and report which workers didn't
  complete.
- **Use `nex pane list` to detect dead workers** before timeout. If a
  worker's label no longer appears in the list, the pane was closed
  externally and its result file will never arrive — bail out instead of
  polling forever.
- Workers can signal errors via `nex event error --message "description"`.
- Workers can send desktop notifications via
  `nex event notification --title "Done" --body "Task complete"`.
