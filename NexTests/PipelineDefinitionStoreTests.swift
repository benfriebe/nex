import Foundation
@testable import Nex
import Testing

@MainActor
struct PipelineDefinitionStoreTests {
    private func makeTempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("nex-pipeline-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDefinition(id: String) -> PipelineDefinition {
        PipelineDefinition(
            id: id,
            name: "Test Pipeline",
            entry: "only",
            nodes: [PipelineNode(id: "only", prompt: "Do the thing.")]
        )
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PipelineDefinitionStoreImpl(directory: dir, watcher: RecursiveFSWatcher(backend: .test))

        try store.save(makeDefinition(id: "roundtrip"))
        let loaded = try store.load(id: "roundtrip")
        #expect(loaded.name == "Test Pipeline")
        #expect(loaded.id == "roundtrip")
    }

    @Test func listReturnsSortedIDs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PipelineDefinitionStoreImpl(directory: dir, watcher: RecursiveFSWatcher(backend: .test))

        try store.save(makeDefinition(id: "zeta"))
        try store.save(makeDefinition(id: "alpha"))
        #expect(store.list() == ["alpha", "zeta"])
    }

    @Test func loadMissingDefinitionThrowsNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PipelineDefinitionStoreImpl(directory: dir, watcher: RecursiveFSWatcher(backend: .test))

        #expect(throws: PipelineDefinitionStoreError.notFound("missing")) {
            try store.load(id: "missing")
        }
    }

    @Test func loadRejectsInvalidID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PipelineDefinitionStoreImpl(directory: dir, watcher: RecursiveFSWatcher(backend: .test))

        #expect(throws: PipelineDefinitionStoreError.invalidID("Not Valid")) {
            try store.load(id: "Not Valid")
        }
    }

    @Test func deleteRemovesFileFromDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PipelineDefinitionStoreImpl(directory: dir, watcher: RecursiveFSWatcher(backend: .test))

        try store.save(makeDefinition(id: "gone"))
        #expect(store.list() == ["gone"])
        try store.delete(id: "gone")
        #expect(store.list().isEmpty)
    }

    @Test func watchSuppressesSelfWriteEcho() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let watcher = RecursiveFSWatcher(backend: .test)
        let store = PipelineDefinitionStoreImpl(directory: dir, watcher: watcher)

        let stream = store.watch()
        try store.save(makeDefinition(id: "echo"))

        let filePath = (dir as NSString).appendingPathComponent("echo.yaml")
        watcher.inject([filePath], into: dir)

        // Give the self-write echo a moment to (not) propagate, then
        // inject a genuinely external change and confirm THAT surfaces.
        try await Task.sleep(nanoseconds: 50_000_000)
        try "name: Externally Edited\nentry: only\nnodes:\n  - id: only\n    prompt: hi"
            .write(toFile: filePath, atomically: true, encoding: .utf8)
        watcher.inject([filePath], into: dir)

        var received = 0
        let collector = Task {
            for await _ in stream {
                received += 1
                if received >= 1 {
                    break
                }
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        #expect(received == 1)
    }
}
