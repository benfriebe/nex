import ComposableArchitecture

// MARK: - Reduce-block partition harness

extension AppReducer {
    /// Which per-domain reduce-block owns a given `Action`.
    ///
    /// `AppReducer.body` is being decomposed from one giant `switch action`
    /// into several per-domain reduce-blocks that all run over the shared
    /// `AppReducer.State`. `domain(of:)` is the single, compiler-checked
    /// source of truth for that partition: its `switch` is **exhaustive with
    /// no `default`**, so the compiler forces every present (and every
    /// future) `Action` case to be consciously assigned to exactly one
    /// domain. That exhaustiveness is the completeness/exclusivity net for
    /// the extraction stages — each extracted block guards on
    /// `Self.domain(of: action) == .<block>` and returns `.none` otherwise,
    /// while `core` keeps everything still mapped to `.core`.
    enum ReducerDomain: Equatable {
        case core
        case searchNotify
        case webPane
        case repoGit
        case socket
        case commandPalette
    }

    static func domain(of action: Action) -> ReducerDomain {
        switch action {
        // MARK: SearchNotify

        // Search (libghostty find), cross-workspace surface notifications,
        // desktop notifications, and the markdown file-open entry points.
        case .ghosttySearchStarted,
             .ghosttySearchEnded,
             .searchTotalUpdated,
             .searchSelectedUpdated,
             .surfaceTitleChanged,
             .surfaceDirectoryChanged,
             .surfaceProcessExited,
             .desktopNotification,
             .openFile,
             .openFileAtPath:
            .searchNotify

        // MARK: WebPane

        // Web-pane top-level actions: URL-bar focus, new-tab / tab
        // cycle / tab close, the batch-inspector lifecycle, private-mode
        // toggle, and the inspect-payload receiver. The `nex web ...`
        // socket verbs stay in `core`'s `.socketMessage` handler (they
        // are `SocketMessage` cases, not `Action` cases) but call the
        // relocated `handleWeb*` helpers via `self`.
        case .openWebPanePath,
             .webPaneFocusURLBar,
             .webPaneOpenNewTab,
             .webPaneTabCycleFocused,
             .webPaneTabCloseActiveFocused,
             .webInspectPayloadReceived,
             .setWebInspectArmedSubmit,
             .webBatchInspectStart,
             .webBatchInspectHide,
             .webBatchInspectShow,
             .webBatchInspectToggle,
             .webBatchInspectSend,
             .webBatchInspectCancel,
             .webPaneSetPrivate,
             .webBatchFocusItem,
             .syncBatchMarkers,
             .pushBatchCommentToPage,
             .webBatchDismissPopover:
            .webPane

        // MARK: RepoGit

        // Repo registry (scan / add / remove / rename), worktree
        // operations, auto-detected repo associations (auto-link /
        // auto-unlink / branch + remote-URL resolution), and the
        // inspector + git-status surface (toggle, refresh, status
        // timer, and the HEAD-watcher lifecycle).
        case .scanForRepos,
             .scanCompleted,
             .addRepo,
             .repoAdded,
             .removeRepo,
             .renameRepo,
             .createWorktree,
             .worktreeCreated,
             .worktreeCreationFailed,
             .removeWorktreeAssociation,
             .autoLinkRepoForPane,
             .autoLinkResolved,
             .autoUnlinkUnusedRepos,
             .repoRemoteURLResolved,
             .repoAssociationBranchResolved,
             .toggleInspector,
             .refreshGitStatus,
             .gitStatusUpdated,
             .startGitStatusTimer,
             .startHeadWatcher,
             .stopHeadWatcher,
             .headChanged:
            .repoGit

        // MARK: Socket

        // The single request/response socket entry point. `.socketMessage`
        // owns the `reply` FD handle, so it must map to exactly one domain
        // (and only `socketReducer` guards on it) — a second match would
        // hand the CLI a doubled JSON line or a premature EOF.
        case .socketMessage:
            .socket

        // MARK: CommandPalette

        // The command-palette overlay: open/close (with focus-handoff
        // scheduling), query filtering, selection movement, and confirm
        // (which switches the active workspace + focuses a pane). The
        // three UI fields (`isCommandPaletteVisible`, `commandPaletteQuery`,
        // `commandPaletteSelectedIndex`) and the computed `commandPaletteItems`
        // stay on `AppReducer.State` — the handlers compute selection over
        // `workspaces` and `commandPaletteConfirm` writes `activeWorkspaceID`
        // directly — so this is a reduce-block over the shared state, not a
        // child reducer with its own slice.
        case .toggleCommandPalette,
             .dismissCommandPalette,
             .commandPaletteQueryChanged,
             .commandPaletteSelectIndex,
             .commandPaletteSelectNext,
             .commandPaletteSelectPrevious,
             .commandPaletteConfirm:
            .commandPalette

        // MARK: Core

        // Everything not yet extracted into its own reduce-block.
        case .appLaunched,
             .createWorkspace,
             .deleteWorkspace,
             .moveWorkspace,
             .moveGroup,
             .moveWorkspacesToGroup,
             .setActiveWorkspace,
             .switchToWorkspaceByIndex,
             .switchToNextWorkspace,
             .switchToPreviousWorkspace,
             .toggleSidebar,
             .showNewWorkspaceSheet,
             .dismissNewWorkspaceSheet,
             .beginRenameActiveWorkspace,
             .setRenamingWorkspaceID,
             .setRenamingPaneID,
             .setPaneStatus,
             .toggleWorkspaceSelection,
             .rangeSelectWorkspace,
             .clearWorkspaceSelection,
             .selectAllWorkspaces,
             .setBulkColor,
             .requestBulkDelete,
             .confirmBulkDelete,
             .cancelBulkDelete,
             .persistState,
             .stateLoaded,
             .toggleGroupCollapse,
             .createGroup,
             .renameGroup,
             .setGroupColor,
             .setGroupIcon,
             .requestGroupCustomEmoji,
             .cancelGroupCustomEmoji,
             .confirmGroupCustomEmoji,
             .setWorkspaceIcon,
             .requestWorkspaceCustomEmoji,
             .cancelWorkspaceCustomEmoji,
             .confirmWorkspaceCustomEmoji,
             .deleteGroup,
             .moveWorkspaceToGroup,
             .beginRenameGroup,
             .setRenamingGroupID,
             .requestGroupDelete,
             .cancelGroupDelete,
             .requestBulkCreateGroup,
             .cancelBulkCreateGroup,
             .confirmBulkCreateGroup,
             .seedTestGroup,
             .workspaces,
             .settings,
             .graft,
             .openDiffPath,
             .presets,
             .migrateLabelsToPresets,
             .updateExternalIndicators,
             .configHotkey,
             .configLoaded,
             .restartSocketServer:
            .core
        }
    }
}
