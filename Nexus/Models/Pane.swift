import Foundation

struct Pane: Identifiable, Equatable, Sendable {
    let id: UUID
    var label: String?
    var type: PaneType
    var title: String?
    var workingDirectory: String
    var createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        label: String? = nil,
        type: PaneType = .shell,
        title: String? = nil,
        workingDirectory: String = NSHomeDirectory(),
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.title = title
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}
