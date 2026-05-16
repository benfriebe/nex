import ComposableArchitecture
import SwiftUI

/// Graft toggle rendered next to each `RepoAssociation` row in the
/// inspector. Reflects the per-association session state via an icon
/// swap plus a coloured status dot.
struct GraftInspectorButton: View {
    let association: RepoAssociation
    @Bindable var store: StoreOf<AppReducer>

    var body: some View {
        WithPerceptionTracking {
            let session = store.graft.sessions[id: association.id]
            let icon = session == nil
                ? "arrow.triangle.2.circlepath"
                : "arrow.triangle.2.circlepath.circle.fill"
            InspectorIconButton(icon: icon, tooltip: tooltipText(session: session)) {
                store.send(.graft(.toggleGraft(association)))
            }
            .overlay(alignment: .topTrailing) {
                if let session {
                    statusDot(for: session.status)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    @ViewBuilder
    private func statusDot(for status: GraftSessionStatus) -> some View {
        switch status {
        case .starting, .syncing:
            Circle().fill(.yellow).frame(width: 5, height: 5)
        case .watching:
            Circle().fill(.green).frame(width: 5, height: 5)
        case .error:
            Circle().fill(.red).frame(width: 5, height: 5)
        }
    }

    private func tooltipText(session: GraftSession?) -> String {
        guard let session else {
            let branch = association.branchName ?? "this worktree"
            return "Mirror \(branch)'s tracked files into the parent repo's " +
                "working tree. Parent's branch stays put; untracked files " +
                "(node_modules, build output) are untouched."
        }
        switch session.status {
        case .starting:
            return "Starting graft..."
        case .syncing:
            return "Syncing \(session.branch)..."
        case .watching:
            let lastSync = session.lastSync
                .map { "Last sync \(Self.relativeFormatter.localizedString(for: $0, relativeTo: Date()))" }
                ?? "Watching"
            return "Mirroring \(session.branch) into the parent. \(lastSync). " +
                "Stop to restore the parent's working tree."
        case .error(let message):
            return "Graft error: \(message)"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Banner shown above the repo association list when an unclean shutdown
/// left a graft breadcrumb behind. The user picks "Restore" (run the
/// stop sequence using the breadcrumb's recorded pre-graft branch +
/// SHA, then pop any stashed parent edits) or "Dismiss" (delete the
/// breadcrumb only).
struct GraftOrphanBanner: View {
    let orphan: GraftOrphan
    @Bindable var store: StoreOf<AppReducer>

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Graft was interrupted")
                    .font(.system(size: 12, weight: .semibold))
                Text(repoDisplayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Button("Restore") {
                        store.send(.graft(.recoverOrphan(orphan)))
                    }
                    .controlSize(.small)
                    Button("Dismiss") {
                        store.send(.graft(.dismissOrphan(orphan)))
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
        )
    }

    private var repoDisplayName: String {
        (orphan.parentRepoRoot as NSString).lastPathComponent
    }
}
