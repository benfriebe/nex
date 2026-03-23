import Foundation

struct Repo: Identifiable, Equatable {
    let id: UUID
    var path: String
    var name: String
    var remoteURL: String?
    var lastAccessedAt: Date

    init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        remoteURL: String? = nil,
        lastAccessedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.remoteURL = remoteURL
        self.lastAccessedAt = lastAccessedAt
    }
}
