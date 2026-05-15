import ComposableArchitecture
import CoreServices
import Foundation

/// Recursive directory watcher backed by FSEvents. Emits a batched array
/// of changed paths after `debounce` ms of quiet. Used by `GraftService`
/// to drive worktree-to-root mirroring.
///
/// At rest this costs zero CPU: FSEvents only wakes the dispatch queue
/// on actual filesystem events. Per active watch: one FSEventStream +
/// a debounce work item.
final class RecursiveFSWatcher: Sendable {
    enum Backend {
        /// Drives real FSEvents. Used in production.
        case live
        /// Inert backend used in tests. `start` registers a continuation
        /// but installs no FSEventStream; callers drive events via
        /// `inject(_:into:)`.
        case test
    }

    /// Marked `@unchecked Sendable` so the teardown hop through
    /// `queue.async` doesn't produce a Swift 6 capture warning. The
    /// individual fields are either value types, locked classes
    /// (`PendingBatch`), or opaque CoreFoundation pointers
    /// (`FSEventStreamRef`) which we only touch on the FSEvents
    /// dispatch queue.
    private struct LiveSession: @unchecked Sendable {
        let rootPath: String
        let stream: FSEventStreamRef
        let pending: PendingBatch
        let continuation: AsyncStream<[String]>.Continuation
    }

    private struct TestSession {
        let rootPath: String
        let continuation: AsyncStream<[String]>.Continuation
        let ignoredComponents: Set<String>
        let debounce: DispatchTimeInterval
        let pending: PendingBatch
    }

    fileprivate final class PendingBatch {
        let lock = NSLock()
        var paths: Set<String> = []
        var workItem: DispatchWorkItem?
    }

    private let backend: Backend
    private let queue = DispatchQueue(label: "nex.recursive-fs-watcher", qos: .utility)
    private let lock = NSLock()
    /// nonisolated(unsafe) because every access is gated by `lock`.
    private nonisolated(unsafe) var liveSessions: [UUID: LiveSession] = [:]
    private nonisolated(unsafe) var testSessions: [UUID: TestSession] = [:]

    init(backend: Backend = .live) {
        self.backend = backend
    }

    /// Begin watching `rootPath` recursively. Emits batches of changed
    /// paths whose components don't intersect `ignoredComponents`. The
    /// stream terminates when the consumer task is cancelled or
    /// `stopAll` is called.
    func start(
        rootPath: String,
        debounce: DispatchTimeInterval = .milliseconds(500),
        ignoredComponents: Set<String> = [".git", "node_modules", "target", ".DS_Store"]
    ) -> AsyncStream<[String]> {
        let token = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.stop(token: token)
            }

            switch backend {
            case .live:
                guard installLive(
                    token: token,
                    rootPath: rootPath,
                    debounce: debounce,
                    ignoredComponents: ignoredComponents,
                    continuation: continuation
                ) else {
                    continuation.finish()
                    return
                }
            case .test:
                lock.withLock {
                    testSessions[token] = TestSession(
                        rootPath: rootPath,
                        continuation: continuation,
                        ignoredComponents: ignoredComponents,
                        debounce: debounce,
                        pending: PendingBatch()
                    )
                }
            }
        }
    }

    /// Stop every active watcher. Used on app teardown.
    func stopAll() {
        let (live, test): ([UUID: LiveSession], [UUID: TestSession]) = lock.withLock {
            let l = liveSessions
            let t = testSessions
            liveSessions.removeAll()
            testSessions.removeAll()
            return (l, t)
        }
        for (_, session) in live {
            tearDownLive(session)
        }
        for (_, session) in test {
            session.continuation.finish()
        }
    }

    /// Total number of active watchers across both backends. Test helper.
    var activeCount: Int {
        lock.withLock { liveSessions.count + testSessions.count }
    }

    // MARK: - Test seam

    /// Feed a batch of paths into every test-backed watcher whose
    /// rootPath matches. Ignored components are still filtered so
    /// tests behave like production. Bypasses debounce — tests get
    /// one synchronous batch.
    func inject(_ paths: [String], into rootPath: String) {
        let targets: [TestSession] = lock.withLock {
            testSessions.values.filter { $0.rootPath == rootPath }
        }
        for session in targets {
            let filtered = filterPaths(paths, ignoredComponents: session.ignoredComponents)
            guard !filtered.isEmpty else { continue }
            session.continuation.yield(filtered)
        }
    }

    // MARK: - Live backend

    private func installLive(
        token: UUID,
        rootPath: String,
        debounce: DispatchTimeInterval,
        ignoredComponents: Set<String>,
        continuation: AsyncStream<[String]>.Continuation
    ) -> Bool {
        let pending = PendingBatch()
        let context = Unmanaged<CallbackContext>.passRetained(
            CallbackContext(
                watcher: self,
                token: token,
                pending: pending,
                ignoredComponents: ignoredComponents,
                debounce: debounce,
                continuation: continuation
            )
        ).toOpaque()

        var streamContext = FSEventStreamContext(
            version: 0,
            info: context,
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<CallbackContext>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            recursiveFSWatcherCallback,
            &streamContext,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.0,
            flags
        ) else {
            Unmanaged<CallbackContext>.fromOpaque(context).release()
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        lock.withLock {
            liveSessions[token] = LiveSession(
                rootPath: rootPath,
                stream: stream,
                pending: pending,
                continuation: continuation
            )
        }
        return true
    }

    fileprivate func handleEvents(
        token: UUID,
        paths: [String],
        ignoredComponents: Set<String>,
        debounce: DispatchTimeInterval,
        continuation: AsyncStream<[String]>.Continuation,
        pending: PendingBatch
    ) {
        let filtered = filterPaths(paths, ignoredComponents: ignoredComponents)
        guard !filtered.isEmpty else { return }

        let shouldSchedule: Bool = pending.lock.withLock {
            for path in filtered {
                pending.paths.insert(path)
            }
            if pending.workItem != nil {
                pending.workItem?.cancel()
            }
            return true
        }
        guard shouldSchedule else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let flushed: [String] = pending.lock.withLock {
                let result = Array(pending.paths)
                pending.paths.removeAll()
                pending.workItem = nil
                return result
            }
            guard !flushed.isEmpty else { return }
            // Ensure the session is still alive before yielding.
            let stillAlive = lock.withLock { liveSessions[token] != nil }
            guard stillAlive else { return }
            continuation.yield(flushed.sorted())
        }
        pending.lock.withLock { pending.workItem = work }
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func stop(token: UUID) {
        let (live, test): (LiveSession?, TestSession?) = lock.withLock {
            let l = liveSessions.removeValue(forKey: token)
            let t = testSessions.removeValue(forKey: token)
            return (l, t)
        }
        if let live {
            tearDownLive(live)
        }
        if let test {
            test.continuation.finish()
        }
    }

    private func tearDownLive(_ session: LiveSession) {
        // FSEventStreamStop / Invalidate / Release must run on the
        // same dispatch queue we wired via `FSEventStreamSetDispatchQueue`
        // — otherwise a callback that's in flight on the watcher
        // queue could dereference a stream that's already been
        // released. Hop teardown onto `queue` (the call site already
        // expects async teardown via the AsyncStream onTermination
        // handler).
        queue.async { [session] in
            self.releaseStream(session)
        }
    }

    private func releaseStream(_ session: LiveSession) {
        session.pending.lock.withLock {
            session.pending.workItem?.cancel()
            session.pending.workItem = nil
            session.pending.paths.removeAll()
        }
        FSEventStreamStop(session.stream)
        FSEventStreamInvalidate(session.stream)
        FSEventStreamRelease(session.stream)
        session.continuation.finish()
    }

    // MARK: - Filtering

    private func filterPaths(_ paths: [String], ignoredComponents: Set<String>) -> [String] {
        guard !ignoredComponents.isEmpty else { return paths }
        return paths.filter { path in
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            for c in components where ignoredComponents.contains(String(c)) {
                return false
            }
            return true
        }
    }
}

/// Unmanaged-payload bridge for the FSEventStream C callback. Holds the
/// watcher (weak) plus the per-stream identity used by `handleEvents`.
private final class CallbackContext {
    weak var watcher: RecursiveFSWatcher?
    let token: UUID
    let pending: RecursiveFSWatcher.PendingBatch
    let ignoredComponents: Set<String>
    let debounce: DispatchTimeInterval
    let continuation: AsyncStream<[String]>.Continuation

    init(
        watcher: RecursiveFSWatcher,
        token: UUID,
        pending: RecursiveFSWatcher.PendingBatch,
        ignoredComponents: Set<String>,
        debounce: DispatchTimeInterval,
        continuation: AsyncStream<[String]>.Continuation
    ) {
        self.watcher = watcher
        self.token = token
        self.pending = pending
        self.ignoredComponents = ignoredComponents
        self.debounce = debounce
        self.continuation = continuation
    }
}

private func recursiveFSWatcherCallback(
    streamRef _: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags _: UnsafePointer<FSEventStreamEventFlags>,
    eventIds _: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
    guard let watcher = context.watcher else { return }

    let pathsPtr = eventPaths.bindMemory(to: UnsafePointer<CChar>?.self, capacity: numEvents)
    var paths: [String] = []
    paths.reserveCapacity(numEvents)
    for i in 0 ..< numEvents {
        if let cstr = pathsPtr[i] {
            paths.append(String(cString: cstr))
        }
    }
    watcher.handleEvents(
        token: context.token,
        paths: paths,
        ignoredComponents: context.ignoredComponents,
        debounce: context.debounce,
        continuation: context.continuation,
        pending: context.pending
    )
}

// MARK: - TCA Dependency

extension RecursiveFSWatcher: DependencyKey {
    static var liveValue: RecursiveFSWatcher {
        // Real FSEvents would be flaky / slow in test suites. Same
        // gate as `NexApp.isTestMode` (inlined here to keep the
        // computed property nonisolated — the SwiftUI App is
        // main-actor isolated, which `liveValue` is not).
        let isTest = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        return RecursiveFSWatcher(backend: isTest ? .test : .live)
    }

    static let testValue = RecursiveFSWatcher(backend: .test)
}

extension DependencyValues {
    var recursiveFSWatcher: RecursiveFSWatcher {
        get { self[RecursiveFSWatcher.self] }
        set { self[RecursiveFSWatcher.self] = newValue }
    }
}
