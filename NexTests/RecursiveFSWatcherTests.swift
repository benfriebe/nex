import Foundation
@testable import Nex
import Testing

@MainActor
struct RecursiveFSWatcherTests {
    @Test func liveWatcherEmitsEventWithinSecond() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let watcher = RecursiveFSWatcher(backend: .live)
        let stream = watcher.start(rootPath: tempDir, debounce: .milliseconds(100))

        // FSEvents on macOS sometimes drops the very first event
        // unless there's some sustained activity, so write a small
        // burst rather than a single file. The watcher's job is to
        // surface SOMETHING under tempDir within the debounce
        // window; whether it's per-file or just the containing dir
        // depends on macOS version and test-suite load.
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            for i in 0 ..< 4 {
                let path = (tempDir as NSString).appendingPathComponent("hello\(i).txt")
                FileManager.default.createFile(atPath: path, contents: Data("hi".utf8))
            }
        }

        let batches = try await collectBatches(stream, count: 5, timeout: .seconds(5))
        let touched = batches.flatMap(\.self).filter { $0.contains(tempDir) }
        #expect(!touched.isEmpty)

        watcher.stopAll()
    }

    @Test func liveWatcherIgnoresDotGitDirectory() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let gitDir = (tempDir as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            atPath: gitDir, withIntermediateDirectories: true
        )

        let watcher = RecursiveFSWatcher(backend: .live)
        let stream = watcher.start(rootPath: tempDir, debounce: .milliseconds(100))

        let target = (gitDir as NSString).appendingPathComponent("HEAD")
        Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? "ref: refs/heads/main".write(toFile: target, atomically: true, encoding: .utf8)
        }

        // Drain a couple of batches (FSEvents fans out parent-dir
        // notifications even when only `.git/` paths changed). The
        // invariant we care about: no path under `.git/` itself
        // surfaces to the consumer.
        let received = try await collectBatches(stream, count: 1, timeout: .seconds(1))
        let allPaths = received.flatMap(\.self)
        #expect(!allPaths.contains { $0.contains("/.git/") })
        // The .git directory itself ALSO has `.git` as its last
        // component, so it must be filtered too.
        #expect(!allPaths.contains { ($0 as NSString).lastPathComponent == ".git" })

        watcher.stopAll()
    }

    @Test func liveWatcherBatchesRapidWrites() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let watcher = RecursiveFSWatcher(backend: .live)
        let stream = watcher.start(rootPath: tempDir, debounce: .milliseconds(300))

        Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
            for i in 0 ..< 10 {
                let path = (tempDir as NSString).appendingPathComponent("file\(i).txt")
                try? "x".write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        let received = try await firstBatch(stream, timeout: .seconds(3))
        // All 10 writes should coalesce into a single batch under the
        // 300ms debounce. FSEvents itself batches further; the watcher's
        // debounce is the upper bound.
        let touched = received.filter { $0.contains(tempDir) }
        #expect(touched.count >= 5)

        watcher.stopAll()
    }

    @Test func cancelStreamStopsWatcher() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let watcher = RecursiveFSWatcher(backend: .live)

        let task = Task {
            for await _ in watcher.start(rootPath: tempDir) {
                // Drain; cancellation will terminate the loop.
            }
        }

        // Give the watcher a tick to install.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(watcher.activeCount == 1)

        task.cancel()
        // Termination handler runs on cancellation; allow the next runloop.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(watcher.activeCount == 0)
    }

    @Test func backendInjectionDeliversFilteredBatch() async throws {
        let watcher = RecursiveFSWatcher(backend: .test)
        let stream = watcher.start(rootPath: "/tmp/fakeroot")

        Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            watcher.inject([
                "/tmp/fakeroot/a.txt",
                "/tmp/fakeroot/.git/HEAD",
                "/tmp/fakeroot/node_modules/foo/bar.js",
                "/tmp/fakeroot/sub/b.txt"
            ], into: "/tmp/fakeroot")
        }

        let received = try await firstBatch(stream, timeout: .seconds(1))
        #expect(received.contains("/tmp/fakeroot/a.txt"))
        #expect(received.contains("/tmp/fakeroot/sub/b.txt"))
        #expect(!received.contains { $0.contains("/.git/") })
        #expect(!received.contains { $0.contains("/node_modules/") })

        watcher.stopAll()
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("nex-fswatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        // FSEvents resolves the path to its realpath; /tmp -> /private/tmp
        // on macOS. Returning the realpath keeps event paths and the
        // watch root comparable in assertions.
        return ((dir as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    }

    private func collectBatches(
        _ stream: AsyncStream<[String]>,
        count: Int,
        timeout: Duration
    ) async throws -> [[String]] {
        // Shared mutable state so the timeout path can return what
        // the collector saw so far — previous impl threw partial
        // results away which made flaky-but-present events look
        // like total silence.
        let collected = LockedBatches()
        return try await withThrowingTaskGroup(of: [[String]]?.self) { group in
            group.addTask {
                for await batch in stream {
                    let now = collected.append(batch)
                    if now >= count {
                        return collected.snapshot
                    }
                }
                return collected.snapshot
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            for try await result in group {
                group.cancelAll()
                if let r = result { return r }
                // Timeout — return whatever the watcher emitted so far.
                return collected.snapshot
            }
            return collected.snapshot
        }
    }

    private func firstBatch(
        _ stream: AsyncStream<[String]>,
        timeout: Duration
    ) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String]?.self) { group in
            group.addTask {
                for await batch in stream {
                    return batch
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            for try await result in group {
                group.cancelAll()
                if let batch = result {
                    return batch
                }
                throw FSWatcherTestError.timedOut
            }
            throw FSWatcherTestError.timedOut
        }
    }

    /// Mutable batch buffer that the collector and timeout tasks
    /// share so `collectBatches` can return partial results even
    /// when the timeout wins.
    private final class LockedBatches: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String]] = []

        @discardableResult
        func append(_ batch: [String]) -> Int {
            lock.withLock {
                items.append(batch)
                return items.count
            }
        }

        var snapshot: [[String]] {
            lock.withLock { items }
        }
    }

    private enum FSWatcherTestError: Error {
        case timedOut
    }
}
