---
name: nex-agentic
description: >
  Use the Nex terminal multiplexer and its CLI to orchestrate multi-agent
  development workflows. Enables spawning named child panes, starting Claude
  agents in them, farming out parallel work, and coordinating results via
  markdown files and direct pane messaging. Trigger when: the user asks to
  "spawn agents", "fan out work", "create worker panes", "orchestrate panes",
  "use nex to coordinate", "multi-agent", "farm out tasks", or any variation
  of parallelizing work across Nex panes.
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
   - `bypassPermissions` (aka `--dangerously-skip-permissions`) — full
     autonomy, no prompts. Common for trusted fan-outs in worktrees.

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
# Split a pane (creates a new pane alongside)
nex pane split [--direction horizontal|vertical] [--path /dir] [--name <label>] [--target <name-or-uuid>]

# Create a new pane (alias for horizontal split)
nex pane create [--path /dir] [--name <label>] [--target <name-or-uuid>]

# Close current pane
nex pane close

# Set a label on current pane (visible as pill badge in title bar)
nex pane name <label>

# Send text to another pane (typed into its PTY + Enter)
# Label resolution is scoped to the sender's own workspace by default
# (issue #92). Pass --workspace <name-or-id> to target another workspace
# or to disambiguate a label collision; UUID targets are always global.
nex pane send --target <label-or-uuid> [--workspace <name-or-uuid>] <command...>

# List panes (only command that returns data — use for reconciliation)
nex pane list [--workspace <name-or-id> | --current] [--json] [--no-header]

# Print current pane's UUID (local; no socket). Exit 1 if not in Nex.
nex pane id
```

### `pane list` — reconcile with live state

`pane list` is the only Nex command that returns data. Use it whenever a
coordinator needs to know what panes actually exist right now — panes can
be closed by the user, crash, or be moved between workspaces. `pane send`
exits non-zero with a structured error on a missing/ambiguous target
(issue #92), but checking `pane list` first lets a coordinator skip
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

Each JSON entry includes: `id`, `label`, `type` (`shell`/`markdown`/
`scratchpad`), `title`, `workspace_id`, `workspace_name`,
`working_directory`, `git_branch`, `status` (`idle`/`running`/
`waitingForInput`), `claude_session_id`, `is_focused`,
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
```

### Workspace Commands

```bash
nex workspace create [--name "..."] [--path /dir] [--color blue|green|red|yellow|purple|orange|pink|gray]
```

### Key Behaviors

- **Target resolution** for `pane send` / `pane close` / `pane capture`:
  UUIDs are matched globally. Labels are scoped to the sender's own
  workspace (via `NEX_PANE_ID`) unless `--workspace <name-or-id>` is
  passed; a bare label without either explicit or implicit scope is
  rejected (issue #92), so coordinators can't silently route into the
  wrong workspace.
- **`--name` flag**: names the new pane at creation time so it can be
  immediately targeted by `pane send`.
- **`--target` flag**: on `split`/`create`, specifies which existing pane to
  split by name or UUID (defaults to the current pane via `NEX_PANE_ID`). This
  lets a coordinator split any named pane, not just itself.
- **Silent fallback**: if `NEX_PANE_ID` is unset or the socket is unavailable,
  all commands exit silently with code 0.
- **`pane send` mechanics**: text is sent directly to the target pane's PTY
  followed by an Enter keypress. If a shell is running, the text executes as a
  shell command. If Claude is running in interactive mode, the text becomes a
  prompt.

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
