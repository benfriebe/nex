import AppKit
import ComposableArchitecture
import Foundation
import SwiftUI
import WebKit

// MARK: - WebPane reduce-block

extension AppReducer {
    /// Extracted per-domain reduce-block owning the 18 top-level
    /// web-pane `Action` cases (URL-bar focus, new-tab / tab cycle /
    /// tab close, the batch-inspector lifecycle, private-mode toggle,
    /// and the inspect-payload receiver) plus every `nex web ...`
    /// socket handler they share with core's `.socketMessage` dispatch.
    ///
    /// The guard short-circuits every non-WebPane action via
    /// `Self.domain(of:)` (the exhaustive partition), so this block
    /// only ever runs the cases below. Case bodies and helper methods
    /// are moved here verbatim from the original `AppReducer.body`
    /// switch and the struct body; dependency access (`webPaneStore`,
    /// `uuid`) goes through `self` exactly as before. The socket web
    /// verbs stay in core's `.socketMessage` handler (Stage 6) but call
    /// these relocated `handleWeb*` methods via `self`. The
    /// `webPaneURLFocusTokens` / `webInspectArmedSubmit` state fields
    /// also stay in core (the latter has an external writer in
    /// `.closePane`); this block reads/writes them via `state`.
    var webPaneReducer: some ReducerOf<Self> {
        Reduce { state, action in
            guard Self.domain(of: action) == .webPane else { return .none }
            switch action {
            case .openWebPanePath(let url, let fromPaneID, let direction):
                guard let activeID = state.activeWorkspaceID else { return .none }
                let newPaneID = uuid()
                // Blank URL → focus the fresh pane's URL bar so the user
                // can type immediately (mirrors `webPaneOpenNewTab` for
                // blank tabs). A preset URL is loading content, so leave
                // focus to the WKWebView. The webview's
                // `claimFirstResponder` yields whenever the URL field is
                // already first responder, so this token bump wins the
                // focus race regardless of async ordering.
                if url.isEmpty {
                    state.webPaneURLFocusTokens[newPaneID, default: 0] &+= 1
                }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .openWebPane(
                        paneID: newPaneID,
                        tabID: uuid(),
                        url: url,
                        reusePaneID: nil,
                        isPrivate: false,
                        // fromPaneID = the pane whose header button /
                        // context menu was used; nil (menu bar / ⌘⇧O)
                        // splits the focused pane.
                        sourcePaneID: fromPaneID,
                        direction: direction
                    )
                )))

            case .webPaneFocusURLBar(let paneID):
                state.webPaneURLFocusTokens[paneID, default: 0] &+= 1
                return .none

            case .webPaneOpenNewTab(let paneID, let url):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let newTabID = uuid()
                // Blank new tab → auto-focus the URL bar so the user can
                // type a URL immediately. A tab opened with a preset URL
                // is loading content, so leave focus to the WKWebView.
                if url?.isEmpty ?? true {
                    state.webPaneURLFocusTokens[paneID, default: 0] &+= 1
                }
                return .send(.workspaces(.element(
                    id: workspace.id,
                    action: .webPaneTabOpen(
                        paneID: paneID,
                        tabID: newTabID,
                        url: url ?? "",
                        makeActive: true
                    )
                )))

            case .webPaneTabCycleFocused(let offset):
                guard let activeID = state.activeWorkspaceID,
                      let workspace = state.workspaces[id: activeID],
                      let focusedID = workspace.focusedPaneID,
                      workspace.panes[id: focusedID]?.type == .web else { return .none }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .webPaneTabCycle(paneID: focusedID, offset: offset)
                )))

            case .webPaneTabCloseActiveFocused:
                guard let activeID = state.activeWorkspaceID,
                      let workspace = state.workspaces[id: activeID],
                      let focusedID = workspace.focusedPaneID,
                      workspace.panes[id: focusedID]?.type == .web,
                      let webState = workspace.webPanes[focusedID],
                      let activeTabID = webState.activeTab?.id else { return .none }
                return .send(.workspaces(.element(
                    id: activeID,
                    action: .webPaneTabClose(paneID: focusedID, tabID: activeTabID)
                )))

            case .setWebInspectArmedSubmit(let paneID, let submit):
                if submit {
                    state.webInspectArmedSubmit[paneID] = true
                } else {
                    state.webInspectArmedSubmit.removeValue(forKey: paneID)
                }
                return .none

            case .webBatchInspectStart(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let webState = workspace.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                let tabID = tab.id
                let isPrivate = webState.isPrivate
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchInspectBegin(paneID: paneID)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .run { send in
                        let nonce: String? = await MainActor.run {
                            store.coordinator(for: paneID, isPrivate: isPrivate).armInspector(tabID: tabID, sticky: true)
                        }
                        guard let nonce else { return }
                        await send(.workspaces(.element(
                            id: workspaceID,
                            action: .webInspectArmedFor(
                                paneID: paneID, sendTo: nil, nonce: nonce
                            )
                        )))
                    }
                )

            case .webBatchInspectToggle(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let batch = workspace.webPanes[paneID]?.batchInspect
                if batch == nil {
                    return .send(.webBatchInspectStart(paneID: paneID))
                } else if batch?.panelVisible == true {
                    return .send(.webBatchInspectHide(paneID: paneID))
                } else {
                    return .send(.webBatchInspectShow(paneID: paneID))
                }

            case .webBatchInspectHide(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchPanelVisible(paneID: paneID, visible: false)
                    ))),
                    // Disarm the page picker and clear the on-page
                    // markers; the SwiftUI panel + items in state
                    // remain so the next show restores everything.
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webInspectDisarm(paneID: paneID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?.disarmInspector()
                        }
                    }
                )

            case .webBatchInspectShow(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let webState = workspace.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                let tabID = tab.id
                let isPrivate = webState.isPrivate
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchPanelVisible(paneID: paneID, visible: true)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .run { send in
                        let nonce: String? = await MainActor.run {
                            store.coordinator(for: paneID, isPrivate: isPrivate).armInspector(tabID: tabID, sticky: true)
                        }
                        guard let nonce else { return }
                        await send(.workspaces(.element(
                            id: workspaceID,
                            action: .webInspectArmedFor(
                                paneID: paneID, sendTo: nil, nonce: nonce
                            )
                        )))
                    }
                )

            case .webPaneSetPrivate(let paneID, let enabledOpt):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let current = workspace.webPanes[paneID]?.isPrivate ?? false
                let enabled = enabledOpt ?? !current
                guard current != enabled else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webPaneSetIsPrivate(paneID: paneID, enabled: enabled)
                    ))),
                    // Destroy the coordinator so the host's next pass
                    // builds a fresh one against the new data store.
                    // The host's mismatch check would catch this too,
                    // but doing it here keeps the teardown ordered
                    // with the state flip.
                    .run { _ in
                        await MainActor.run {
                            store.destroyCoordinator(paneID: paneID)
                        }
                    }
                )

            case .webBatchInspectCancel(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                state.webInspectArmedSubmit.removeValue(forKey: paneID)
                return .merge(
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchInspectCleared(paneID: paneID)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webInspectDisarm(paneID: paneID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?.disarmInspector()
                        }
                    }
                )

            case .webBatchInspectSend(let paneID, let sendTo):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let batch = workspace.webPanes[paneID]?.batchInspect else { return .none }
                let store = webPaneStore
                let workspaceID = workspace.id
                let submit = state.webInspectArmedSubmit[paneID] ?? false
                state.webInspectArmedSubmit.removeValue(forKey: paneID)
                // Seed `lastBatchTarget` so the next batch on this
                // pane defaults to the same destination. In-memory
                // only — fresh launch always starts unselected.
                if !batch.items.isEmpty {
                    let memory: BatchTargetMemory = sendTo.map { .pane($0) } ?? .local
                    state.workspaces[id: workspaceID]?.webPanes[paneID]?.lastBatchTarget = memory
                }

                var effects: [Effect<Action>] = [
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webBatchInspectCleared(paneID: paneID)
                    ))),
                    .send(.syncBatchMarkers(paneID: paneID)),
                    .send(.workspaces(.element(
                        id: workspaceID,
                        action: .webInspectDisarm(paneID: paneID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?.disarmInspector()
                        }
                    }
                ]
                // Empty batch — nothing to send, just tear down.
                if batch.items.isEmpty {
                    return .merge(effects)
                }
                if let sendTo {
                    let formatted = InspectPayloadSanitiser.formatBatchForPaste(batch.items)
                    effects.append(paneSendText(paneID: sendTo, text: formatted, bare: !submit))
                } else {
                    // No destination — queue each item locally for
                    // `nex web inspect-result` to drain. Stamp the
                    // per-item comment onto the result before
                    // enqueueing so `inspectResultJSON` surfaces it
                    // (the single-shot picker path always leaves
                    // `comment` empty).
                    for item in batch.items {
                        var annotated = item.result
                        annotated.comment = item.comment
                        effects.append(.send(.workspaces(.element(
                            id: workspaceID,
                            action: .webInspectResultReceived(
                                paneID: paneID, result: annotated
                            )
                        ))))
                    }
                }
                return .merge(effects)

            case .webBatchFocusItem(let paneID, let itemID, let origin):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let webState = workspace.webPanes[paneID],
                      let tab = webState.activeTab else { return .none }
                let store = webPaneStore
                let tabID = tab.id
                // Push the focus ring + badge pulse onto the page
                // regardless of origin — the persistent ring is the
                // primary visual feedback, and re-pulsing the badge
                // is cheap. `.panel` also scrolls the page; `.page`
                // skips the scroll since the element is already under
                // the cursor.
                let scrollIntoView = origin == .panel
                return .merge(
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webBatchItemFocused(paneID: paneID, itemID: itemID)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            store.coordinatorIfExists(for: paneID)?
                                .highlightBatchMarker(
                                    tabID: tabID,
                                    itemID: itemID,
                                    scrollIntoView: scrollIntoView
                                )
                        }
                    }
                )

            case .syncBatchMarkers(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let webState = workspace.webPanes[paneID]
                let tabID = webState?.activeTab?.id
                // Hidden panel = no on-page markers either. Items
                // still live in state for when the user re-opens.
                let panelVisible = webState?.batchInspect?.panelVisible ?? false
                let items: [BatchMarkerInput] = panelVisible
                    ? (webState?.batchInspect?.items ?? [])
                    .enumerated()
                    .map { idx, item in
                        BatchMarkerInput(
                            id: item.id,
                            selector: item.result.selector,
                            label: String(idx + 1),
                            comment: item.comment
                        )
                    }
                    : []
                let store = webPaneStore
                return .run { _ in
                    await MainActor.run {
                        guard let coordinator = store.coordinatorIfExists(for: paneID),
                              let tabID else { return }
                        if items.isEmpty {
                            coordinator.clearBatchMarkers(tabID: tabID)
                        } else {
                            coordinator.syncBatchMarkers(tabID: tabID, items: items)
                        }
                    }
                }

            case .pushBatchCommentToPage(let paneID, let itemID, let comment):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                guard let tabID = workspace.webPanes[paneID]?.activeTab?.id else { return .none }
                let store = webPaneStore
                return .run { _ in
                    await MainActor.run {
                        store.coordinatorIfExists(for: paneID)?
                            .pushBatchComment(tabID: tabID, itemID: itemID, comment: comment)
                    }
                }

            case .webBatchDismissPopover(let paneID):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let tabID = workspace.webPanes[paneID]?.activeTab?.id
                let store = webPaneStore
                return .merge(
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webBatchItemFocused(paneID: paneID, itemID: nil)
                    ))),
                    .run { _ in
                        await MainActor.run {
                            guard let tabID else { return }
                            store.coordinatorIfExists(for: paneID)?.unfocusBatch(tabID: tabID)
                        }
                    }
                )

            case .webInspectPayloadReceived(let paneID, let result):
                guard let workspace = state.workspaceContainingPane(paneID) else { return .none }
                let webState = workspace.webPanes[paneID]

                // Batch mode: append to the in-progress batch and
                // leave the picker armed (sticky) for the next pick.
                // No paste happens until the user hits Send. Also
                // refresh the on-page numbered markers so the new
                // pick gets a badge, then focus the new item so the
                // page draws its ring and the panel auto-focuses the
                // comment field. A hidden batch (panelVisible == false)
                // is paused — `nex web inspect --send-to` can arm a
                // single-shot inspect on top, so route the result down
                // the single-shot path instead of hijacking it.
                if webState?.batchInspect?.panelVisible == true {
                    let item = BatchInspectItem(result: result)
                    return .merge(
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .webBatchItemAdded(paneID: paneID, item: item)
                        ))),
                        .send(.syncBatchMarkers(paneID: paneID)),
                        // Origin .page — the click was on the page,
                        // so we don't re-scroll the element into view
                        // (it's already where the user clicked).
                        .send(.webBatchFocusItem(
                            paneID: paneID, itemID: item.id, origin: .page
                        ))
                    )
                }

                // Single-shot mode: queue on source pane (so
                // `nex web inspect-result` can drain it later), and
                // if this arm was set up with `--send-to`, paste the
                // formatted block into the destination via the
                // factored paneSendText helper. Submit-after-paste
                // is recorded out-of-band in `webInspectArmedSubmit`
                // (Phase 3 ships paste-only as the safe default).
                let sendTo = webState?.pendingInspectSendTo
                let submit = state.webInspectArmedSubmit[paneID] ?? false
                var effects: [Effect<Action>] = [
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webInspectResultReceived(paneID: paneID, result: result)
                    ))),
                    .send(.workspaces(.element(
                        id: workspace.id,
                        action: .webInspectDisarm(paneID: paneID)
                    )))
                ]
                state.webInspectArmedSubmit.removeValue(forKey: paneID)
                if let sendTo {
                    let formatted = InspectPayloadSanitiser.formatForPaste(result)
                    effects.append(paneSendText(paneID: sendTo, text: formatted, bare: !submit))
                }
                return .merge(effects)

            default:
                return .none
            }
        }
    }

    // MARK: - Web pane handlers (Phase 1)

    enum WebNavAction { case back, forward, reload, reloadHard }

    /// Open a new `.web` pane in the active workspace. Mirrors the
    /// shape of `handlePaneList` — single JSON reply, then close.
    /// Allocates the new pane (and active-tab) UUIDs up front so the
    /// reply payload can echo a concrete `pane_id` *before* the
    /// workspace effect runs and the CLI can print/script against it.
    func handleWebOpen(
        state: State,
        paneID: UUID?,
        url: String,
        isPrivate: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        // Open in the caller's workspace when NEX_PANE_ID resolves
        // (mirrors the markdown `.openFile` route), else the active
        // workspace. Without this the web pane would always land in
        // the active workspace even when `nex web open` / `nex open
        // <web-file>` is invoked from a pane in a background one.
        let targetID: UUID? = if let paneID,
                                 let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
            workspace.id
        } else {
            state.activeWorkspaceID
        }
        guard let activeID = targetID else {
            reply?.send(["ok": false, "error": "no active workspace"])
            reply?.close()
            return .none
        }
        let normalized = WebPaneCoordinator.normalizeURLInput(url)
        let newPaneID = uuid()
        let newTabID = uuid()
        reply?.send([
            "ok": true,
            "pane_id": newPaneID.uuidString,
            "tab_id": newTabID.uuidString,
            "url": normalized,
            "private": isPrivate,
            "workspace_id": activeID.uuidString
        ])
        reply?.close()
        return .send(.workspaces(.element(
            id: activeID,
            action: .openWebPane(
                paneID: newPaneID,
                tabID: newTabID,
                url: url,
                reusePaneID: nil,
                isPrivate: isPrivate
            )
        )))
    }

    /// Wire-level addressing for any `nex web ...` command. All three
    /// fields come from the same CLI payload (`pane_id`, `target`,
    /// `workspace`); bundling them keeps the per-handler signatures
    /// from leaking that detail.
    struct WebPaneScope: Equatable {
        let paneID: UUID?
        let target: String?
        let workspaceFilter: String?
    }

    /// Resolve a pane-target reference to a `.web` pane. Replies with
    /// the structured error on a miss and returns nil so the caller
    /// can short-circuit cleanly.
    private func resolveWebPane(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> (paneID: UUID, workspace: WorkspaceFeature.State, webState: WebPaneState)? {
        switch resolvePaneTarget(
            state: state, paneID: scope.paneID,
            target: scope.target, workspaceFilter: scope.workspaceFilter
        ) {
        case .found(let resolvedID, let ws):
            guard let pane = ws.panes[id: resolvedID] else {
                reply?.error("pane not found: \(resolvedID.uuidString)")
                return nil
            }
            guard pane.type == .web else {
                reply?.error("pane is not a web pane (type: \(pane.type.rawValue))")
                return nil
            }
            guard let webState = ws.webPanes[resolvedID] else {
                reply?.error("web pane state missing for \(resolvedID.uuidString)")
                return nil
            }
            return (resolvedID, ws, webState)
        case .error(let message):
            reply?.error(message)
            return nil
        }
    }

    func handleWebNavigate(
        state: State,
        scope: WebPaneScope,
        url: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        guard resolved.webState.activeTab != nil else {
            reply?.error("web pane has no active tab")
            return .none
        }
        let normalized = WebPaneCoordinator.normalizeURLInput(url)
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "url": normalized
        ])
        return .send(.workspaces(.element(
            id: resolved.workspace.id,
            action: .webPaneNavigate(paneID: resolved.paneID, url: url)
        )))
    }

    func handleWebURL(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }

        // Destructure into Sendable locals — Swift 6 strict
        // concurrency rejects capturing the resolved tuple
        // (which carries WorkspaceFeature.State) in a @Sendable
        // closure.
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let tabID = resolved.webState.activeTab?.id
        let fallbackURL = resolved.webState.activeTab?.url ?? ""
        let fallbackTitle = resolved.webState.activeTab?.title ?? ""

        return .run { _ in
            let snapshot: (url: String, title: String)? = await MainActor.run {
                guard let tabID else { return nil }
                return store.coordinatorIfExists(for: resolvedPaneID)?
                    .currentURLAndTitle(tabID: tabID)
            }
            let url = snapshot?.url.isEmpty == false ? snapshot!.url : fallbackURL
            let title = snapshot?.title.isEmpty == false ? snapshot!.title : fallbackTitle
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "url": url,
                "title": title
            ])
        }
    }

    func handleWebNav(
        state: State,
        scope: WebPaneScope,
        action: WebNavAction,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }

        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString
        ])

        let wsID = resolved.workspace.id
        let paneID = resolved.paneID
        switch action {
        case .back:
            return .send(.workspaces(.element(id: wsID, action: .webPaneBack(paneID: paneID))))
        case .forward:
            return .send(.workspaces(.element(id: wsID, action: .webPaneForward(paneID: paneID))))
        case .reload:
            return .send(.workspaces(.element(id: wsID, action: .webPaneReload(paneID: paneID, hard: false))))
        case .reloadHard:
            return .send(.workspaces(.element(id: wsID, action: .webPaneReload(paneID: paneID, hard: true))))
        }
    }

    func handleWebCapture(
        state: State,
        scope: WebPaneScope,
        mode: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        guard let tab = resolved.webState.activeTab else {
            reply?.error("web pane has no active tab")
            return .none
        }

        guard let captureMode = WebCaptureMode(rawValue: mode) else {
            reply?.error("unknown capture mode '\(mode)' (allowed: meta, text, screenshot)")
            return .none
        }

        // Destructure into Sendable locals for the .run closure
        // (Swift 6 strict concurrency disallows capturing the
        // resolved tuple, which carries WorkspaceFeature.State).
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let tabID = tab.id
        let tabURL = tab.url
        let tabTitle = tab.title
        let isPrivate = resolved.webState.isPrivate

        return .run { _ in
            let snapshot: (url: String, title: String) = await MainActor.run {
                store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).currentURLAndTitle(tabID: tabID)
                    ?? (tabURL, tabTitle)
            }
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "url": snapshot.url,
                "title": snapshot.title,
                "mode": captureMode.rawValue
            ]
            switch captureMode {
            case .meta:
                break
            case .text:
                let text = await store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).captureText(tabID: tabID)
                payload["text"] = text
                payload["byte_count"] = text.utf8.count
            case .screenshot:
                let pngData = await store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).captureScreenshot(tabID: tabID)
                if let pngData {
                    let inlineThreshold = 1_000_000 // 1 MB
                    if pngData.count <= inlineThreshold {
                        payload["png_base64"] = pngData.base64EncodedString()
                        payload["byte_count"] = pngData.count
                    } else {
                        // Per-app temporary directory — OS prunes it
                        // automatically (vs. `/tmp` where files lingered
                        // until reboot).
                        let ts = Int(Date().timeIntervalSince1970)
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("nex-web-capture-\(resolvedPaneID.uuidString)-\(ts).png")
                        if (try? pngData.write(to: url)) != nil {
                            payload["path"] = url.path
                            payload["byte_count"] = pngData.count
                        } else {
                            payload["ok"] = false
                            payload["error"] = "failed to write screenshot to \(url.path)"
                        }
                    }
                } else {
                    payload["ok"] = false
                    payload["error"] = "screenshot capture failed"
                }
            }
            reply?.sendAndClose(payload)
        }
    }

    // MARK: - Web pane actuator handlers

    /// Dispatch a `__nexAct.<method>(<args>)` call against the resolved
    /// web pane's active tab and translate the parsed envelope into a
    /// `ReplyHandle` reply. Shared body for every actuator-backed
    /// verb (click / type / q* / wait / select / scroll / hover / key /
    /// exec).
    private func runWebPaneActuator(
        state: State,
        scope: WebPaneScope,
        errorLabel: String,
        reply: SocketServer.ReplyHandle?,
        body: @escaping @Sendable (WebPaneCoordinator, UUID) async -> WebPaneActuator.Result
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        guard let tab = resolved.webState.activeTab else {
            reply?.error("web pane has no active tab")
            return .none
        }

        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let tabID = tab.id
        let isPrivate = resolved.webState.isPrivate

        return .run { _ in
            let coordinator = await MainActor.run {
                store.coordinator(for: resolvedPaneID, isPrivate: isPrivate)
            }
            let outcome = await body(coordinator, tabID)
            switch outcome {
            case .unknownTab:
                reply?.error("web pane has no live tab \(tabID.uuidString)")
            case .evaluationFailed(let message):
                reply?.error("\(errorLabel) evaluation failed: \(message)")
            case .success(let envelope):
                var payload = (try? JSONSerialization.jsonObject(
                    with: envelope.raw
                ) as? [String: Any]) ?? [:]
                payload["pane_id"] = resolvedPaneID.uuidString
                payload["workspace_id"] = workspaceID.uuidString
                payload["tab_id"] = tabID.uuidString
                reply?.sendAndClose(payload)
            }
        }
    }

    private func handleWebActuatorCall(
        state: State,
        scope: WebPaneScope,
        method: String,
        args: [JSValue],
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        runWebPaneActuator(
            state: state, scope: scope, errorLabel: "actuator", reply: reply
        ) { coordinator, tabID in
            await WebPaneActuator.invoke(
                coordinator: coordinator, tabID: tabID, method: method, args: args
            )
        }
    }

    func handleWebClick(
        state: State,
        scope: WebPaneScope,
        selector: String,
        double: Bool,
        right: Bool,
        atX: Double?,
        atY: Double?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if double { opts.append(JSPair(key: "double", value: .bool(true))) }
        if right { opts.append(JSPair(key: "right", value: .bool(true))) }
        if let x = atX, let y = atY {
            opts.append(JSPair(key: "at", value: .object([
                JSPair(key: "x", value: .double(x)),
                JSPair(key: "y", value: .double(y))
            ])))
        }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "click",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebType(
        state: State,
        scope: WebPaneScope,
        selector: String,
        text: String,
        submit: Bool,
        replace: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if submit { opts.append(JSPair(key: "submit", value: .bool(true))) }
        // `replace` defaults true in the JS side; only ship the flag
        // when the caller overrode it so the wire payload stays small.
        if !replace { opts.append(JSPair(key: "replace", value: .bool(false))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "type",
            args: [.string(selector), .string(text), .object(opts)],
            reply: reply
        )
    }

    func handleWebQText(
        state: State,
        scope: WebPaneScope,
        selector: String,
        maxBytes: Int?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let maxBytes { opts.append(JSPair(key: "maxBytes", value: .int(maxBytes))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "text",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebQAttr(
        state: State,
        scope: WebPaneScope,
        selector: String,
        attribute: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "attr",
            args: [.string(selector), .string(attribute)],
            reply: reply
        )
    }

    func handleWebQCount(
        state: State,
        scope: WebPaneScope,
        selector: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "count",
            args: [.string(selector)],
            reply: reply
        )
    }

    func handleWebQExists(
        state: State,
        scope: WebPaneScope,
        selector: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "exists",
            args: [.string(selector)],
            reply: reply
        )
    }

    func handleWebQDom(
        state: State,
        scope: WebPaneScope,
        selector: String,
        maxBytes: Int?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let maxBytes { opts.append(JSPair(key: "maxBytes", value: .int(maxBytes))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "dom",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebWait(
        state: State,
        scope: WebPaneScope,
        selector: String?,
        urlMatch: String?,
        forCondition: String?,
        timeoutMs: Int,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let selector { opts.append(JSPair(key: "selector", value: .string(selector))) }
        if let urlMatch { opts.append(JSPair(key: "urlMatch", value: .string(urlMatch))) }
        if let forCondition { opts.append(JSPair(key: "for", value: .string(forCondition))) }
        opts.append(JSPair(key: "timeout", value: .int(timeoutMs)))
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "wait",
            args: [.object(opts)],
            reply: reply
        )
    }

    func handleWebSelect(
        state: State,
        scope: WebPaneScope,
        selector: String,
        valueOrLabel: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "select",
            args: [.string(selector), .string(valueOrLabel)],
            reply: reply
        )
    }

    func handleWebScroll(
        state: State,
        scope: WebPaneScope,
        selector: String,
        block: String,
        behavior: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let opts: [JSPair] = [
            JSPair(key: "block", value: .string(block)),
            JSPair(key: "behavior", value: .string(behavior))
        ]
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "scroll",
            args: [.string(selector), .object(opts)],
            reply: reply
        )
    }

    func handleWebHover(
        state: State,
        scope: WebPaneScope,
        selector: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        handleWebActuatorCall(
            state: state, scope: scope,
            method: "hover",
            args: [.string(selector)],
            reply: reply
        )
    }

    func handleWebKey(
        state: State,
        scope: WebPaneScope,
        keyName: String,
        selector: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        var opts: [JSPair] = []
        if let selector { opts.append(JSPair(key: "selector", value: .string(selector))) }
        return handleWebActuatorCall(
            state: state, scope: scope,
            method: "key",
            args: [.string(keyName), .object(opts)],
            reply: reply
        )
    }

    func handleWebExec(
        state: State,
        scope: WebPaneScope,
        script: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let wrappedSource = WebPaneExecWrapper.wrap(script)
        return runWebPaneActuator(
            state: state, scope: scope, errorLabel: "exec", reply: reply
        ) { coordinator, tabID in
            await WebPaneActuator.evaluate(
                coordinator: coordinator, tabID: tabID, source: wrappedSource
            )
        }
    }

    // MARK: - Web pane tab handlers

    enum TabRefResolution {
        case found(UUID)
        case error(String)
    }

    /// Resolve a `tab` ref (UUID string or numeric index) against a
    /// web pane's tab list. Returns the concrete tab UUID or an
    /// error message safe to surface in a reply.
    private func resolveTabRef(
        _ ref: String,
        in webState: WebPaneState
    ) -> TabRefResolution {
        if let uuid = UUID(uuidString: ref) {
            guard webState.contains(tabID: uuid) else {
                return .error("no tab with UUID '\(ref)' in this web pane")
            }
            return .found(uuid)
        }
        if let idx = Int(ref) {
            guard webState.tabs.indices.contains(idx) else {
                return .error("tab index \(idx) out of range (0..<\(webState.tabs.count))")
            }
            return .found(webState.tabs[idx].id)
        }
        return .error("tab ref must be a UUID or numeric index, got '\(ref)'")
    }

    private func tabJSON(_ tab: WebTab, isActive: Bool, index: Int) -> [String: Any] {
        [
            "id": tab.id.uuidString,
            "url": tab.url,
            "title": tab.title,
            "index": index,
            "active": isActive
        ]
    }

    func handleWebTabs(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let activeID = resolved.webState.activeTab?.id
        let entries = resolved.webState.tabs.enumerated().map { idx, tab in
            tabJSON(tab, isActive: tab.id == activeID, index: idx)
        }
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "tabs": entries
        ])
        return .none
    }

    func handleWebTabNew(
        state: State,
        scope: WebPaneScope,
        url: String,
        makeActive: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let newTabID = uuid()
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "tab_id": newTabID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "url": WebPaneCoordinator.normalizeURLInput(url),
            "active": makeActive
        ])
        return .send(.workspaces(.element(
            id: resolved.workspace.id,
            action: .webPaneTabOpen(
                paneID: resolved.paneID,
                tabID: newTabID,
                url: url,
                makeActive: makeActive
            )
        )))
    }

    func handleWebTabClose(
        state: State,
        scope: WebPaneScope,
        tabRef: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        switch resolveTabRef(tabRef, in: resolved.webState) {
        case .error(let message):
            reply?.error(message)
            return .none
        case .found(let tabID):
            if resolved.webState.tabs.count == 1 {
                reply?.error("cannot close the only tab in a web pane, use `nex pane close` to close the pane itself")
                return .none
            }
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolved.paneID.uuidString,
                "workspace_id": resolved.workspace.id.uuidString,
                "tab_id": tabID.uuidString
            ])
            return .send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webPaneTabClose(paneID: resolved.paneID, tabID: tabID)
            )))
        }
    }

    func handleWebTabSelect(
        state: State,
        scope: WebPaneScope,
        tabRef: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        switch resolveTabRef(tabRef, in: resolved.webState) {
        case .error(let message):
            reply?.error(message)
            return .none
        case .found(let tabID):
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolved.paneID.uuidString,
                "workspace_id": resolved.workspace.id.uuidString,
                "tab_id": tabID.uuidString
            ])
            return .send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webPaneTabSelect(paneID: resolved.paneID, tabID: tabID)
            )))
        }
    }

    // MARK: - Web pane console + inspector handlers (Phase 3)

    private func consoleLineJSON(_ entry: RingBuffer<ConsoleLine>.Entry) -> [String: Any] {
        let line = entry.value
        var dict: [String: Any] = [
            "seq": entry.seq,
            "tab_id": line.tabID.uuidString,
            "level": line.level.rawValue,
            "message": line.message,
            "url": line.url,
            "captured_at": InspectPayloadSanitiser.isoFormatter.string(from: line.capturedAt)
        ]
        if let n = line.lineNumber { dict["line"] = n }
        if let n = line.columnNumber { dict["column"] = n }
        return dict
    }

    private func inspectResultJSON(_ result: InspectResult) -> [String: Any] {
        var dict: [String: Any] = [
            "tab_id": result.tabID.uuidString,
            "selector": result.selector,
            "xpath": result.xpath,
            "tag": result.tag,
            "id": result.elementID,
            "url": result.url,
            "text": result.text,
            "attributes": result.attributes,
            "rect": [
                "x": result.rect.origin.x,
                "y": result.rect.origin.y,
                "w": result.rect.size.width,
                "h": result.rect.size.height
            ],
            "captured_at": InspectPayloadSanitiser.isoFormatter.string(from: result.capturedAt)
        ]
        if !result.outerHTML.isEmpty { dict["outer_html"] = result.outerHTML }
        if !result.contextHTML.isEmpty { dict["context_html"] = result.contextHTML }
        if !result.comment.isEmpty { dict["comment"] = result.comment }
        return dict
    }

    func handleWebConsole(
        state: State,
        scope: WebPaneScope,
        since: UInt64,
        level: String?,
        clear: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let entries = resolved.webState.consoleBuffer.entries(since: since)
        let filtered: [RingBuffer<ConsoleLine>.Entry] = if let level {
            entries.filter { $0.value.level.rawValue == level }
        } else {
            entries
        }
        let nextSeq = resolved.webState.consoleBuffer.nextSeq
        let dropped = resolved.webState.consoleBuffer.droppedSinceLastDrain
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "lines": filtered.map(consoleLineJSON),
            "next_since": nextSeq,
            "dropped": dropped
        ])
        // Acknowledge the reported drops so the next call only
        // surfaces drops that accumulated after this drain. Always
        // dispatched, even when `dropped == 0`, so the reducer
        // doesn't have to branch on it.
        var effects: [Effect<Action>] = [
            .send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webConsoleAcknowledgeDrops(paneID: resolved.paneID)
            )))
        ]
        if clear {
            effects.append(.send(.workspaces(.element(
                id: resolved.workspace.id,
                action: .webConsoleClear(paneID: resolved.paneID)
            ))))
        }
        return .merge(effects)
    }

    func handleWebInspect(
        state: State,
        scope: WebPaneScope,
        sendTo: String?,
        submit: Bool,
        disarm: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }

        // Explicit disarm path: no arming, just clear server-side
        // state and the in-page picker.
        if disarm {
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolved.paneID.uuidString,
                "armed": false
            ])
            let resolvedPaneID = resolved.paneID
            let store = webPaneStore
            return .merge(
                .send(.workspaces(.element(
                    id: resolved.workspace.id,
                    action: .webInspectDisarm(paneID: resolvedPaneID)
                ))),
                .run { _ in
                    await MainActor.run {
                        store.coordinatorIfExists(for: resolvedPaneID)?.disarmInspector()
                    }
                }
            )
        }

        guard let tab = resolved.webState.activeTab else {
            reply?.error("web pane has no active tab")
            return .none
        }

        // Resolve `--send-to` to a concrete pane UUID up front so we
        // can report a clear error before arming. Only `.shell` panes
        // have a terminal surface that `paneSendText` can write to —
        // markdown / scratchpad / diff / web destinations would
        // silently no-op inside `SurfaceManager.sendText`, so reject
        // them here with a typed error instead.
        let sendToPaneID: UUID?
        if let sendTo {
            switch resolvePaneTarget(
                state: state, paneID: scope.paneID, target: sendTo,
                workspaceFilter: scope.workspaceFilter
            ) {
            case .found(let resolvedID, let workspace):
                guard let destPane = workspace.panes[id: resolvedID] else {
                    reply?.error("--send-to: pane not found: \(resolvedID.uuidString)")
                    return .none
                }
                guard destPane.type == .shell else {
                    reply?.error(
                        "--send-to: destination must be a shell pane (got: \(destPane.type.rawValue))"
                    )
                    return .none
                }
                sendToPaneID = resolvedID
            case .error(let message):
                reply?.error("--send-to: \(message)")
                return .none
            }
        } else {
            sendToPaneID = nil
        }

        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let store = webPaneStore
        let tabID = tab.id
        let isPrivate = resolved.webState.isPrivate

        return .run { send in
            // Arm the in-page picker on the main actor and read back
            // the nonce. Hop to MainActor.run synchronously so we
            // can return the nonce before the reply lands.
            let nonce: String? = await MainActor.run {
                store.coordinator(for: resolvedPaneID, isPrivate: isPrivate).armInspector(tabID: tabID)
            }
            guard let nonce else {
                reply?.error("failed to arm inspector for active tab")
                return
            }
            await send(.workspaces(.element(
                id: workspaceID,
                action: .webInspectArmedFor(
                    paneID: resolvedPaneID,
                    sendTo: sendToPaneID,
                    nonce: nonce
                )
            )))
            if submit {
                await send(.setWebInspectArmedSubmit(paneID: resolvedPaneID, submit: true))
            }
            reply?.sendAndClose([
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "tab_id": tabID.uuidString,
                "armed": true,
                "send_to": sendToPaneID?.uuidString ?? "",
                "submit": submit
            ])
        }
    }

    func handleWebInspectResult(
        state: State,
        scope: WebPaneScope,
        clear: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        // Drain *both* sources: the legacy single-shot queue
        // (`inspectResultQueue`, written by `nex web inspect`
        // without `--send-to`) and the batch panel items (the
        // unified UI queue — items collected via the scope button
        // that haven't been sent to a target yet). Items annotate
        // with their per-batch comment before serialising.
        var results: [InspectResult] = []
        results.append(contentsOf: resolved.webState.inspectResultQueue)
        if let batch = resolved.webState.batchInspect {
            for item in batch.items {
                var annotated = item.result
                annotated.comment = item.comment
                results.append(annotated)
            }
        }
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "results": results.map(inspectResultJSON)
        ])
        if clear {
            var effects: [Effect<Action>] = [
                .send(.workspaces(.element(
                    id: resolved.workspace.id,
                    action: .webInspectResultClear(paneID: resolved.paneID)
                )))
            ]
            // Only tear down the batch when one exists — `Cancel`
            // disarms the page picker, and a single-shot inspect may
            // be armed on this pane independently of any batch.
            if resolved.webState.batchInspect != nil {
                effects.append(.send(.webBatchInspectCancel(paneID: resolved.paneID)))
            }
            return .merge(effects)
        }
        return .none
    }

    // MARK: - Web pane storage / cookies handlers (Phase 5)

    func handleWebPrivate(
        state: State,
        scope: WebPaneScope,
        enabled: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let already = resolved.webState.isPrivate == enabled
        reply?.sendAndClose([
            "ok": true,
            "pane_id": resolved.paneID.uuidString,
            "workspace_id": resolved.workspace.id.uuidString,
            "private": enabled,
            "changed": !already
        ])
        if already { return .none }
        return .send(.webPaneSetPrivate(paneID: resolved.paneID, enabled: enabled))
    }

    func handleWebCookiesList(
        state: State,
        scope: WebPaneScope,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        let isPrivate = resolved.webState.isPrivate
        return .run { _ in
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let coord = store.coordinatorIfExists(for: resolvedPaneID) else {
                        continuation.resume(returning: [])
                        return
                    }
                    coord.dataStore.httpCookieStore.getAllCookies { result in
                        continuation.resume(returning: result)
                    }
                }
            }
            let payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "private": isPrivate,
                "cookies": cookies.map(Self.cookieJSON)
            ]
            reply?.sendAndClose(payload)
        }
    }

    func handleWebCookiesClear(
        state: State,
        scope: WebPaneScope,
        domain: String?,
        all: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        if all, domain != nil {
            reply?.error("--all and --domain are mutually exclusive")
            return .none
        }
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        return .run { _ in
            let removed: Int = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let coord = store.coordinatorIfExists(for: resolvedPaneID) else {
                        continuation.resume(returning: 0)
                        return
                    }
                    let dataStore = coord.dataStore
                    if all {
                        let types = WKWebsiteDataStore.allWebsiteDataTypes()
                        dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
                            // Count is unknown for the omnibus
                            // removeData path; report -1 so callers
                            // can distinguish from "0 cookies matched".
                            continuation.resume(returning: -1)
                        }
                        return
                    }
                    let needle = domain.map(HTTPCookie.canonicalDomain)
                    dataStore.httpCookieStore.deleteAll(
                        matching: { cookie in
                            guard let needle else { return true }
                            return HTTPCookie.canonicalDomain(cookie.domain) == needle
                        },
                        completion: { count in continuation.resume(returning: count) }
                    )
                }
            }
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString
            ]
            if all {
                payload["cleared_site_data"] = true
            } else {
                payload["deleted"] = removed
                if let domain {
                    payload["domain"] = domain
                }
            }
            reply?.sendAndClose(payload)
        }
    }

    func handleWebCookiesDelete(
        state: State,
        scope: WebPaneScope,
        name: String,
        domain: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        guard let resolved = resolveWebPane(state: state, scope: scope, reply: reply)
        else { return .none }
        let store = webPaneStore
        let resolvedPaneID = resolved.paneID
        let workspaceID = resolved.workspace.id
        return .run { _ in
            let removed: Int = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let coord = store.coordinatorIfExists(for: resolvedPaneID) else {
                        continuation.resume(returning: 0)
                        return
                    }
                    let needle = domain.map(HTTPCookie.canonicalDomain)
                    coord.dataStore.httpCookieStore.deleteAll(
                        matching: { cookie in
                            guard cookie.name == name else { return false }
                            guard let needle else { return true }
                            return HTTPCookie.canonicalDomain(cookie.domain) == needle
                        },
                        completion: { count in continuation.resume(returning: count) }
                    )
                }
            }
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedPaneID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "deleted": removed,
                "name": name
            ]
            if let domain {
                payload["domain"] = domain
            }
            reply?.sendAndClose(payload)
        }
    }

    private static func cookieJSON(_ cookie: HTTPCookie) -> [String: Any] {
        var dict: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "is_secure": cookie.isSecure,
            "is_http_only": cookie.isHTTPOnly
        ]
        if let expires = cookie.expiresDate {
            dict["expires"] = expires.timeIntervalSince1970
        }
        if cookie.isSessionOnly {
            dict["session_only"] = true
        }
        return dict
    }
}
