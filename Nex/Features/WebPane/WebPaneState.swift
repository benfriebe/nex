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

/// One captured console line from a web pane.
struct ConsoleLine: Equatable {
    enum Level: String, Equatable, Codable {
        case log, debug, info, warn, error
    }

    /// Tab the line came from. Phase 3 attributes every line to the
    /// active tab at the time the script handler fired; cross-tab
    /// filtering uses this.
    let tabID: UUID
    let level: Level
    /// Pre-joined argument string (JS-side `args.map(String).join(' ')`).
    let message: String
    let url: String
    let lineNumber: Int?
    let columnNumber: Int?
    let capturedAt: Date
}

/// Which side of the list↔page sync initiated a focus event.
enum BatchFocusOrigin: Equatable {
    case panel
    case page
}

/// One item collected during batch-annotate mode — the captured
/// inspect result plus the user's free-form comment.
struct BatchInspectItem: Equatable, Identifiable {
    let id: UUID
    var result: InspectResult
    var comment: String

    init(id: UUID = UUID(), result: InspectResult, comment: String = "") {
        self.id = id
        self.result = result
        self.comment = comment
    }
}

/// Active batch-annotate session on a web pane. The picker stays
/// armed (sticky) while this is set so each click adds another
/// `BatchInspectItem`; the user finalises with `webBatchInspectSend`
/// or aborts with `webBatchInspectCancel`.
struct BatchInspectState: Equatable {
    var items: [BatchInspectItem]
    /// Item currently focused for bidirectional list↔page sync. Set
    /// when the user taps a panel row or clicks a numbered badge on
    /// the page; the row gets a brief highlight, the page scrolls
    /// the matching element into view, and the badge pulses.
    var focusedItemID: UUID?
    /// Panel on screen + page picker armed. Toggled by the scope
    /// chrome button; items persist across hide/show. On-page markers
    /// follow this flag.
    var panelVisible: Bool

    init(
        items: [BatchInspectItem] = [],
        focusedItemID: UUID? = nil,
        panelVisible: Bool = true
    ) {
        self.items = items
        self.focusedItemID = focusedItemID
        self.panelVisible = panelVisible
    }
}

/// One captured inspect-result payload from the picker.
struct InspectResult: Equatable {
    let tabID: UUID
    let selector: String
    let xpath: String
    let tag: String
    let elementID: String
    let outerHTML: String
    /// Attribute name → value, as captured.
    let attributes: [String: String]
    let rect: CGRect
    let text: String
    let contextHTML: String
    let url: String
    let capturedAt: Date
    /// Free-form annotation. Always empty for results captured by a
    /// single-shot picker arm; populated when the batch-annotate
    /// "queue locally" path stamps each result with the user's
    /// per-item comment before enqueueing.
    var comment: String = ""
}

/// Remembered destination from the previous batch in this app
/// session. Two distinct cases (rather than `Optional<UUID>`) so the
/// "Local queue" pick is durable: `Optional<UUID>` would collapse it
/// back to "no selection".
///
/// Note: the `.local` case is currently unreachable from the panel
/// (the picker only offers pane targets and disables Send until one
/// is picked) but is kept so the eventual "Local queue" picker entry
/// has a place to land.
enum BatchTargetMemory: Equatable {
    case local
    case pane(UUID)
}

/// Sidecar state for a `.web` pane. Lives on `WorkspaceFeature.State`
/// in the `webPanes: [UUID: WebPaneState]` dictionary, keyed by pane
/// id. Kept off the `Pane` struct itself so consumers that don't care
/// about web pane internals don't have to learn the type.
struct WebPaneState: Equatable {
    var tabs: [WebTab]
    var activeTabID: UUID?
    var isPrivate: Bool

    // MARK: - Phase 3 fields (console + inspector)

    /// Rolling buffer of console output captured from this pane's
    /// WKWebViews. Cap is 1000 lines per the plan; oldest is dropped
    /// when full and reported via `droppedSinceLastDrain`.
    var consoleBuffer: RingBuffer<ConsoleLine> = .init(capacity: 1000)
    /// True while the element picker is armed for the next click.
    /// Single-shot: cleared automatically once a click delivers.
    var inspectorArmed: Bool = false
    /// Set on `nex web inspect --send-to <target>` arms. The reducer
    /// reads this when an inspect result arrives, formats the payload,
    /// and pastes it via `paneSendText` to the named pane (resolved
    /// via the usual label/UUID rules at arm time and stashed here).
    var pendingInspectSendTo: UUID?
    /// Set at arm time; checked against the nonce embedded in every
    /// `nexInspect.postMessage` payload. Mismatch → drop. Prevents
    /// page-injected JS from spoofing the channel.
    var pendingInspectNonce: String?
    /// Past inspect-result payloads not yet drained by
    /// `nex web inspect-result`. Capped at 32 entries; oldest dropped.
    var inspectResultQueue: [InspectResult] = []
    /// Active batch-annotate session — see BatchInspectState. nil
    /// when no batch is in progress (the default).
    var batchInspect: BatchInspectState?
    /// Last destination the user picked for a batch on this pane in
    /// the current app run. Drives the panel's initial picker
    /// selection so a second batch defaults to the previous target.
    /// Nil on the very first batch (and on fresh launch — not
    /// serialised) so the user must pick deliberately.
    var lastBatchTarget: BatchTargetMemory?

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
