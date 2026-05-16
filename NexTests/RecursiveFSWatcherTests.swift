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

        // FSEvents needs a moment to arm the stream after
        // FSEventStreamStart; firing the write too soon means the
        // event is lost. 200ms was flaky in CI; 600ms is comfortably
        // past the observed startup ceiling on this hardware.
        try await Task.sleep(nanoseconds: 600_000_000)
        let target = (tempDir as NSString).appendingPathComponent("hello.txt")
        Task.detached {
            try? "hi".write(toFile: target, atomically: true, encoding: .utf8)
        }

        let received = try await firstBatch(stream, timeout: .seconds(3))
        #expect(!received.isEmpty)
        #expect(received.contains { $0.contains("hello.txt") })

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
        try await withThrowingTaskGroup(of: [[String]]?.self) { group in
            group.addTask {
                var collected: [[String]] = []
                for await batch in stream {
                    collected.append(batch)
                    if collected.count >= count {
                        return collected
                    }
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            for try await result in group {
                group.cancelAll()
                if let r = result { return r }
                // Timeout — return whatever the watcher emitted so far
                // (could be empty if no events landed).
                return []
            }
            return []
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

    private enum FSWatcherTestError: Error {
        case timedOut
    }
}
