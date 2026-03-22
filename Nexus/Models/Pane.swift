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
    var claudeSessionID: String?
    var createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        label: String? = nil,
        type: PaneType = .shell,
        title: String? = nil,
        workingDirectory: String = NSHomeDirectory(),
        gitBranch: String? = nil,
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
        self.status = status
        self.claudeSessionID = claudeSessionID
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}
