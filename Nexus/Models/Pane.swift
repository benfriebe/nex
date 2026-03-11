import Foundation

enum PaneStatus: String, Codable, Sendable, Equatable {
    case idle
    case running
    case waitingForInput
}

struct Pane: Identifiable, Equatable, Sendable {
    let id: UUID
    var label: String?
    var type: PaneType
    var title: String?
    var workingDirectory: String
    var status: PaneStatus
    var createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        label: String? = nil,
        type: PaneType = .shell,
        title: String? = nil,
        workingDirectory: String = NSHomeDirectory(),
        status: PaneStatus = .idle,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.title = title
        self.workingDirectory = workingDirectory
        self.status = status
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}
