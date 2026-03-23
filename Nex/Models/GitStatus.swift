import Foundation

enum RepoGitStatus: Equatable {
    case unknown
    case clean
    case dirty(changedFiles: Int)
}
