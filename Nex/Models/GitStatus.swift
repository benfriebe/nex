import Foundation

enum RepoGitStatus: Equatable {
    case unknown
    case clean
    /// Working tree has changes. `changedFiles` is the porcelain count
    /// (includes untracked); `additions`/`deletions` come from
    /// `git diff --shortstat` and so only count tracked-file edits.
    /// They will be 0 for untracked-only or pure-mode-change states.
    case dirty(changedFiles: Int, additions: Int = 0, deletions: Int = 0)
}
