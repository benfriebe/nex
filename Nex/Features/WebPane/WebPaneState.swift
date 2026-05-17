import Foundation

/// A single tab inside a `.web` pane.
struct WebTab: Equatable, Identifiable, Codable {
    let id: UUID
    var url: String
    var title: String

    init(id: UUID = UUID(), url: String, title: String = "") {
        self.id = id
        self.url = url
        self.title = title
    }

    /// Title used in the pane header and the chrome tab pill. Falls
    /// back through title -> host -> url -> "New Tab" so a tab that
    /// hasn't reported a title yet still shows something meaningful.
    var displayLabel: String {
        if !title.isEmpty { return title }
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        if !url.isEmpty { return url }
        return "New Tab"
    }
}

/// Sidecar state for a `.web` pane. Lives on `WorkspaceFeature.State`
/// in the `webPanes: [UUID: WebPaneState]` dictionary, keyed by pane
/// id. Kept off the `Pane` struct itself so consumers that don't care
/// about web pane internals don't have to learn the type.
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

    func index(of tabID: UUID) -> Int? {
        tabs.firstIndex(where: { $0.id == tabID })
    }

    func contains(tabID: UUID) -> Bool {
        tabs.contains(where: { $0.id == tabID })
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
