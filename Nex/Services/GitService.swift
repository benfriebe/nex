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

struct GitService {
    var scanForRepos: @Sendable (_ rootPath: String, _ maxDepth: Int) async throws -> [ScannedRepo]
    var getRemoteURL: @Sendable (_ repoPath: String) async throws -> String?
    var getCurrentBranch: @Sendable (_ path: String) async throws -> String?
    var getStatus: @Sendable (_ path: String) async throws -> RepoGitStatus
    var createWorktree: @Sendable (_ repoPath: String, _ worktreePath: String, _ branchName: String) async throws -> Void
    var removeWorktree: @Sendable (_ repoPath: String, _ worktreePath: String) async throws -> Void
    var listWorktrees: @Sendable (_ repoPath: String) async throws -> [WorktreeInfo]
    var pruneWorktrees: @Sendable (_ repoPath: String) async throws -> Void
    var resolveRepoRoot: @Sendable (_ path: String) async -> RepoRootInfo?
    var getDiff: @Sendable (_ repoPath: String, _ targetPath: String?) async throws -> String
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
        }
    )
}

// MARK: - Helpers

private func runGit(args: [String], at directory: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw GitServiceError.commandFailed(
            command: "git \(args.joined(separator: " "))",
            exitCode: Int(process.terminationStatus)
        )
    }
    return String(data: data, encoding: .utf8) ?? ""
}

enum GitServiceError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int)
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
            removeWorktree: unimplemented("GitService.removeWorktree"),
            listWorktrees: unimplemented("GitService.listWorktrees"),
            pruneWorktrees: unimplemented("GitService.pruneWorktrees"),
            resolveRepoRoot: { _ in nil },
            getDiff: { _, _ in "" }
        )
    }
}

extension DependencyValues {
    var gitService: GitService {
        get { self[GitService.self] }
        set { self[GitService.self] = newValue }
    }
}
