import Foundation

struct RepoAssociation: Identifiable, Equatable {
    let id: UUID
    var repoID: UUID
    var worktreePath: String
    var branchName: String?

    init(
        id: UUID = UUID(),
        repoID: UUID,
        worktreePath: String,
        branchName: String? = nil
    ) {
        self.id = id
        self.repoID = repoID
        self.worktreePath = worktreePath
        self.branchName = branchName
    }
}
