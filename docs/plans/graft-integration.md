# Plan: native worktree-mirroring ("graft") in Nex

> Implementer: read this top-to-bottom before touching code. The plan is self-contained — you do not need conversation history. All file paths and line numbers reference the repo state as of branch `main` at commit `99befa9`.

## 1. What we are building

A built-in capability in the Nex Swift app that watches a git worktree for file changes and continuously mirrors those tracked-file changes back to the parent repo's working tree. Any `RepoAssociation` row in the workspace inspector gets a one-click toggle to start/stop this mirroring.

The capability is inspired by the standalone [graft](https://github.com/benfriebe/graft) Rust TUI, but this is a complete native replacement — **no runtime dependency on the graft binary, no shared on-disk state, no interop**. A user who installs Nex never needs to install graft.

### Why this fits Nex

Nex already owns every concept the feature needs:

| concept | Nex location |
|---|---|
| worktree picker | `RepoAssociation` rows in `WorkspaceInspectorView.swift:282` |
| `git worktree add` | `gitService.createWorktree` (`Nex/Services/GitService.swift:101`) |
| repo root vs worktree path | `gitService.resolveRepoRoot` → `RepoRootInfo.parentRepoRoot` (`Nex/Services/GitService.swift:165`) |
| 500 ms file-change debounce | Same pattern as `PersistenceService` and `SettingsFeature`'s appearance debounce |

The gap is recursive directory watching — `GitHeadWatcher` watches a single file via kqueue. We add an FSEvents-backed `RecursiveFSWatcher` for directory trees.

## 2. The mirroring state machine

Three phases, all shellable through `git`:

**Start (per association):**
1. Reject if `parentRepoRoot` has a merge/rebase/cherry-pick in progress.
2. If `parentRepoRoot` has dirty tree (`git status --porcelain` non-empty), `git stash push --include-untracked -m "nex-graft:<assoc-id>"`. Record the resulting `stash@{0}` SHA (use `git rev-parse refs/stash` immediately after) so we pop the exact stash later.
3. Write breadcrumb `<parentRepoRoot>/.git/nex-graft-active` (Nex-private path — does not collide with the standalone graft binary's `.git/graft-active`). JSON body: `{"version":1,"stashed":<bool>,"assocId":"<uuid>","stashRef":"<sha-or-null>","worktreePath":"<path>","branch":"<name>"}`.
4. Run one initial sync pass (step "Sync pass" below).
5. Start recursive FSEvents watcher rooted at the worktree path with the ignore set.

**Sync pass (every debounced batch):**
1. In the worktree: `git add -A`.
2. Capture `git diff --name-only --cached` — these are the changed paths to log.
3. If non-empty, `git commit -m "nex-graft: checkpoint" --no-verify` (skip hooks — checkpoint commits would thrash pre-commit hooks otherwise).
4. In `parentRepoRoot`: `git checkout -f <branch> --` to update the root to the worktree branch's new tip. Use `git checkout -f <sha>` of the worktree's HEAD if the parent doesn't have a local branch by that name (rare — only when the worktree was created with a branch the parent didn't have first).

**Stop:**
1. Stop the watcher.
2. In `parentRepoRoot`: `git checkout -f HEAD --` to discard the synced tree.
3. If breadcrumb says we stashed: `git stash pop <stashRef>`. If the pop fails (conflicts), leave the stash in place and surface an error — DO NOT drop the stash silently.
4. Delete the breadcrumb file.

**Recovery on app launch:**
- For every registered `RepoAssociation`, check `<parentRepoRoot>/.git/nex-graft-active`. If present, the previous Nex run died mid-mirror.
- Surface a one-time banner: "Graft for <repo> was interrupted. Restore your stash?" with **Restore** (run the Stop sequence using the breadcrumb's `stashRef`) and **Dismiss** (delete the breadcrumb only — leaves the stash for the user to handle manually).

### Concurrency rule

Only one active graft session per **parent repo root**. Two workspaces pointing at different worktrees of the same repo can't graft simultaneously — the root is the shared target. Enforce via a `Set<String>` (canonicalised `parentRepoRoot` paths) inside `GraftService`. UI disables the toggle on the second association with a tooltip: "Already grafting <other-workspace> into this repo."

## 3. Files to create

### 3a. `Nex/Services/RecursiveFSWatcher.swift` (new)

FSEvents-backed recursive watcher. Mirrors the shape of `Nex/Services/GitHeadWatcher.swift` but uses `FSEventStreamCreate` instead of `DispatchSource`.

Required surface:

```swift
final class RecursiveFSWatcher: Sendable {
    /// Begin watching `rootPath` recursively. Emits batched paths after
    /// `debounce` ms of quiet. Honours `ignoredComponents` (directory or
    /// file name match — e.g. `.git`, `node_modules`, `.DS_Store`).
    /// Cancelling the consumer task stops the stream.
    func start(
        rootPath: String,
        debounce: DispatchTimeInterval = .milliseconds(500),
        ignoredComponents: Set<String> = [".git", "node_modules", "target", ".DS_Store"]
    ) -> AsyncStream<[String]>

    func stopAll()
}

extension RecursiveFSWatcher: DependencyKey { ... }
```

Implementation notes:
- `FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.0, UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))`. `kFSEventStreamCreateFlagFileEvents` gives per-file granularity (we need paths for the log line); `kFSEventStreamCreateFlagNoDefer` ensures the first event in a quiet system flushes immediately.
- Schedule on a dedicated `DispatchQueue(label: "nex.recursive-fs-watcher", qos: .utility)` via `FSEventStreamSetDispatchQueue`.
- Inside the C callback, filter paths whose components contain any of `ignoredComponents`, then forward into a Swift actor or `NSLock`-protected struct that holds the pending batch and a `DispatchWorkItem` for the debounce flush.
- Test seam: `testValue` returns a watcher that emits whatever `inject(_:into:)` test helper feeds in. Use an `nonisolated(unsafe)` continuation registry keyed by `rootPath`, gated by `NSLock`, identical to `GitHeadWatcher`'s pattern.

### 3b. `Nex/Services/GraftService.swift` (new)

The state machine. Pure orchestration — no FS calls of its own; delegates to `gitService` and `recursiveFSWatcher`. Exposed as a TCA dependency.

```swift
struct GraftSession: Equatable, Identifiable {
    var id: UUID                       // matches RepoAssociation.id
    var worktreePath: String
    var parentRepoRoot: String
    var branch: String
    var status: GraftSessionStatus     // .starting / .watching / .syncing / .error(String)
    var stashRef: String?              // SHA if we stashed; nil otherwise
    var lastSync: Date?
    var recentLog: [GraftLogEntry]     // bounded to last 100 entries
}

enum GraftSessionStatus: Equatable {
    case starting
    case watching
    case syncing
    case error(String)
}

struct GraftLogEntry: Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: Kind                     // .info / .sync(filesChanged: Int) / .error(String)
    let message: String

    enum Kind: Equatable { case info; case sync(Int); case error }
}

struct GraftService {
    /// Begin grafting. Throws on conflict (repo-root already grafting,
    /// merge/rebase in progress, missing worktree, etc.).
    var start: @Sendable (_ association: RepoAssociation) async throws -> GraftSession

    /// Stop grafting. Idempotent. Throws only if the stop sequence
    /// itself fails (e.g. stash pop conflict).
    var stop: @Sendable (_ associationID: UUID) async throws -> Void

    /// Snapshot of all active sessions. Used by reducer to hydrate UI.
    var activeSessions: @Sendable () async -> [GraftSession]

    /// Subscribe to incremental session updates (status changes, log
    /// lines). Single subscriber is fine — fan-out happens in the
    /// reducer.
    var updates: @Sendable () -> AsyncStream<GraftSessionEvent>

    /// Scan all known parent repo roots for orphaned `.git/graft-active`
    /// breadcrumbs. Called once on app launch.
    var detectOrphans: @Sendable (_ parentRepoRoots: [String]) async -> [GraftOrphan]

    /// Run the stop sequence using a breadcrumb's recorded state.
    /// Used by the recovery banner's "Restore" action.
    var recoverOrphan: @Sendable (_ orphan: GraftOrphan) async throws -> Void

    /// Delete a breadcrumb without running the stop sequence. Used by
    /// "Dismiss" so the banner stops nagging.
    var dismissOrphan: @Sendable (_ orphan: GraftOrphan) async -> Void
}

enum GraftSessionEvent: Equatable {
    case started(GraftSession)
    case updated(GraftSession)
    case stopped(UUID)
}

struct GraftOrphan: Equatable, Identifiable {
    var id: UUID                       // assocId from breadcrumb (or fresh UUID if missing)
    var parentRepoRoot: String
    var worktreePath: String
    var stashRef: String?
}
```

Implementation:
- Internal actor (or `NSLock`-gated struct, matching the repo's existing style) holds `[UUID: GraftSession]` and `Set<String>` of busy parent-repo roots.
- Each `start` call:
  1. Acquires the parent-repo-root mutex. Throw `GraftError.alreadyActive` if held.
  2. Builds initial session, emits `.started`.
  3. Spawns a `Task` that runs the watcher loop. The task is stored in the session record so `stop` can cancel it.
  4. On every batch from `RecursiveFSWatcher.start(...)`: flip status to `.syncing`, run the sync pass, append a log entry, flip back to `.watching`. Emit `.updated` after each transition.
  5. On sync-pass failure (e.g. transient `git index.lock`): set status to `.error(msg)`, log it, keep watching. Errors do not stop the loop — fix the underlying cause and the next file-change event retries.
- Breadcrumb file is `<parentRepoRoot>/.git/nex-graft-active`, written as JSON via `JSONEncoder` and read with `JSONDecoder` (strict — reject unknown `version`). Nex owns this file end-to-end; no other tool reads or writes it.

### 3c. `Nex/Features/Graft/GraftFeature.swift` (new)

TCA reducer slice. Owns the UI-visible state.

```swift
@Reducer
struct GraftFeature {
    @ObservableState
    struct State: Equatable {
        var sessions: IdentifiedArrayOf<GraftSession> = []
        var orphans: IdentifiedArrayOf<GraftOrphan> = []  // surfaces recovery banner
    }

    enum Action {
        case onAppLaunched(parentRepoRoots: [String])
        case orphansDetected([GraftOrphan])
        case toggleGraft(RepoAssociation)
        case startSucceeded(GraftSession)
        case startFailed(associationID: UUID, error: String)
        case stopSucceeded(UUID)
        case stopFailed(UUID, error: String)
        case sessionEvent(GraftSessionEvent)
        case subscribeToUpdates
        case recoverOrphan(GraftOrphan)
        case dismissOrphan(GraftOrphan)
    }

    @Dependency(\.graftService) var graftService

    var body: some ReducerOf<Self> { ... }
}
```

Plug `GraftFeature` into `AppReducer.State` as `var graft = GraftFeature.State()`. Wire `Scope(state: \.graft, action: \.graft) { GraftFeature() }` into the body — same pattern as `SettingsFeature`.

On `AppReducer.Action.onAppLaunched` (or whatever the existing post-restore action is — search `socketServer.start` to find the spot), forward to `.graft(.onAppLaunched(...))` with the deduplicated list of `RepoRecord` parent paths.

### 3d. `Nex/Features/Graft/GraftInspectorButton.swift` (new)

The toggle button rendered in `WorkspaceInspectorView.swift`. Extracted into its own view to keep the inspector file readable.

```swift
struct GraftInspectorButton: View {
    let association: RepoAssociation
    @Bindable var store: StoreOf<AppReducer>

    var body: some View {
        let session = store.graft.sessions[id: association.id]
        let icon = session == nil ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle.fill"
        let tooltip = tooltipText(session: session)
        InspectorIconButton(icon: icon, tooltip: tooltip) {
            store.send(.graft(.toggleGraft(association)))
        }
        .overlay(alignment: .topTrailing) {
            if let session, case .error = session.status {
                Circle().fill(.red).frame(width: 5, height: 5).offset(x: 2, y: -2)
            } else if session != nil {
                Circle().fill(.green).frame(width: 5, height: 5).offset(x: 2, y: -2)
            }
        }
    }

    private func tooltipText(session: GraftSession?) -> String { ... }
}
```

## 4. Files to modify

### 4a. `Nex/Services/GitService.swift`

Add new closures to `GitService` (after `resolveHeadPath`):

```swift
var stashPushIncludeUntracked: @Sendable (_ repoPath: String, _ message: String) async throws -> String?  // returns stash SHA or nil if nothing to stash
var stashPopRef: @Sendable (_ repoPath: String, _ stashRef: String) async throws -> Void
var addAllAndCommit: @Sendable (_ worktreePath: String, _ message: String, _ noVerify: Bool) async throws -> [String]  // returns changed paths
var checkoutBranchForce: @Sendable (_ repoPath: String, _ branchOrSha: String) async throws -> Void
var checkoutHeadForce: @Sendable (_ repoPath: String) async throws -> Void
var repoState: @Sendable (_ repoPath: String) async throws -> RepoState  // .clean / .merge / .rebase / .cherryPick / ...
```

Implementations all use the existing `runGit` helper (`Nex/Services/GitService.swift:246`).

For `stashPushIncludeUntracked`: run `git stash push --include-untracked -m "<message>"`. If output contains `"No local changes to save"`, return `nil`. Otherwise run `git rev-parse refs/stash` and return the SHA.

For `addAllAndCommit`: `git add -A`, then `git diff --name-only --cached` to capture paths, then `git commit -m <msg> --no-verify` (if `noVerify`). If `git diff --name-only --cached` returns empty, skip the commit and return `[]`.

For `repoState`: check for `<git-dir>/MERGE_HEAD`, `<git-dir>/rebase-merge`, `<git-dir>/rebase-apply`, `<git-dir>/CHERRY_PICK_HEAD`, `<git-dir>/REVERT_HEAD`, `<git-dir>/BISECT_LOG`. Resolve `<git-dir>` via `git rev-parse --git-dir`. Return a matching `RepoState` enum case (`Nex/Services/GitService.swift`, define near `GitServiceError`).

Add corresponding entries to `testValue` (`Nex/Services/GitService.swift:297`) — use `unimplemented(...)` for ones tests don't exercise, and stub returns for the rest.

### 4b. `Nex/Features/Workspace/WorkspaceInspectorView.swift`

Insert the graft button between the diff button (line 282-288) and the terminal button (line 290-300):

```swift
InspectorIconButton(icon: "plusminus", tooltip: "Show diff for this repo") { ... }

GraftInspectorButton(association: assoc, store: store)   // NEW

InspectorIconButton(icon: "terminal", ...) { ... }
```

Above the row, render the orphan-recovery banner once per workspace if `store.graft.orphans` has entries whose `parentRepoRoot` matches one of this workspace's associations. Banner has two buttons (Restore / Dismiss) wired to `.graft(.recoverOrphan(...))` and `.graft(.dismissOrphan(...))`.

### 4c. `Nex/AppReducer.swift`

- Add `var graft = GraftFeature.State()` to `AppReducer.State`.
- Add `case graft(GraftFeature.Action)` to `AppReducer.Action`.
- `Scope(state: \.graft, action: \.graft) { GraftFeature() }` in the body.
- On app-launch hydration (find the existing place where `repoRegistry` is loaded post-restore — search for `persistenceService.load`), send `.graft(.onAppLaunched(parentRepoRoots: <unique paths>))`.
- On app teardown (search for `socketServer.stop` or `stopAll`), call `graftService.stop` for every active session so we don't leave breadcrumbs from a clean quit. Quick-quit path is fine — breadcrumb-based recovery handles abrupt termination.

### 4d. `Nex/NexApp.swift` (test-mode gate)

If you use `FSEvents` directly in `RecursiveFSWatcher`, guard the `liveValue` so it returns a no-op watcher under `NexApp.isTestMode` (search for existing usages — same gate is used for ghostty init). Tests should never trigger FSEvents.

## 5. CLI (`Tools/nex-cli/nex.swift`)

Three new subcommands, all request/response (allowlist them in `Nex/Services/SocketServer.swift:84`):

```
nex graft start [--workspace <name-or-id>] [--repo <name-or-path>]
nex graft stop  [--workspace <name-or-id>] [--repo <name-or-path>]
nex graft status [--json]
```

If neither `--workspace` nor `--repo` is given, the CLI uses `NEX_PANE_ID` to resolve the calling workspace, and grafts/stops every association in it.

### Wire messages

Extend `SocketMessage` (`Nex/Services/SocketServer.swift` — search for `enum SocketMessage`) with:
- `graftStart(workspace: String?, repo: String?, paneID: String?)`
- `graftStop(workspace: String?, repo: String?, paneID: String?)`
- `graftStatus`

Reply payloads:
- `graft-start` → `{"ok":true,"started":[{"associationId":"...","worktreePath":"...","branch":"..."}]}` or `{"ok":false,"error":"..."}`
- `graft-stop` → `{"ok":true,"stopped":["<assoc-id>", ...]}` or `{"ok":false,"error":"..."}`
- `graft-status` → `{"ok":true,"sessions":[<GraftSession JSON>]}`

### CLI handler

Add `case "graft": handleGraft(&args)` after `case "diff":` (`Tools/nex-cli/nex.swift:1172`). Implement `handleGraft` modelled on `handleDiff` (line 1118) and the request/response pattern in `handlePane` close/capture/send (search for `replyCommandAllowlist` usages).

## 6. Tests

Add to `NexTests/`:

### 6a. `RecursiveFSWatcherTests.swift`
- Create temp dir, start watcher, write file → assert event arrives within 1s.
- Write file inside `.git/` → assert no event.
- Burst-write 10 files within 100ms → assert exactly one event batch with all 10 paths.
- Cancel consumer task → assert watcher tears down (use `Task.cancel()` and confirm via internal counter).

### 6b. `GraftServiceTests.swift`
- Use a temp git repo with a worktree (cribbing setup from `NexTests/WorktreeOperationTests.swift`).
- `start` on clean root: no stash created; breadcrumb says `"stashed":false`.
- `start` on dirty root: stash created; breadcrumb records stash SHA; `git stash list` shows the entry.
- Sync pass: write a file in the worktree, drive a fake `RecursiveFSWatcher` event, assert worktree gets a `nex-graft: checkpoint` commit and parent root's `HEAD` matches it.
- `stop` after dirty start: stash pops successfully, breadcrumb removed.
- `stop` after dirty start with conflicting stash: stash remains, error returned, breadcrumb still removed (the stash is the user's; we don't delete it, but we don't keep claiming we're grafting).
- Double-start on same parent root: second call throws `GraftError.alreadyActive`.
- Orphan detection: pre-seed `.git/nex-graft-active`, call `detectOrphans`, assert it's returned.

### 6c. `GraftFeatureTests.swift`
- Toggle on → `.startSucceeded` → state has session.
- Toggle off → `.stopSucceeded` → state has no session.
- Orphan-restore action delegates to `graftService.recoverOrphan` (use `TestStore` with a stub `graftService`).

### 6d. `SocketParsingTests.swift` (modify existing)
- Parse `{"command":"graft-start", ...}` → `SocketMessage.graftStart(...)`. Same for stop/status.

### 6e. `GraftCLIReplyTests.swift` (new)
- Send `graft-start` over the socket with a stubbed `graftService`, assert reply is `{"ok":true,"started":[...]}` and FD is closed.
- Send `graft-start` for an unknown workspace → reply is `{"ok":false,"error":"..."}`.

## 7. Acceptance / manual verification

After everything compiles and `make check` passes:

1. Open Nex, create a workspace pointing at a real repo's worktree.
2. Confirm the new graft icon appears in the inspector between diff and terminal.
3. Hover → tooltip reads "Start grafting <branch> into <repo>".
4. Click → icon flips to filled variant with green dot; in terminal, `git -C <parentRepoRoot> log -1` shows nothing yet (no commits in worktree).
5. Edit a file in the worktree (e.g. `echo x >> README.md`). Within ~1s, `git -C <parentRepoRoot> diff HEAD~1` should show the edit reflected in the root.
6. Click the graft icon again → icon reverts, parent root is restored to its pre-graft state, any stash is popped, `.git/nex-graft-active` is gone.
7. Kill Nex mid-graft (`killall Nex`). Relaunch. Confirm the orphan-recovery banner appears.
8. CLI smoke test:
   ```
   nex graft start                # in a Nex pane, inside a worktree
   nex graft status --json        # shows the session
   nex graft stop
   ```

## 8. Out of scope (deferred)

Do **not** implement these in this PR:
- Dedicated `GraftPaneView` showing the sync log. v1 puts the log in a popover hung off the inspector button — single SwiftUI view, no new pane type, no DB persistence of sessions.
- Configurable debounce / ignore set / `--no-verify` toggle via the keybindings config. Document defaults; add settings later if anyone asks.
- Multi-target sync (e.g. one worktree → many roots). Pure 1:1 for now.
- Conflict-aware sync. The current design force-checkouts the root (see "Force checkout discards work" below). If anyone reports lost work, revisit then.

## 9. Risks to keep in mind while implementing

- **Hooks on every checkpoint.** We commit a checkpoint in the worktree on every debounced batch, passing `--no-verify` to skip hooks (otherwise pre-commit linters would thrash the loop). Document this in the tooltip or settings UI so users aren't surprised that pre-commit linters don't run on graft checkpoints.
- **`stash@{0}` is not stable.** Always capture the SHA via `git rev-parse refs/stash` right after `stash push`, and pop by SHA — not by `stash@{0}` index, which shifts if anything else stashes.
- **Force checkout discards work.** The Stop sequence runs `git checkout -f HEAD --` in the parent root. If a user happened to edit a file in the parent root mid-graft, those edits are gone. Accept it but mention it in the toggle-off tooltip.
- **FSEvents coalescing.** With `kFSEventStreamCreateFlagFileEvents` you get per-file paths, but FSEvents still batches under load. The 500ms debounce on top is what guarantees correct behaviour, not the FSEvents config.
- **Test isolation.** Real FSEvents in tests are flaky. The `RecursiveFSWatcher.testValue` must be a fully synthetic injection point. `GraftServiceTests` uses real git but a fake watcher.

## 10. Suggested commit sequence

Each commit should be independently buildable.

1. `feat(graft): RecursiveFSWatcher service + tests`
2. `feat(graft): extend GitService with stash/commit/checkout/state helpers + tests`
3. `feat(graft): GraftService state machine + tests`
4. `feat(graft): GraftFeature reducer + tests`
5. `feat(graft): inspector button + orphan-recovery banner`
6. `feat(graft): nex graft start/stop/status CLI`
7. `docs(graft): README note + CLAUDE.md architecture entry`

Final commit updates `CLAUDE.md` with a `### Graft` section under `## Architecture`, mirroring the existing "Markdown panes" and "Diff panes" sections.
