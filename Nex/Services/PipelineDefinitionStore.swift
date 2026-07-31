import ComposableArchitecture
import Foundation

/// Filesystem-backed CRUD + change notifications for pipeline
/// definitions living at `~/.config/nex/pipelines/*.yaml`. The canvas
/// editor autosaves through this store (config-file-as-source-of-truth,
/// the `ProfilesSettingsView` idiom) and `nex pipeline` CLI verbs read
/// through it too.
struct PipelineDefinitionStore: Sendable {
    /// Sorted definition ids currently on disk (filename minus `.yaml`).
    var list: @Sendable () -> [String]
    var load: @Sendable (_ id: String) throws -> PipelineDefinition
    /// Writes `definition` to `<id>.yaml`, creating the pipelines
    /// directory if needed. Records the write so `watch()` can suppress
    /// the FS event this save itself produces.
    var save: @Sendable (_ definition: PipelineDefinition) throws -> Void
    var delete: @Sendable (_ id: String) throws -> Void
    /// Emits whenever a definition file changes on disk for a reason
    /// other than this store's own `save`/`delete` calls (self-write
    /// echo suppression) — the signal to re-list/reload.
    var watch: @Sendable () -> AsyncStream<Void>
}

enum PipelineDefinitionStoreError: Error, Equatable, LocalizedError {
    case notFound(String)
    case invalidID(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(id): "Pipeline \"\(id)\" not found"
        case let .invalidID(id): "Invalid pipeline id \"\(id)\""
        }
    }
}

/// Live implementation. Mirrors `GraftServiceImpl`'s "class + NSLock +
/// nonisolated(unsafe)" shape rather than an actor, since the FS
/// operations here are all synchronous.
final class PipelineDefinitionStoreImpl: @unchecked Sendable {
    let directory: String
    private let watcher: RecursiveFSWatcher
    private let lock = NSLock()
    /// path -> mtime of this store's own writes, so `watch()` can
    /// distinguish "I just saved this" from "something else changed
    /// it" (an open + dirty editor pane should surface a conflict
    /// banner only for the latter).
    private var selfWrites: [String: Date] = [:]

    init(directory: String, watcher: RecursiveFSWatcher) {
        self.directory = directory
        self.watcher = watcher
    }

    private func path(for id: String) -> String {
        (directory as NSString).appendingPathComponent("\(id).yaml")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }

    func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return entries
            .filter { $0.hasSuffix(".yaml") }
            .map { String($0.dropLast(".yaml".count)) }
            .sorted()
    }

    func load(id: String) throws -> PipelineDefinition {
        guard PipelineDefinition.isValidSlug(id) else {
            throw PipelineDefinitionStoreError.invalidID(id)
        }
        let filePath = path(for: id)
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            throw PipelineDefinitionStoreError.notFound(id)
        }
        return try PipelineDefinition.fromYAML(contents, id: id)
    }

    func save(_ definition: PipelineDefinition) throws {
        guard PipelineDefinition.isValidSlug(definition.id) else {
            throw PipelineDefinitionStoreError.invalidID(definition.id)
        }
        try ensureDirectory()
        let yaml = try definition.toYAML()
        let filePath = path(for: definition.id)
        try yaml.write(toFile: filePath, atomically: true, encoding: .utf8)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date)
            .flatMap(\.self) ?? Date()
        lock.withLock { selfWrites[filePath] = mtime }
    }

    func delete(id: String) throws {
        guard PipelineDefinition.isValidSlug(id) else {
            throw PipelineDefinitionStoreError.invalidID(id)
        }
        let filePath = path(for: id)
        try FileManager.default.removeItem(atPath: filePath)
        lock.withLock { selfWrites.removeValue(forKey: filePath) }
    }

    func watch() -> AsyncStream<Void> {
        try? ensureDirectory()
        let paths = watcher.start(rootPath: directory, ignoredComponents: [])
        return AsyncStream { continuation in
            let task = Task { [lock, weak self] in
                for await batch in paths {
                    guard let self else { break }
                    let echoesOnly = batch.allSatisfy { changedPath in
                        guard let recorded = lock.withLock({ self.selfWrites[changedPath] }) else {
                            return false
                        }
                        let currentMTime = (try? FileManager.default
                            .attributesOfItem(atPath: changedPath)[.modificationDate] as? Date)?.flatMap(\.self)
                        return currentMTime == recorded
                    }
                    if !echoesOnly {
                        continuation.yield(())
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - TCA Dependency

extension PipelineDefinitionStore: DependencyKey {
    static let liveValue: PipelineDefinitionStore = makeLive(
        directory: ("~/.config/nex/pipelines" as NSString).expandingTildeInPath,
        watcher: RecursiveFSWatcher.liveValue
    )

    static func makeLive(directory: String, watcher: RecursiveFSWatcher) -> PipelineDefinitionStore {
        let impl = PipelineDefinitionStoreImpl(directory: directory, watcher: watcher)
        return PipelineDefinitionStore(
            list: { impl.list() },
            load: { try impl.load(id: $0) },
            save: { try impl.save($0) },
            delete: { try impl.delete(id: $0) },
            watch: { impl.watch() }
        )
    }

    static let testValue = PipelineDefinitionStore(
        list: { [] },
        load: { id in throw PipelineDefinitionStoreError.notFound(id) },
        save: { _ in },
        delete: { _ in },
        watch: { AsyncStream { _ in } }
    )
}

extension DependencyValues {
    var pipelineDefinitionStore: PipelineDefinitionStore {
        get { self[PipelineDefinitionStore.self] }
        set { self[PipelineDefinitionStore.self] = newValue }
    }
}
