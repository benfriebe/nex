import AppKit
import Foundation

/// Bridge between AppKit's document-open callback and the TCA store,
/// mirroring `QuitGate`. `NexAppDelegate.application(_:open:)` hands us
/// each opened markdown file; `NexApp.onAppear` wires `connect` to a
/// closure that forwards the path into the store as `.openFileAtPath`.
///
/// Lives outside TCA because `application(_:open:)` can fire during a
/// cold launch *before* the SwiftUI scene's `.onAppear` has wired the
/// store closure. Paths that arrive early are buffered and replayed the
/// moment `connect` runs, so a double-clicked `.md` that launches Nex is
/// never dropped (issue #197). The reducer handles the second race — an
/// open that arrives after the closure is wired but before the async
/// persistence load has set `activeWorkspaceID` — via `pendingFileOpens`.
@MainActor
final class FileOpenGate {
    static let shared = FileOpenGate()

    /// Extensions Nex claims as markdown, matching the
    /// `UTImportedTypeDeclarations` tag spec in `Info.plist`. Used to
    /// filter the delegate's URLs so an explicit `open -a Nex.app foo.png`
    /// (which bypasses the Info.plist type association) can't render a
    /// binary file as a garbage markdown preview.
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    private var forward: ((String) -> Void)?
    private var buffer: [String] = []

    private init() {}

    /// Called by `NexAppDelegate` for each opened markdown file. Forwards
    /// immediately if the store closure is wired, otherwise buffers until
    /// `connect` runs.
    func open(_ path: String) {
        if let forward {
            forward(path)
        } else {
            buffer.append(path)
        }
    }

    /// Wired by `NexApp.onAppear` once the store exists. Stores the
    /// forwarding closure and drains any paths that arrived before the
    /// scene was ready, in arrival order.
    func connect(_ forward: @escaping (String) -> Void) {
        self.forward = forward
        let queued = buffer
        buffer.removeAll()
        for path in queued {
            forward(path)
        }
    }
}
