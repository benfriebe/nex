import Foundation

enum PaneStatus: String, Codable, Equatable {
    case idle
    case running
    case waitingForInput
}

struct Pane: Identifiable, Equatable {
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
    var claudeSessionID: String?

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
        claudeSessionID: String? = nil,
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
        self.claudeSessionID = claudeSessionID
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}
