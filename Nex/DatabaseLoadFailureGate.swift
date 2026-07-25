import AppKit
import Foundation

/// User's response to the load-failure alert.
enum DatabaseLoadFailureChoice {
    case retry
    case quit
}

/// AppKit alert shown when `PersistenceService.load()` fails (issue
/// #267). A failed load used to be indistinguishable from a genuinely
/// empty first-launch DB, so the app quietly booted into a fresh
/// Default workspace and the very next debounced save overwrote the
/// still-intact data on disk. Now a failure surfaces here instead, and
/// `AppReducer.State.dbLoadFailed` + `PersistenceService`'s own
/// `hasLoadedSuccessfully` guard both refuse to run the destructive
/// clear-and-reinsert write until a load actually succeeds.
///
/// Deliberately only offers Retry/Quit — most causes at this layer
/// (SQLITE_BUSY from a second running instance, a stalled backup tool
/// holding the file, a transient I/O hiccup) are recoverable by trying
/// again once the lock clears. A structurally broken DB (won't even
/// open, or a migration failed) is handled earlier and automatically by
/// `DatabaseService.init`, which quarantines the unreadable file and
/// starts fresh rather than reaching this alert at all.
@MainActor
enum DatabaseLoadFailureGate {
    static func present(errorDescription: String) -> DatabaseLoadFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Nex couldn't load your saved data"
        alert.informativeText = """
        Reading nex.db failed: \(errorDescription)

        To avoid overwriting your existing workspaces, Nex has NOT created a new, empty database. If another Nex instance or a backup tool (Time Machine, iCloud) is using the file, quit it and retry. Quitting Nex now leaves your data untouched.
        """
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .retry : .quit
    }
}
