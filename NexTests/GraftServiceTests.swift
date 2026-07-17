import Foundation
@testable import Nex
import Testing

/// Integration-style tests for the graft state machine. These shell out
/// to `/usr/bin/git` against temporary repositories — the recursive FS
/// watcher is faked so events are deterministic.
@MainActor
struct GraftServiceTests {
    @Test func startOnCleanRootSkipsStash() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )

        let session = try await impl.start(env.association)

        #expect(session.stashRef == nil)
        let breadcrumb = try loadBreadcrumb(at: env.parent)
        #expect(breadcrumb.stashed == false)
        #expect(breadcrumb.stashRef == nil)
        #expect(breadcrumb.worktreePath == env.worktree)

        try await impl.stop(env.association.id)
    }

    @Test func startOnDirtyRootStashesAndRecordsSHA() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        // Dirty the parent root before starting.
        let dirty = (env.parent as NSString).appendingPathComponent("dirty.txt")
        try "dirty contents".write(toFile: dirty, atomically: true, encoding: .utf8)

        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )

        let session = try await impl.start(env.association)
        #expect(session.stashRef != nil)
        let breadcrumb = try loadBreadcrumb(at: env.parent)
        #expect(breadcrumb.stashed == true)
        #expect(breadcrumb.stashRef == session.stashRef)

        let stashList = try shell("git", ["stash", "list"], at: env.parent)
        #expect(stashList.contains("nex-graft:\(env.association.id.uuidString)"))

        try await impl.stop(env.association.id)
    }

    @Test func syncMirrorsTrackedFilesToParentWithoutCommitting() async throws {
        // Under the tree-based design: the worktree's branch ref and
        // index are never touched. The parent's working tree gets
        // updated to reflect the worktree's content (via
        // `read-tree --reset -u`), but the parent's HEAD / branch
        // ref also stays put.
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let watcher = RecursiveFSWatcher(backend: .test)
        let impl = GraftServiceImpl(gitService: .live, watcher: watcher)

        let worktreeInitialSHA = try shell(
            "git", ["rev-parse", "HEAD"], at: env.worktree
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let parentInitialSHA = try shell(
            "git", ["rev-parse", "HEAD"], at: env.parent
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await impl.start(env.association)

        let newFile = (env.worktree as NSString).appendingPathComponent("synced.txt")
        try "hello graft".write(toFile: newFile, atomically: true, encoding: .utf8)
        watcher.inject([newFile], into: env.worktree)

        // Poll for the file to land in the parent. The tree-based
        // sync writes tracked files via read-tree, so the parent's
        // working tree sees them without any commit.
        let parentFile = (env.parent as NSString).appendingPathComponent("synced.txt")
        try await pollUntil(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: parentFile)
        }

        // Worktree branch ref must NOT have moved — no checkpoint
        // commit appended.
        let worktreeSHAAfter = try shell(
            "git", ["rev-parse", "HEAD"], at: env.worktree
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(worktreeSHAAfter == worktreeInitialSHA)

        // Parent's HEAD ref also unchanged (no detached HEAD).
        let parentSHAAfter = try shell(
            "git", ["rev-parse", "HEAD"], at: env.parent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(parentSHAAfter == parentInitialSHA)

        // No `nex-graft: checkpoint` commit anywhere.
        let worktreeLog = try shell("git", ["log", "--pretty=%s"], at: env.worktree)
        #expect(!worktreeLog.contains("nex-graft: checkpoint"))
        let parentLog = try shell("git", ["log", "--pretty=%s"], at: env.parent)
        #expect(!parentLog.contains("nex-graft: checkpoint"))

        try await impl.stop(env.association.id)
    }

    @Test func stopRestoresParentWorkingTreeAndKeepsWorktreeUntouched() async throws {
        // After the tree-based redesign: stop restores the parent's
        // working tree to its pre-graft branch HEAD via
        // `git reset --hard <preGraftSha>`, and the worktree is
        // never touched at any point.
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let watcher = RecursiveFSWatcher(backend: .test)
        let impl = GraftServiceImpl(gitService: .live, watcher: watcher)

        let parentInitialBranch = try shell(
            "git", ["rev-parse", "--abbrev-ref", "HEAD"], at: env.parent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let parentInitialSHA = try shell(
            "git", ["rev-parse", "HEAD"], at: env.parent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreeInitialSHA = try shell(
            "git", ["rev-parse", "HEAD"], at: env.worktree
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await impl.start(env.association)

        // Drive a sync so the parent has the worktree's content.
        let newFile = (env.worktree as NSString).appendingPathComponent("synced.txt")
        try "hello".write(toFile: newFile, atomically: true, encoding: .utf8)
        watcher.inject([newFile], into: env.worktree)
        let parentFile = (env.parent as NSString).appendingPathComponent("synced.txt")
        try await pollUntil(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: parentFile)
        }

        try await impl.stop(env.association.id)

        // Parent restored: same branch, same SHA, synced file gone.
        let parentBranchAfter = try shell(
            "git", ["rev-parse", "--abbrev-ref", "HEAD"], at: env.parent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let parentSHAAfter = try shell(
            "git", ["rev-parse", "HEAD"], at: env.parent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(parentBranchAfter == parentInitialBranch)
        #expect(parentSHAAfter == parentInitialSHA)
        #expect(!FileManager.default.fileExists(atPath: parentFile))

        // Worktree completely untouched.
        let worktreeSHAAfter = try shell(
            "git", ["rev-parse", "HEAD"], at: env.worktree
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(worktreeSHAAfter == worktreeInitialSHA)
        // The user's actual edit on disk is preserved (it's never been
        // touched by git).
        #expect(FileManager.default.fileExists(atPath: newFile))
    }

    @Test func startOnMainRepoRefuses() async throws {
        // Graft is a worktree-to-parent mirror; running it on the
        // parent repo itself would self-reference. Reject up front.
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let mainAssoc = RepoAssociation(
            id: UUID(),
            repoID: UUID(),
            worktreePath: env.parent,
            branchName: "main"
        )
        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )
        do {
            _ = try await impl.start(mainAssoc)
            Issue.record("expected GraftError.notAWorktree")
        } catch let error as GraftError {
            if case .notAWorktree = error {
                // ok
            } else {
                Issue.record("unexpected GraftError: \(error)")
            }
        }
    }

    @Test func stopAfterDirtyStartPopsStashAndRemovesBreadcrumb() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let dirty = (env.parent as NSString).appendingPathComponent("dirty.txt")
        try "dirty contents".write(toFile: dirty, atomically: true, encoding: .utf8)

        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )
        _ = try await impl.start(env.association)
        try await impl.stop(env.association.id)

        let breadcrumbPath = (env.parent as NSString)
            .appendingPathComponent(".git/\(GraftServiceImpl.breadcrumbName)")
        #expect(!FileManager.default.fileExists(atPath: breadcrumbPath))

        // Dirty file is restored.
        let restored = try String(contentsOfFile: dirty)
        #expect(restored == "dirty contents")
    }

    @Test func doubleStartOnSameParentRootThrowsAlreadyActive() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let secondWorktree = try addSiblingWorktree(parent: env.parent, name: "feature-2")
        let secondAssoc = RepoAssociation(
            id: UUID(),
            repoID: UUID(),
            worktreePath: secondWorktree,
            branchName: "feature-2"
        )
        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )

        _ = try await impl.start(env.association)
        do {
            _ = try await impl.start(secondAssoc)
            Issue.record("expected GraftError.alreadyActive")
        } catch let error as GraftError {
            if case .alreadyActive = error {
                // ok
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }

        try await impl.stop(env.association.id)
    }

    /// Heart of issue #231 at the service level: a live session whose
    /// sync failed (worktree deleted) still holds the parent-root
    /// claim — a second start must be rejected — but the claim is
    /// derived from the session itself, so `stop` releases it and a
    /// retry succeeds. Under the old standalone `busyRoots` set, a
    /// removal path that skipped `stop` left the claim held forever.
    @Test func erroredSessionBlocksSecondStartUntilStopped() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let secondWorktree = try addSiblingWorktree(parent: env.parent, name: "feature-2")
        let secondAssoc = RepoAssociation(
            id: UUID(),
            repoID: UUID(),
            worktreePath: secondWorktree,
            branchName: "feature-2"
        )
        let watcher = RecursiveFSWatcher(backend: .test)
        let impl = GraftServiceImpl(gitService: .live, watcher: watcher)

        _ = try await impl.start(env.association)

        // Delete the worktree out from under the session, then poke
        // the watcher — the sync pass fails with `missingWorktree`
        // and the session flips to `.error` while staying live.
        try FileManager.default.removeItem(atPath: env.worktree)
        watcher.inject(
            [(env.worktree as NSString).appendingPathComponent("gone.txt")],
            into: env.worktree
        )
        try await pollUntilAsync(timeout: .seconds(5)) {
            let sessions = await impl.activeSessions()
            if case .error = sessions.first(where: { $0.id == env.association.id })?.status {
                return true
            }
            return false
        }

        // The errored session still owns the parent root.
        do {
            _ = try await impl.start(secondAssoc)
            Issue.record("expected GraftError.alreadyActive")
        } catch let error as GraftError {
            if case .alreadyActive = error {
                // ok
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }

        // Stopping the errored session releases the claim...
        try await impl.stop(env.association.id)
        let after = await impl.activeSessions()
        #expect(after.isEmpty)

        // ...so the retry on the same parent root now succeeds.
        let session = try await impl.start(secondAssoc)
        #expect(session.parentRepoRoot.hasSuffix((env.parent as NSString).lastPathComponent))
        try await impl.stop(secondAssoc.id)
    }

    /// A start that fails (parent mid-merge) must release the
    /// mid-start root claim so a later attempt isn't rejected with a
    /// phantom `alreadyActive`.
    @Test func failedStartReleasesRootClaimForRetry() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )

        // Fake an in-progress merge in the parent.
        let headSha = try shell("git", ["rev-parse", "HEAD"], at: env.parent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeHead = (env.parent as NSString)
            .appendingPathComponent(".git/MERGE_HEAD")
        try headSha.write(toFile: mergeHead, atomically: true, encoding: .utf8)

        do {
            _ = try await impl.start(env.association)
            Issue.record("expected GraftError.repoBusy")
        } catch let error as GraftError {
            if case .repoBusy = error {
                // ok
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }

        // Clear the merge state; the retry must not hit alreadyActive.
        try FileManager.default.removeItem(atPath: mergeHead)
        _ = try await impl.start(env.association)
        try await impl.stop(env.association.id)
    }

    /// Concurrent stops of the same session coalesce onto one
    /// teardown: both callers succeed, the stash pops exactly once,
    /// and neither returns before the teardown finished.
    @Test func concurrentStopsCoalesceAndPopStashOnce() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        // Dirty the parent so a stash exists — a double-run of the
        // stop sequence would pop twice and the second would throw a
        // spurious stashPopConflict.
        let dirty = (env.parent as NSString).appendingPathComponent("dirty.txt")
        try "dirty contents".write(toFile: dirty, atomically: true, encoding: .utf8)
        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )
        _ = try await impl.start(env.association)

        let assocID = env.association.id
        async let first: Void = impl.stop(assocID)
        async let second: Void = impl.stop(assocID)
        try await first
        try await second

        let stashList = try shell("git", ["stash", "list"], at: env.parent)
        #expect(!stashList.contains("nex-graft"))
        let restored = try String(contentsOfFile: dirty)
        #expect(restored == "dirty contents")
        let breadcrumbPath = (env.parent as NSString)
            .appendingPathComponent(".git/\(GraftServiceImpl.breadcrumbName)")
        #expect(!FileManager.default.fileExists(atPath: breadcrumbPath))
        let after = await impl.activeSessions()
        #expect(after.isEmpty)
    }

    /// `stop` for an id the service doesn't know is a silent no-op:
    /// no throw, no published `.stopped` event (so reducer mirrors
    /// are never perturbed by stops of start-failure placeholders).
    @Test func stopUnknownAssociationIsSilentNoOp() async throws {
        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )
        let events = LockedEventCount()
        let stream = impl.updates()
        let listener = Task {
            for await _ in stream {
                events.increment()
            }
        }

        try await impl.stop(UUID())
        try await Task.sleep(for: .milliseconds(200))
        #expect(events.value == 0)
        listener.cancel()
    }

    @Test func detectOrphansReturnsPreseededBreadcrumb() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let breadcrumbPath = (env.parent as NSString)
            .appendingPathComponent(".git/\(GraftServiceImpl.breadcrumbName)")
        let payload: [String: Any] = [
            "version": 1,
            "stashed": true,
            "assocId": env.association.id.uuidString,
            "stashRef": "deadbeef00000000",
            "worktreePath": env.worktree,
            "branch": "feature"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: breadcrumbPath))

        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )
        let orphans = await impl.detectOrphans([env.parent])
        #expect(orphans.count == 1)
        #expect(orphans.first?.worktreePath == env.worktree)
        #expect(orphans.first?.stashRef == "deadbeef00000000")
    }

    @Test func dismissOrphanRemovesBreadcrumb() async throws {
        let env = try makeRepoEnv()
        defer { env.cleanup() }
        let breadcrumbPath = (env.parent as NSString)
            .appendingPathComponent(".git/\(GraftServiceImpl.breadcrumbName)")
        let payload: [String: Any] = [
            "version": 1,
            "stashed": false,
            "assocId": env.association.id.uuidString,
            "stashRef": nil as String? as Any,
            "worktreePath": env.worktree,
            "branch": "feature"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: breadcrumbPath))

        let impl = GraftServiceImpl(
            gitService: .live,
            watcher: RecursiveFSWatcher(backend: .test)
        )
        let orphan = GraftOrphan(
            id: env.association.id,
            parentRepoRoot: env.parent,
            worktreePath: env.worktree,
            stashRef: nil
        )
        await impl.dismissOrphan(orphan)
        #expect(!FileManager.default.fileExists(atPath: breadcrumbPath))
    }

    // MARK: - Repo env

    private struct RepoEnv {
        let parent: String
        let worktree: String
        let association: RepoAssociation
        let cleanup: () -> Void
    }

    private func makeRepoEnv() throws -> RepoEnv {
        let tmp = NSTemporaryDirectory()
        let unique = UUID().uuidString
        // Put the worktree OUTSIDE the parent repo so the parent's
        // `git status` stays clean. A nested worktree path would
        // otherwise show up as untracked in the parent.
        let parent = (tmp as NSString)
            .appendingPathComponent("nex-graft-test-\(unique)-parent")
        let worktree = (tmp as NSString)
            .appendingPathComponent("nex-graft-test-\(unique)-worktree")
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )

        _ = try shell("git", ["init"], at: parent)
        _ = try shell("git", ["checkout", "-b", "main"], at: parent)
        _ = try shell("git", ["config", "user.email", "test@nex"], at: parent)
        _ = try shell("git", ["config", "user.name", "Nex Test"], at: parent)
        _ = try shell("git", ["config", "commit.gpgsign", "false"], at: parent)
        _ = try shell("git", ["commit", "--allow-empty", "-m", "initial"], at: parent)

        _ = try shell(
            "git",
            ["worktree", "add", "-b", "feature", worktree],
            at: parent
        )
        _ = try shell("git", ["config", "user.email", "test@nex"], at: worktree)
        _ = try shell("git", ["config", "user.name", "Nex Test"], at: worktree)
        _ = try shell("git", ["config", "commit.gpgsign", "false"], at: worktree)

        let cleanup: () -> Void = {
            try? FileManager.default.removeItem(atPath: parent)
            try? FileManager.default.removeItem(atPath: worktree)
        }
        let assoc = RepoAssociation(
            id: UUID(),
            repoID: UUID(),
            worktreePath: worktree,
            branchName: "feature"
        )
        return RepoEnv(parent: parent, worktree: worktree, association: assoc, cleanup: cleanup)
    }

    private func addSiblingWorktree(parent: String, name: String) throws -> String {
        let tmp = NSTemporaryDirectory()
        let path = (tmp as NSString)
            .appendingPathComponent("nex-graft-test-\(UUID().uuidString)-sibling-\(name)")
        _ = try shell("git", ["worktree", "add", "-b", name, path], at: parent)
        _ = try shell("git", ["config", "user.email", "test@nex"], at: path)
        _ = try shell("git", ["config", "user.name", "Nex Test"], at: path)
        _ = try shell("git", ["config", "commit.gpgsign", "false"], at: path)
        return path
    }

    @discardableResult
    private func shell(_ binary: String, _ args: [String], at directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/" + binary)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let outStr = String(data: data, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GraftTestShell", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(binary) \(args.joined(separator: " ")) failed: \(errStr) | \(outStr)"]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct DecodedBreadcrumb: Codable, Equatable {
        let version: Int
        let stashed: Bool
        let assocId: String
        let stashRef: String?
        let worktreePath: String
        let branch: String
    }

    private func loadBreadcrumb(at parent: String) throws -> DecodedBreadcrumb {
        let path = (parent as NSString)
            .appendingPathComponent(".git/\(GraftServiceImpl.breadcrumbName)")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(DecodedBreadcrumb.self, from: data)
    }

    private func pollUntilAsync(
        timeout: Duration,
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "GraftTestShell", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "poll timed out"]
        )
    }

    private func pollUntil(
        timeout: Duration,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "GraftTestShell", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "poll timed out"]
        )
    }
}

private final class LockedEventCount: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() {
        lock.withLock { _value += 1 }
    }

    var value: Int { lock.withLock { _value } }
}
