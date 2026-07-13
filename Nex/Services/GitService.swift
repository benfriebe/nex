import ComposableArchitecture
import Foundation

struct ScannedRepo: Equatable {
    let path: String
    let name: String
}

struct WorktreeInfo: Equatable {
    let path: String
    let branch: String?
    let isMain: Bool
}

struct RepoRootInfo: Equatable {
    let worktreeRoot: String
    let parentRepoRoot: String
}

/// In-progress operations that block graft mirroring. `clean` means
/// `git status` is dirty-allowed but there is no merge/rebase/etc in
/// flight. `unknown` covers anything we don't explicitly recognise.
enum RepoState: Equatable {
    case clean
    case merge
    case rebase
    case cherryPick
    case revert
    case bisect
    case unknown(String)
}

struct GitService {
    var scanForRepos: @Sendable (_ rootPath: String, _ maxDepth: Int) async throws -> [ScannedRepo]
    var getRemoteURL: @Sendable (_ repoPath: String) async throws -> String?
    var getCurrentBranch: @Sendable (_ path: String) async throws -> String?
    var getStatus: @Sendable (_ path: String) async throws -> RepoGitStatus
    var createWorktree: @Sendable (_ repoPath: String, _ worktreePath: String, _ branchName: String) async throws -> Void
    /// `git worktree add -b <branch> <path> <baseRef>` — creates the
    /// worktree on a new branch based on an explicit ref (e.g.
    /// `origin/main`) rather than the current HEAD. Used by the
    /// "update main first" inline-worktree flow (issue #222).
    var createWorktreeFromBase: @Sendable (_ repoPath: String, _ worktreePath: String, _ branchName: String, _ baseRef: String) async throws -> Void
    /// The repository's default branch name (e.g. `main`), resolved from
    /// `origin/HEAD`. Falls back to `main` when there is no remote HEAD
    /// symref. Used to base a fresh worktree on `origin/<default>`.
    var defaultBranch: @Sendable (_ repoPath: String) async throws -> String
    /// `git fetch <remote>` — refresh remote-tracking refs before
    /// branching a worktree off the freshly-updated default branch.
    var fetch: @Sendable (_ repoPath: String, _ remote: String) async throws -> Void
    var removeWorktree: @Sendable (_ repoPath: String, _ worktreePath: String) async throws -> Void
    var listWorktrees: @Sendable (_ repoPath: String) async throws -> [WorktreeInfo]
    var pruneWorktrees: @Sendable (_ repoPath: String) async throws -> Void
    var resolveRepoRoot: @Sendable (_ path: String) async -> RepoRootInfo?
    var getDiff: @Sendable (_ repoPath: String, _ targetPath: String?) async throws -> String
    var resolveHeadPath: @Sendable (_ worktreePath: String) async throws -> String
    /// `git stash push --include-untracked -m <message>`. Returns the
    /// resulting stash SHA (via `git rev-parse refs/stash`) or `nil` if
    /// there was nothing to stash.
    var stashPushIncludeUntracked: @Sendable (_ repoPath: String, _ message: String) async throws -> String?
    /// `git stash pop <stashRef>`. Pops by SHA so the operation is
    /// stable across other stashes landing in the meantime.
    var stashPopRef: @Sendable (_ repoPath: String, _ stashRef: String) async throws -> Void
    /// `git add -A` + `git commit -m <msg>` (optionally `--no-verify`).
    /// Returns the staged paths captured between add and commit. If
    /// nothing is staged the function is a no-op and returns `[]`.
    var addAllAndCommit: @Sendable (_ worktreePath: String, _ message: String, _ noVerify: Bool) async throws -> [String]
    /// `git checkout -f <branchOrSha> --`. Used to overwrite the
    /// parent root's tree on every graft sync.
    var checkoutBranchForce: @Sendable (_ repoPath: String, _ branchOrSha: String) async throws -> Void
    /// `git checkout -f HEAD --`. Used on graft stop to discard the
    /// synced tree before popping the user's stash.
    var checkoutHeadForce: @Sendable (_ repoPath: String) async throws -> Void
    /// Inspect git-dir for merge/rebase/cherry-pick/revert/bisect
    /// breadcrumbs. Returns `.clean` when no operation is in flight.
    var repoState: @Sendable (_ repoPath: String) async throws -> RepoState
    /// `git rev-parse HEAD` — returns the SHA of the current HEAD.
    /// Used by the graft sync pass to fall back to SHA-based
    /// checkout when the worktree is on a branch the parent root
    /// doesn't know, or detached.
    var getHeadSha: @Sendable (_ repoPath: String) async throws -> String
    /// `git reset --hard <sha>` — rewinds the current branch to a
    /// specific SHA, discarding working tree and index changes. Used
    /// on graft stop to roll the parent root back to its pre-graft
    /// state before popping the user's stash. Without this step,
    /// the parent's branch ref still points at the checkpoint
    /// commits graft made during the session.
    var resetHard: @Sendable (_ repoPath: String, _ sha: String) async throws -> Void
    /// `git reset --mixed <sha>` — rewinds the current branch ref and
    /// the index to `<sha>` but leaves working-tree files untouched.
    /// Used on graft stop in the WORKTREE so the checkpoint commits
    /// disappear while the user's actual edits remain on disk as
    /// uncommitted changes.
    var resetMixed: @Sendable (_ repoPath: String, _ sha: String) async throws -> Void
    /// Compute the tree SHA representing the worktree's current state
    /// (HEAD + all staged + all unstaged edits) WITHOUT touching the
    /// worktree's real index. Backed by an out-of-band temp index
    /// (`GIT_INDEX_FILE=…`) so the user's pending staging in the
    /// worktree is preserved verbatim.
    ///
    /// This is the worktree-side primitive for the tree-based graft
    /// sync: the parent then applies the tree via `readTreeInto` and
    /// nothing on the worktree's git state changes (no checkpoint
    /// commits, no branch ref movement).
    var writeTreeForWorktree: @Sendable (_ worktreePath: String) async throws -> String
    /// `git read-tree --reset -u <tree>` — replace the repo's index and
    /// working tree with `<tree>`. Used by the parent in graft sync to
    /// mirror the worktree's content without changing the parent's
    /// HEAD / branch ref.
    var readTreeInto: @Sendable (_ repoPath: String, _ treeSha: String) async throws -> Void
}

// MARK: - Live Implementation

extension GitService {
    static let live = GitService(
        scanForRepos: { rootPath, maxDepth in
            let fm = FileManager.default
            let rootURL = URL(fileURLWithPath: rootPath)
            var repos: [ScannedRepo] = []

            func walk(_ url: URL, depth: Int) {
                guard depth <= maxDepth else { return }
                let gitDir = url.appendingPathComponent(".git")
                // .git can be a directory (regular repo) or a file (worktree)
                if fm.fileExists(atPath: gitDir.path) {
                    repos.append(ScannedRepo(
                        path: url.path,
                        name: url.lastPathComponent
                    ))
                    return // Don't recurse into repos
                }

                guard let children = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { return }

                for child in children {
                    let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        walk(child, depth: depth + 1)
                    }
                }
            }

            walk(rootURL, depth: 0)
            return repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        },

        getRemoteURL: { repoPath in
            let output = try runGit(args: ["remote", "get-url", "origin"], at: repoPath)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        },

        getCurrentBranch: { path in
            let output = try runGit(args: ["rev-parse", "--abbrev-ref", "HEAD"], at: path)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        },

        getStatus: { path in
            let output = try runGit(args: ["status", "--porcelain"], at: path)
            let lines = output.split(separator: "\n").filter { !$0.isEmpty }
            if lines.isEmpty {
                return .clean
            }
            // `--shortstat HEAD` covers both staged and unstaged so the line
            // counts match what `--porcelain` already reports as dirty (which
            // also includes staged). Plain `--shortstat` would miss staged
            // edits and produce +0/-0 for stage-only repos. Errors swallow
            // (e.g. fresh repo with no HEAD yet) so the dirty count survives.
            let shortstat = (try? runGit(args: ["diff", "--shortstat", "HEAD"], at: path)) ?? ""
            let (additions, deletions) = parseShortstat(shortstat)
            return .dirty(changedFiles: lines.count, additions: additions, deletions: deletions)
        },

        createWorktree: { repoPath, worktreePath, branchName in
            // Try creating from existing branch first, fall back to new branch
            do {
                _ = try runGit(args: ["worktree", "add", worktreePath, branchName], at: repoPath)
            } catch {
                _ = try runGit(args: ["worktree", "add", "-b", branchName, worktreePath], at: repoPath)
            }
        },

        createWorktreeFromBase: { repoPath, worktreePath, branchName, baseRef in
            _ = try runGit(args: ["worktree", "add", "-b", branchName, worktreePath, baseRef], at: repoPath)
        },

        defaultBranch: { repoPath in
            // Query the remote directly: `git ls-remote --symref origin HEAD`
            // prints `ref: refs/heads/<default>\tHEAD`. This is robust where
            // the *local* `origin/HEAD` symref is unset — which is common,
            // and a plain `git fetch` does NOT create it — so a repo whose
            // default is `master`/`develop` resolves correctly instead of
            // wrongly falling back to `main` (review of #222).
            if let out = try? runGit(args: ["ls-remote", "--symref", "origin", "HEAD"], at: repoPath) {
                for line in out.split(separator: "\n") where line.hasPrefix("ref:") {
                    let rest = line.dropFirst("ref:".count)
                    let ref = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                    if ref.hasPrefix("refs/heads/") {
                        return String(ref.dropFirst("refs/heads/".count))
                    }
                }
            }
            // Offline / no remote: fall back to the local `origin/HEAD`
            // symref (`refs/remotes/origin/main` → `main`), then `main`.
            if let output = try? runGit(
                args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                at: repoPath
            ) {
                let ref = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ref.isEmpty {
                    if let slash = ref.firstIndex(of: "/") {
                        return String(ref[ref.index(after: slash)...])
                    }
                    return ref
                }
            }
            return "main"
        },

        fetch: { repoPath, remote in
            _ = try runGit(args: ["fetch", remote], at: repoPath)
        },

        removeWorktree: { repoPath, worktreePath in
            _ = try runGit(args: ["worktree", "remove", worktreePath], at: repoPath)
        },

        listWorktrees: { repoPath in
            let output = try runGit(args: ["worktree", "list", "--porcelain"], at: repoPath)
            var worktrees: [WorktreeInfo] = []
            var currentPath: String?
            var currentBranch: String?
            var isMain = false

            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let str = String(line)
                if str.hasPrefix("worktree ") {
                    // Save previous worktree if we have one
                    if let path = currentPath {
                        worktrees.append(WorktreeInfo(path: path, branch: currentBranch, isMain: isMain))
                    }
                    currentPath = String(str.dropFirst("worktree ".count))
                    currentBranch = nil
                    isMain = false
                } else if str.hasPrefix("branch ") {
                    let ref = String(str.dropFirst("branch ".count))
                    currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
                } else if str == "bare" {
                    isMain = true
                } else if str.isEmpty {
                    // Entry separator — first entry is always the main worktree
                    if worktrees.isEmpty {
                        isMain = true
                    }
                }
            }

            // Save last worktree
            if let path = currentPath {
                worktrees.append(WorktreeInfo(path: path, branch: currentBranch, isMain: isMain))
            }

            // Mark first entry as main
            if !worktrees.isEmpty {
                worktrees[0] = WorktreeInfo(
                    path: worktrees[0].path,
                    branch: worktrees[0].branch,
                    isMain: true
                )
            }

            return worktrees
        },

        pruneWorktrees: { repoPath in
            _ = try runGit(args: ["worktree", "prune"], at: repoPath)
        },

        resolveRepoRoot: { path in
            // Skip non-existent paths and non-directories. Avoids spawning
            // git for transient or invalid pwd values.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else {
                return nil
            }

            guard let output = try? runGit(
                args: ["rev-parse", "--show-toplevel", "--git-common-dir"],
                at: path
            ) else {
                return nil
            }

            let lines = output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { return nil }

            let worktreeRoot = lines[0]
            let commonDirRaw = lines[1]

            // --git-common-dir is absolute when the worktree is detached from
            // its repo, but relative (e.g. ".git") for the main worktree.
            let commonDirAbs: String = if commonDirRaw.hasPrefix("/") {
                commonDirRaw
            } else {
                (worktreeRoot as NSString)
                    .appendingPathComponent(commonDirRaw)
            }

            // Strip a trailing "/.git" or "/.git/" to recover the parent repo.
            // For bare repos the common dir is the repo itself; fall back to
            // its parent directory in that case so we still register something
            // sensible.
            let resolvedCommon = (commonDirAbs as NSString).standardizingPath
            let parentRepoRoot: String
            let lastComponent = (resolvedCommon as NSString).lastPathComponent
            if lastComponent == ".git" {
                parentRepoRoot = (resolvedCommon as NSString).deletingLastPathComponent
            } else {
                parentRepoRoot = resolvedCommon
            }

            return RepoRootInfo(
                worktreeRoot: (worktreeRoot as NSString).standardizingPath,
                parentRepoRoot: (parentRepoRoot as NSString).standardizingPath
            )
        },

        getDiff: { repoPath, targetPath in
            var args = ["diff", "--no-color"]
            if let targetPath, !targetPath.isEmpty {
                args += ["--", targetPath]
            }
            return try runGit(args: args, at: repoPath)
        },

        resolveHeadPath: { worktreePath in
            // `--git-path HEAD` returns the absolute path to the worktree's
            // HEAD file. For the main worktree this is `<repo>/.git/HEAD`;
            // for a linked worktree it's `<repo>/.git/worktrees/<name>/HEAD`.
            let raw = try runGit(args: ["rev-parse", "--git-path", "HEAD"], at: worktreePath)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // `--git-path` returns relative paths for the main worktree
            // (e.g. ".git/HEAD"). Resolve against the worktree root.
            let absolute: String = if trimmed.hasPrefix("/") {
                trimmed
            } else {
                (worktreePath as NSString).appendingPathComponent(trimmed)
            }
            return (absolute as NSString).standardizingPath
        },

        stashPushIncludeUntracked: { repoPath, message in
            // `git stash push` is silent on success and prints to stdout
            // when there's nothing to stash. The exit code is 0 in both
            // cases, so we detect the "nothing to stash" outcome by
            // inspecting the output.
            let output = try runGit(
                args: ["stash", "push", "--include-untracked", "-m", message],
                at: repoPath
            )
            if output.contains("No local changes to save") {
                return nil
            }
            let sha = try runGit(args: ["rev-parse", "refs/stash"], at: repoPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? nil : sha
        },

        stashPopRef: { repoPath, stashRef in
            // `git stash pop` requires a `stash@{N}` reference, not a
            // bare SHA. Look up the index that currently matches the
            // recorded SHA — robust against other stashes landing in
            // the meantime. If the stash is gone (user dropped it),
            // treat as a no-op so the rest of the stop sequence can
            // still clean up.
            let listing = try runGit(args: ["stash", "list", "--format=%H"], at: repoPath)
            let shas = listing
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let index = shas.firstIndex(of: stashRef) else { return }
            _ = try runGit(args: ["stash", "pop", "stash@{\(index)}"], at: repoPath)
        },

        addAllAndCommit: { worktreePath, message, noVerify in
            _ = try runGit(args: ["add", "-A"], at: worktreePath)
            let staged = try runGit(
                args: ["diff", "--name-only", "--cached"],
                at: worktreePath
            )
            let paths = staged
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !paths.isEmpty else { return [] }
            var commitArgs = ["commit", "-m", message]
            if noVerify { commitArgs.append("--no-verify") }
            _ = try runGit(args: commitArgs, at: worktreePath)
            return paths
        },

        checkoutBranchForce: { repoPath, branchOrSha in
            _ = try runGit(args: ["checkout", "-f", branchOrSha, "--"], at: repoPath)
        },

        checkoutHeadForce: { repoPath in
            _ = try runGit(args: ["checkout", "-f", "HEAD", "--"], at: repoPath)
        },

        repoState: { repoPath in
            let raw = try runGit(args: ["rev-parse", "--git-dir"], at: repoPath)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let gitDir: String = if trimmed.hasPrefix("/") {
                trimmed
            } else {
                (repoPath as NSString).appendingPathComponent(trimmed)
            }
            let fm = FileManager.default
            func exists(_ component: String) -> Bool {
                fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(component))
            }
            if exists("MERGE_HEAD") { return .merge }
            if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
            if exists("CHERRY_PICK_HEAD") { return .cherryPick }
            if exists("REVERT_HEAD") { return .revert }
            if exists("BISECT_LOG") { return .bisect }
            return .clean
        },

        getHeadSha: { repoPath in
            let raw = try runGit(args: ["rev-parse", "HEAD"], at: repoPath)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        },

        resetHard: { repoPath, sha in
            _ = try runGit(args: ["reset", "--hard", sha], at: repoPath)
        },

        resetMixed: { repoPath, sha in
            _ = try runGit(args: ["reset", "--mixed", sha], at: repoPath)
        },

        writeTreeForWorktree: { worktreePath in
            // Build a throw-away index file so the user's real
            // staging in the worktree survives untouched. The
            // sequence: seed the temp index with HEAD's tree → stage
            // every working-tree change (`add -A`) into the temp
            // index → write that index out as a tree. The resulting
            // tree SHA represents "worktree's working tree as a
            // single committable snapshot".
            let tempDir = NSTemporaryDirectory() as NSString
            let tempIndex = tempDir.appendingPathComponent("nex-graft-index-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(atPath: tempIndex) }
            let env = ["GIT_INDEX_FILE": tempIndex]
            _ = try runGit(args: ["read-tree", "HEAD"], at: worktreePath, env: env)
            _ = try runGit(args: ["add", "-A"], at: worktreePath, env: env)
            let raw = try runGit(args: ["write-tree"], at: worktreePath, env: env)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        },

        readTreeInto: { repoPath, treeSha in
            // `--reset -u`: reset the repo's index to the given tree
            // AND update the working tree to match. Tracked files
            // that differ get overwritten; tracked files absent from
            // the new tree are removed. Untracked files (node_modules,
            // build artifacts, ignored caches) are left alone.
            _ = try runGit(args: ["read-tree", "--reset", "-u", treeSha], at: repoPath)
        }
    )
}

// MARK: - Helpers

private func runGit(args: [String], at directory: String, env: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    if let env, !env.isEmpty {
        // Inherit the parent process env so PATH, HOME, etc. survive.
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in env {
            merged[key] = value
        }
        process.environment = merged
    }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitServiceError.commandFailed(
            command: "git \(args.joined(separator: " "))",
            exitCode: Int(process.terminationStatus),
            stderr: errText
        )
    }
    return String(data: data, encoding: .utf8) ?? ""
}

enum GitServiceError: Error, Equatable {
    /// `stderr` carries the message git printed (e.g. "error: Untracked
    /// working tree file '<path>' would be overwritten by merge") so
    /// the graft sync error tooltip can surface something actionable
    /// instead of `exitCode: 128`.
    case commandFailed(command: String, exitCode: Int, stderr: String?)
}

/// Parse a `git diff --shortstat` summary line into (additions, deletions).
/// Examples:
///   " 3 files changed, 27 insertions(+), 12 deletions(-)"
///   " 1 file changed, 5 insertions(+)"
///   " 1 file changed, 3 deletions(-)"
///   "" (no diff)
func parseShortstat(_ text: String) -> (additions: Int, deletions: Int) {
    var additions = 0
    var deletions = 0
    for part in text.split(separator: ",") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        let tokens = trimmed.split(separator: " ", maxSplits: 1)
        guard let first = tokens.first, let count = Int(first) else { continue }
        if trimmed.contains("insertion") { additions = count }
        if trimmed.contains("deletion") { deletions = count }
    }
    return (additions, deletions)
}

// MARK: - TCA Dependency

extension GitService: DependencyKey {
    static var liveValue: GitService { .live }

    static var testValue: GitService {
        GitService(
            scanForRepos: unimplemented("GitService.scanForRepos"),
            getRemoteURL: unimplemented("GitService.getRemoteURL"),
            getCurrentBranch: unimplemented("GitService.getCurrentBranch"),
            getStatus: unimplemented("GitService.getStatus"),
            createWorktree: unimplemented("GitService.createWorktree"),
            createWorktreeFromBase: unimplemented("GitService.createWorktreeFromBase"),
            defaultBranch: unimplemented("GitService.defaultBranch", placeholder: "main"),
            fetch: unimplemented("GitService.fetch"),
            removeWorktree: unimplemented("GitService.removeWorktree"),
            listWorktrees: unimplemented("GitService.listWorktrees"),
            pruneWorktrees: unimplemented("GitService.pruneWorktrees"),
            resolveRepoRoot: { _ in nil },
            getDiff: { _, _ in "" },
            // Non-failing stub: an empty path causes `open()` to return -1
            // in `GitHeadWatcher`, so the watcher silently no-ops in tests
            // that don't care about HEAD watching. Tests that do care should
            // override this to return a real HEAD path.
            resolveHeadPath: { _ in "" },
            stashPushIncludeUntracked: unimplemented("GitService.stashPushIncludeUntracked", placeholder: nil),
            stashPopRef: unimplemented("GitService.stashPopRef"),
            addAllAndCommit: unimplemented("GitService.addAllAndCommit", placeholder: []),
            checkoutBranchForce: unimplemented("GitService.checkoutBranchForce"),
            checkoutHeadForce: unimplemented("GitService.checkoutHeadForce"),
            repoState: unimplemented("GitService.repoState", placeholder: .clean),
            getHeadSha: unimplemented("GitService.getHeadSha", placeholder: ""),
            resetHard: unimplemented("GitService.resetHard"),
            resetMixed: unimplemented("GitService.resetMixed"),
            writeTreeForWorktree: unimplemented("GitService.writeTreeForWorktree", placeholder: ""),
            readTreeInto: unimplemented("GitService.readTreeInto")
        )
    }
}

extension DependencyValues {
    var gitService: GitService {
        get { self[GitService.self] }
        set { self[GitService.self] = newValue }
    }
}
