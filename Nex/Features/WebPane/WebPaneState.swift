import Foundation

/// A single tab inside a `.web` pane. Phase 1 ships with at most one
/// tab per pane; the type carries an `id` already so Phase 2 can add
/// the tab strip without re-shaping persisted state.
struct WebTab: Equatable, Identifiable, Codable {
    let id: UUID
    var url: String
    var title: String

    init(id: UUID = UUID(), url: String, title: String = "") {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// Sidecar state for a `.web` pane. Lives on `WorkspaceFeature.State`
/// in the `webPanes: [UUID: WebPaneState]` dictionary, keyed by pane
/// id. Kept off the `Pane` struct itself so consumers that don't care
/// about web pane internals don't have to learn the type.
///
/// Phase 1 fields only — Phase 3 adds the console buffer and inspector
/// state alongside these.
struct WebPaneState: Equatable {
    var tabs: [WebTab]
    var activeTabID: UUID?
    var isPrivate: Bool

    init(tabs: [WebTab] = [], activeTabID: UUID? = nil, isPrivate: Bool = false) {
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.isPrivate = isPrivate
    }

    /// Convenience: the active tab, or `tabs.first` if `activeTabID`
    /// is stale (e.g. just after a tab close). Returns nil for an
    /// empty-tab pane.
    var activeTab: WebTab? {
        if let id = activeTabID, let tab = tabs.first(where: { $0.id == id }) {
            return tab
        }
        return tabs.first
    }
}

/// `nex web capture` modes. `meta` returns just URL + title; `text`
/// adds visible page text; `screenshot` adds a PNG (inline base64
/// or `/tmp` path depending on size).
enum WebCaptureMode: String {
    case meta
    case text
    case screenshot
}
