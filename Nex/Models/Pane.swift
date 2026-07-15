import Foundation

enum PaneStatus: String, Codable, Equatable {
    case idle
    case running
    case waitingForInput
}

struct Pane: Identifiable, Equatable {
    /// Default body font size (px) for markdown preview panes. The reset
    /// keybinding (⌘0) snaps `markdownFontSize` back to this value.
    static let defaultMarkdownFontSize: Double = 14

    let id: UUID
    var label: String?
    var type: PaneType
    var title: String?
    var workingDirectory: String
    var gitBranch: String?
    var status: PaneStatus
    var filePath: String?
    var isEditing: Bool
    /// When non-nil on a markdown pane in edit mode, the shell command used
    /// to launch the user's `$EDITOR` inside a ghostty surface bound to this
    /// pane. Nil means use the built-in `MarkdownEditorView`. Transient — not
    /// persisted.
    var externalEditorCommand: String?
    /// In-memory text content for scratchpad panes. Persisted to the database
    /// but never written to a file on disk.
    var scratchpadContent: String?
    var agentSessionID: String?
    /// Rendered body font size (px) for markdown preview panes. Per-pane,
    /// in-memory only; adjusted via Cmd+= / Cmd+-.
    var markdownFontSize: Double
    /// When set on a markdown pane created via `nex open --here`, points
    /// at the parked source pane in the workspace's `parkedPanes` lane.
    /// Closing this pane restores the source instead of taking the
    /// normal close path. In-memory only; not persisted.
    var parkedSourcePaneID: UUID?
    /// Wall-clock time the current agent run started, used by the chrome
    /// to show "claude · mm:ss" elapsed. Set when status transitions into
    /// `.running` (guarded so repeated start pings within a run don't reset
    /// it). Transient — not persisted, so a pane restored as `.running`
    /// has this nil until the resumed agent re-emits a start.
    var agentStartedAt: Date?

    /// Number of Claude Code background units still in flight for this
    /// pane's agent (`run_in_background` shells + background subagents),
    /// as reported by the `background_tasks` array on the most recent
    /// `Stop` / `Notification` hook (issues #215, #220). Non-zero means
    /// the turn ended but work continues, so the pane stays `.running`
    /// instead of falsely reading `.waitingForInput`. Transient — not
    /// persisted; reset to 0 on the next `start` / `error`.
    var backgroundTaskCount: Int

    /// Convenience accessor for rendering logic.
    var isUsingExternalEditor: Bool { externalEditorCommand != nil }
    var createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        label: String? = nil,
        type: PaneType = .shell,
        title: String? = nil,
        workingDirectory: String = NSHomeDirectory(),
        gitBranch: String? = nil,
        filePath: String? = nil,
        isEditing: Bool = false,
        externalEditorCommand: String? = nil,
        scratchpadContent: String? = nil,
        status: PaneStatus = .idle,
        agentSessionID: String? = nil,
        markdownFontSize: Double = Pane.defaultMarkdownFontSize,
        parkedSourcePaneID: UUID? = nil,
        agentStartedAt: Date? = nil,
        backgroundTaskCount: Int = 0,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.title = title
        self.workingDirectory = workingDirectory
        self.gitBranch = gitBranch
        self.filePath = filePath
        self.isEditing = isEditing
        self.externalEditorCommand = externalEditorCommand
        self.scratchpadContent = scratchpadContent
        self.status = status
        self.agentSessionID = agentSessionID
        self.markdownFontSize = markdownFontSize
        self.parkedSourcePaneID = parkedSourcePaneID
        self.agentStartedAt = agentStartedAt
        self.backgroundTaskCount = backgroundTaskCount
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}
