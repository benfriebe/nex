import Foundation

struct RepoAssociation: Identifiable, Equatable {
    let id: UUID
    var repoID: UUID
    var worktreePath: String
    var branchName: String?
    var isAutoDetected: Bool

    init(
        id: UUID = UUID(),
        repoID: UUID,
        worktreePath: String,
        branchName: String? = nil,
        isAutoDetected: Bool = false
    ) {
        self.id = id
        self.repoID = repoID
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.isAutoDetected = isAutoDetected
    }
}
