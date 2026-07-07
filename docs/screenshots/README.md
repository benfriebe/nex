# README screenshots

The 11 PNGs here back the images in the top-level `README.md`. They were
captured in a sandboxed macOS VM running a build of the app, staged with a
seeded polyrepo (Backend / Frontend / Infra groups, colour-coded workspaces,
label pills, and a `nex` repo association) so the chrome reflects real use.

- **Primary set** — `*.png` in this directory, captured at **1080p**
  (1920×1080 windows). The README references these.
- **720p set** — `720p/*.png`, the same shots down-sampled to 1280×720 for
  lighter-weight / alternate use.

The terminal panes show a `nex@nex` prompt with a repo dashboard (branch,
recent commits, changed files, a `PaneLayout.swift` peek) so they read as a
real session rather than a bare prompt.

| File | Suggested shot |
| --- | --- |
| `hero.png` | Full Nex window: sidebar with a couple of groups, an active workspace with a mixed split (terminal + markdown + web pane), inspector visible. Pick the workspace that best shows Nex in real use. |
| `workspaces.png` | Sidebar focused. Show several workspaces, a group, colour dots, and the inspector on the right with a repo association and worktree info. |
| `command-palette.png` | `Cmd+P` open over a workspace, with a query showing results (mix of workspaces and panes). |
| `groups-labels.png` | Sidebar with at least one group expanded, workspaces tagged with labels, the filter input populated to show live filtering. |
| `markdown-pane.png` | A markdown pane in preview mode rendering a doc with a heading, a fenced code block, a task list, and front-matter at the top. Bonus: split with a terminal pane next to it. |
| `diff-pane.png` | A diff pane showing a real `git diff` with add/delete lines coloured and a couple of file `<details>` blocks. |
| `web-pane.png` | The web pane open on a real site, multi-tab visible. Optional: a sibling terminal pane where an agent has just run `nex web click ...`. |
| `agent-monitoring.png` | The menu-bar popover open with running and waiting agents listed, plus the dock badge visible. |
| `themes.png` | Appearance settings (or a gallery) showing the preset palettes applied to the chrome — Dracula / Nord / Tokyo Night etc. |
| `status-bar.png` | The bottom status bar: focused pane path + branch + diff stats on the left, CPU / memory / load sparklines and agent counts on the right. |
| `inspector-graft.png` | Inspector view showing one or two repo associations, the graft toggle button, current branch, git status counts. |

## Re-capturing

The capture harness lives in the cua tooling (`capture_readme_shots.py`): it
seeds the workspace/repo state, frames the window at 1080p, and screenshots
each scene. Re-run a scene and re-copy its `<name>.png` here (plus the 2/3
down-sample into `720p/`) to refresh. No README edits are needed on refresh;
the references in `../../README.md` already point at these filenames.
