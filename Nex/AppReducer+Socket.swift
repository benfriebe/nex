import AppKit
import ComposableArchitecture
import Foundation

// MARK: - Socket reduce-block (SocketRouter)

extension AppReducer {
    /// Extracted per-domain reduce-block that is the **sole owner** of
    /// the single `.socketMessage` `Action` case (the `nex` CLI's
    /// request/response FD pipe). `.socketMessage` carries the `reply`
    /// handle, so exactly one reducer may ever match it — a second match
    /// would hand the CLI a doubled JSON line or a premature EOF. The
    /// exhaustive `domain(of:)` partition maps `.socketMessage` to
    /// `.socket` and nothing else, and only this block guards on it.
    ///
    /// The giant nested `switch message` (agent lifecycle, pane / workspace
    /// / file / layout commands, and the request/response verbs) plus the
    /// socket-only helpers below are moved here verbatim from the original
    /// `AppReducer.body` switch and struct body; every `reply.send(...)` /
    /// `reply.close()` sequence and the `agentStopped` / `notification` /
    /// `paneMoveToWorkspace` effect orderings are byte-identical. Shared
    /// helpers (`resolvePaneTarget`, `paneSendText`, `tailLines`, the graft
    /// + `handleWeb*` handlers) stay in core / WebPane and are reached via
    /// `self`; dependency access (`surfaceManager`, `notificationService`,
    /// `graftService`, `ghosttyConfig`, `uuid`) goes through `self` exactly
    /// as before.
    var socketReducer: some ReducerOf<Self> {
        Reduce { state, action in
            guard Self.domain(of: action) == .socket else { return .none }
            switch action {
            case .socketMessage(let message, let reply):
                switch message {
                // MARK: Agent lifecycle

                case .agentStarted(let paneID):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    // If we get a "start" while already running, the previous "stop"
                    // was missed (e.g. user interrupted Claude). Reset to idle first
                    // so the status lifecycle stays clean.
                    if workspace.pane(id: paneID)?.status == .running {
                        state.workspaces[id: workspace.id]?.mutatePane(id: paneID) {
                            $0.status = .idle
                        }
                    }

                    return .merge(
                        .send(.workspaces(.element(id: workspace.id, action: .agentStarted(paneID: paneID)))),
                        .send(.updateExternalIndicators)
                    )

                case .agentStopped(let paneID):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    let isFocused = state.activeWorkspaceID == workspace.id && workspace.focusedPaneID == paneID
                    let notifService = notificationService
                    let wsID = workspace.id
                    let isAppActive = MainActor.assumeIsolated { NSApp.isActive }
                    let shouldNotify = !isFocused || !isAppActive
                    let shouldBounce = !isAppActive
                    let title = workspace.pane(id: paneID)?.title ?? workspace.name

                    return .merge(
                        .send(.workspaces(.element(id: workspace.id, action: .agentStopped(paneID: paneID)))),
                        .send(.updateExternalIndicators),
                        .run { _ in
                            if shouldNotify {
                                notifService.post(
                                    title: title,
                                    body: "Agent is waiting for input",
                                    paneID: paneID,
                                    workspaceID: wsID
                                )
                            }
                            if shouldBounce {
                                _ = await MainActor.run {
                                    NSApp.requestUserAttention(.informationalRequest)
                                }
                            }
                        }
                    )

                case .agentError(let paneID, let message):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    let notifService = notificationService
                    let wsID = workspace.id

                    return .merge(
                        .send(.workspaces(.element(id: workspace.id, action: .agentError(paneID: paneID)))),
                        .send(.updateExternalIndicators),
                        .run { _ in
                            notifService.post(
                                title: "Agent Error",
                                body: message,
                                paneID: paneID,
                                workspaceID: wsID
                            )
                        }
                    )

                case .notification(let paneID, let title, let body):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    let isFocused = state.activeWorkspaceID == workspace.id && workspace.focusedPaneID == paneID
                    let notifService = notificationService
                    let wsID = workspace.id
                    let isAppActive = MainActor.assumeIsolated { NSApp.isActive }

                    var effects: [Effect<Action>] = [
                        .send(.workspaces(.element(id: workspace.id, action: .agentStopped(paneID: paneID)))),
                        .send(.updateExternalIndicators)
                    ]
                    if !isFocused || !isAppActive {
                        effects.append(.run { _ in
                            notifService.post(title: title, body: body, paneID: paneID, workspaceID: wsID)
                        })
                    }
                    return .merge(effects)

                case .sessionStarted(let paneID, let sessionID):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    return .merge(
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .sessionStarted(paneID: paneID, sessionID: sessionID)
                        ))),
                        .send(.updateExternalIndicators)
                    )

                case .sessionEnded(let paneID, let sessionID):
                    guard let workspace = state.workspaceContainingPane(paneID)
                    else { return .none }

                    // Persist so the cleared session id survives the next
                    // launch — otherwise the resume loop on restart would
                    // still see the stale id and reattach a dead session.
                    return .merge(
                        .send(.workspaces(.element(
                            id: workspace.id,
                            action: .sessionEnded(paneID: paneID, sessionID: sessionID)
                        ))),
                        .send(.persistState)
                    )

                // MARK: Pane commands

                case let .paneSplit(paneID, direction, path, name, target, workspaceFilter):
                    return handlePaneSplit(
                        state: &state,
                        paneID: paneID,
                        direction: direction,
                        path: path,
                        name: name,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case let .paneCreate(paneID, path, name, target, workspaceFilter):
                    return handlePaneCreate(
                        state: &state,
                        paneID: paneID,
                        path: path,
                        name: name,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case .paneClose(let paneID, let target, let workspaceFilter):
                    return handlePaneClose(
                        state: state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case let .paneName(paneID, target, workspace, name):
                    return handlePaneName(
                        state: &state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspace,
                        name: name,
                        reply: reply
                    )

                case .paneSend(let paneID, let target, let text, let workspaceFilter, let bare):
                    return handlePaneSend(
                        state: state,
                        paneID: paneID,
                        target: target,
                        text: text,
                        workspaceFilter: workspaceFilter,
                        bare: bare,
                        reply: reply
                    )

                case .paneSendKey(let paneID, let target, let key, let workspaceFilter):
                    return handlePaneSendKey(
                        state: state,
                        paneID: paneID,
                        target: target,
                        key: key,
                        workspaceFilter: workspaceFilter,
                        reply: reply
                    )

                case .paneSync(let paneID, let workspaceFilter, let action):
                    return handlePaneSync(
                        state: state,
                        paneID: paneID,
                        workspaceFilter: workspaceFilter,
                        action: action,
                        reply: reply
                    )

                case .paneSyncExclude(let paneID, let target, let workspaceFilter, let excluded):
                    return handlePaneSyncExclude(
                        state: state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        excluded: excluded,
                        reply: reply
                    )

                case .paneMove(let paneID, let direction):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    state.workspaces[id: workspace.id]?.setFocus(paneID)
                    return .send(.workspaces(.element(
                        id: workspace.id, action: .movePaneInDirection(direction)
                    )))

                case .paneMoveToWorkspace(let paneID, let toWorkspace, let create):
                    // Find source workspace
                    guard let sourceWS = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }

                    // Resolve target workspace
                    var targetWSID = Self.resolveWorkspace(toWorkspace, state: state)

                    // Auto-create if requested
                    if targetWSID == nil, create {
                        let newID = uuid()
                        let newWS = WorkspaceFeature.State(
                            id: newID, name: toWorkspace,
                            slug: WorkspaceFeature.State.makeSlug(from: toWorkspace, id: newID),
                            color: state.workspaces.nextRandomColor(), panes: [], layout: .empty,
                            focusedPaneID: nil, createdAt: Date(), lastAccessedAt: Date()
                        )
                        state.workspaces.append(newWS)
                        state.topLevelOrder.append(.workspace(newID))
                        targetWSID = newID
                        // Scroll the freshly created (and about-to-be-active)
                        // destination workspace into view (issue #187). Only
                        // the auto-create branch: moving into an existing
                        // workspace is a plain move, out of scope.
                        state.sidebarScrollTarget = .workspace(newID)
                    }

                    guard let targetWSID, targetWSID != sourceWS.id else { return .none }
                    guard let pane = sourceWS.panes[id: paneID] else { return .none }

                    let sourceWSID = sourceWS.id

                    // Capture web sidecar before removal so it can
                    // ride along to the target workspace below. The
                    // Pane struct doesn't carry tab/URL state for
                    // `.web` panes — it lives in `webPanes[paneID]`
                    // on the workspace, and the move must transfer
                    // it explicitly or the target ends up with a
                    // blank pane and `nex web url` fails with
                    // "web pane state missing".
                    let webStateToTransfer: WebPaneState? = pane.type == .web
                        ? sourceWS.webPanes[paneID]
                        : nil

                    // Remove from source
                    state.workspaces[id: sourceWSID]?.panes.remove(id: paneID)
                    if webStateToTransfer != nil {
                        state.workspaces[id: sourceWSID]?.webPanes.removeValue(forKey: paneID)
                    }
                    // Drop any source-side sync exclusion for this pane.
                    // Otherwise a later move-back would silently re-apply
                    // the orphan opt-out with no UI hint to explain why.
                    state.workspaces[id: sourceWSID]?.syncInputExcluded.remove(paneID)
                    let newSourceLayout = state.workspaces[id: sourceWSID]!.layout.removing(paneID: paneID)
                    state.workspaces[id: sourceWSID]?.layout = newSourceLayout
                    state.workspaces[id: sourceWSID]?.currentLayoutIndex = nil

                    // Source-side close-like refocus: walk the per-session
                    // focus stack first so the user lands on whatever they
                    // had focused before the moved pane, not the layout's
                    // first leaf. Mirrors the WorkspaceFeature.closePane
                    // contract.
                    state.workspaces[id: sourceWSID]?.focusHistory.removeAll { $0 == paneID }
                    if state.workspaces[id: sourceWSID]?.focusedPaneID == paneID {
                        let popped = state.workspaces[id: sourceWSID]?.popFocusFromHistory(excluding: paneID) ?? nil
                        state.workspaces[id: sourceWSID]?.focusedPaneID = popped ?? newSourceLayout.allPaneIDs.first
                    }
                    var dropMarkdownFind = false
                    if state.workspaces[id: sourceWSID]?.searchingPaneID == paneID {
                        state.workspaces[id: sourceWSID]?.searchingPaneID = nil
                        state.workspaces[id: sourceWSID]?.searchNeedle = ""
                        state.workspaces[id: sourceWSID]?.searchTotal = nil
                        state.workspaces[id: sourceWSID]?.searchSelected = nil
                        // Drop any in-DOM find marks on a markdown pane being
                        // moved across workspaces (the WKWebView/coordinator
                        // travels with the pane, but its workspace-level
                        // search context does not).
                        dropMarkdownFind = pane.type == .markdown
                    }
                    if state.workspaces[id: sourceWSID]?.zoomedPaneID == paneID {
                        if let saved = state.workspaces[id: sourceWSID]?.savedLayout {
                            state.workspaces[id: sourceWSID]?.layout = saved.removing(paneID: paneID)
                        }
                        state.workspaces[id: sourceWSID]?.zoomedPaneID = nil
                        state.workspaces[id: sourceWSID]?.savedLayout = nil
                    }

                    // Add to target
                    state.workspaces[id: targetWSID]?.panes.append(pane)
                    if let webStateToTransfer {
                        state.workspaces[id: targetWSID]?.webPanes[paneID] = webStateToTransfer
                    }

                    let targetLayout = state.workspaces[id: targetWSID]?.layout ?? .empty
                    if targetLayout.isEmpty {
                        state.workspaces[id: targetWSID]?.layout = .leaf(paneID)
                    } else {
                        let anchorID = state.workspaces[id: targetWSID]?.focusedPaneID
                            ?? targetLayout.allPaneIDs.first
                        if let anchorID {
                            let newLayout = targetLayout.splitting(
                                paneID: anchorID, direction: .horizontal, newPaneID: paneID
                            ).layout
                            state.workspaces[id: targetWSID]?.layout = newLayout
                        }
                    }

                    state.workspaces[id: targetWSID]?.setFocus(paneID)
                    state.workspaces[id: targetWSID]?.currentLayoutIndex = nil
                    state.activeWorkspaceID = targetWSID

                    // Issue #121 — cross-workspace move bypasses the
                    // WorkspaceFeature bookkeeping reducer, so we have
                    // to push fresh sync-group snapshots for both
                    // source and target explicitly. Without these, the
                    // source workspace's `SurfaceManager.syncGroups`
                    // entry would still reference the moved pane and
                    // the target would never broadcast to it.
                    let sourceSyncEffect = refreshSyncGroupForWorkspace(
                        workspaceID: sourceWSID, state: state
                    )
                    let targetSyncEffect = refreshSyncGroupForWorkspace(
                        workspaceID: targetWSID, state: state
                    )

                    if dropMarkdownFind {
                        return .merge(
                            .run { _ in
                                await MainActor.run {
                                    MarkdownFindController.shared.close(paneID: paneID)
                                }
                            },
                            sourceSyncEffect,
                            targetSyncEffect,
                            .send(.persistState)
                        )
                    }
                    return .merge(sourceSyncEffect, targetSyncEffect, .send(.persistState))

                // MARK: Workspace commands

                case .workspaceCreate(let name, let path, let color, let group, let profile):
                    return handleSocketWorkspaceCreate(
                        &state,
                        name: name,
                        path: path,
                        color: color,
                        group: group,
                        profile: profile
                    )

                case .workspaceMove(let nameOrID, let group, let index):
                    return handleSocketWorkspaceMove(
                        &state,
                        nameOrID: nameOrID,
                        group: group,
                        index: index
                    )

                case .workspaceProfile(let nameOrID, let profile):
                    // UUID-wins / unique-name / ambiguous→no-op semantics
                    // come from `resolveWorkspace`, matching workspace-move.
                    guard let workspace = state.resolveWorkspace(nameOrID) else { return .none }
                    return .send(.workspaces(.element(
                        id: workspace.id,
                        action: .setProfile(profile)
                    )))

                case .groupCreate(let name, let color):
                    return handleSocketGroupCreate(&state, name: name, color: color)

                case .groupRename(let nameOrID, let newName):
                    guard let group = state.resolveGroup(nameOrID) else { return .none }
                    return .send(.renameGroup(id: group.id, name: newName))

                case .groupDelete(let nameOrID, let cascade):
                    guard let group = state.resolveGroup(nameOrID) else { return .none }
                    return .send(.deleteGroup(id: group.id, cascade: cascade))

                // MARK: File commands

                case .openFile(let path, let paneID, let reuse):
                    if let paneID,
                       let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
                        state.workspaces[id: workspace.id]?.setFocus(paneID)
                        return .send(.workspaces(.element(
                            id: workspace.id,
                            action: .openMarkdownFile(filePath: path, reusePaneID: reuse ? paneID : nil)
                        )))
                    }
                    guard let activeID = state.activeWorkspaceID else { return .none }
                    return .send(.workspaces(.element(
                        id: activeID,
                        action: .openMarkdownFile(filePath: path, reusePaneID: nil)
                    )))

                case .openDiff(let repoPath, let targetPath, let paneID):
                    if let paneID,
                       let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) {
                        state.workspaces[id: workspace.id]?.setFocus(paneID)
                        return .send(.workspaces(.element(
                            id: workspace.id,
                            action: .openDiffPane(
                                repoPath: repoPath,
                                targetPath: targetPath,
                                reusePaneID: nil
                            )
                        )))
                    }
                    guard let activeID = state.activeWorkspaceID else { return .none }
                    return .send(.workspaces(.element(
                        id: activeID,
                        action: .openDiffPane(
                            repoPath: repoPath,
                            targetPath: targetPath,
                            reusePaneID: nil
                        )
                    )))

                // MARK: Layout commands

                case .layoutCycle(let paneID):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil })
                    else { return .none }
                    return .send(.workspaces(.element(id: workspace.id, action: .cycleLayout)))

                case .layoutSelect(let paneID, let name):
                    guard let workspace = state.workspaces.first(where: { $0.panes[id: paneID] != nil }),
                          let layout = PredefinedLayout(rawValue: name)
                    else { return .none }
                    return .send(.workspaces(.element(id: workspace.id, action: .selectLayout(layout))))

                // MARK: Request / response

                case .paneList(let paneID, let workspaceFilter, let scope):
                    handlePaneList(
                        state: state,
                        paneID: paneID,
                        workspaceFilter: workspaceFilter,
                        scope: scope,
                        reply: reply
                    )
                    return .none

                case .paneCapture(let paneID, let target, let workspaceFilter, let lines, let includeScrollback):
                    return handlePaneCapture(
                        state: state,
                        paneID: paneID,
                        target: target,
                        workspaceFilter: workspaceFilter,
                        lines: lines,
                        includeScrollback: includeScrollback,
                        reply: reply
                    )

                case .graftStart(let workspaceFilter, let repoFilter, let paneID):
                    return handleGraftStart(
                        state: state,
                        workspaceFilter: workspaceFilter,
                        repoFilter: repoFilter,
                        paneID: paneID,
                        reply: reply
                    )

                case .graftStop(let workspaceFilter, let repoFilter, let paneID):
                    return handleGraftStop(
                        state: state,
                        workspaceFilter: workspaceFilter,
                        repoFilter: repoFilter,
                        paneID: paneID,
                        reply: reply
                    )

                case .graftStatus:
                    return handleGraftStatus(state: state, reply: reply)

                case .ping:
                    return handlePing(reply: reply)

                case .webOpen(let paneID, let url, let isPrivate):
                    return handleWebOpen(
                        state: state,
                        paneID: paneID,
                        url: url,
                        isPrivate: isPrivate,
                        reply: reply
                    )

                case .webNavigate(let paneID, let target, let workspaceFilter, let url):
                    return handleWebNavigate(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        url: url,
                        reply: reply
                    )

                case .webURL(let paneID, let target, let workspaceFilter):
                    return handleWebURL(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        reply: reply
                    )

                case .webBack(let paneID, let target, let workspaceFilter):
                    return handleWebNav(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        action: .back,
                        reply: reply
                    )

                case .webForward(let paneID, let target, let workspaceFilter):
                    return handleWebNav(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        action: .forward,
                        reply: reply
                    )

                case .webReload(let paneID, let target, let workspaceFilter, let hard):
                    return handleWebNav(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        action: hard ? .reloadHard : .reload,
                        reply: reply
                    )

                case .webCapture(let paneID, let target, let workspaceFilter, let mode):
                    return handleWebCapture(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        mode: mode,
                        reply: reply
                    )

                case .webTabs(let paneID, let target, let workspaceFilter):
                    return handleWebTabs(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        reply: reply
                    )

                case .webTabNew(let paneID, let target, let workspaceFilter, let url, let makeActive):
                    return handleWebTabNew(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        url: url,
                        makeActive: makeActive,
                        reply: reply
                    )

                case .webTabClose(let paneID, let target, let workspaceFilter, let tabRef):
                    return handleWebTabClose(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        tabRef: tabRef,
                        reply: reply
                    )

                case .webTabSelect(let paneID, let target, let workspaceFilter, let tabRef):
                    return handleWebTabSelect(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        tabRef: tabRef,
                        reply: reply
                    )

                case .webConsole(let paneID, let target, let workspaceFilter, let since, let level, let clear):
                    return handleWebConsole(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        since: since,
                        level: level,
                        clear: clear,
                        reply: reply
                    )

                case .webInspect(let paneID, let target, let workspaceFilter, let sendTo, let submit, let disarm):
                    return handleWebInspect(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        sendTo: sendTo,
                        submit: submit,
                        disarm: disarm,
                        reply: reply
                    )

                case .webInspectResult(let paneID, let target, let workspaceFilter, let clear):
                    return handleWebInspectResult(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        clear: clear,
                        reply: reply
                    )

                case .webPrivate(let paneID, let target, let workspaceFilter, let enabled):
                    return handleWebPrivate(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        enabled: enabled,
                        reply: reply
                    )

                case .webCookiesList(let paneID, let target, let workspaceFilter):
                    return handleWebCookiesList(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        reply: reply
                    )

                case .webCookiesClear(let paneID, let target, let workspaceFilter, let domain, let all):
                    return handleWebCookiesClear(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        domain: domain,
                        all: all,
                        reply: reply
                    )

                case .webCookiesDelete(let paneID, let target, let workspaceFilter, let name, let domain):
                    return handleWebCookiesDelete(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        name: name,
                        domain: domain,
                        reply: reply
                    )

                case .webClick(let paneID, let target, let workspaceFilter, let selector, let double, let right, let atX, let atY):
                    return handleWebClick(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        double: double,
                        right: right,
                        atX: atX,
                        atY: atY,
                        reply: reply
                    )

                case .webType(let paneID, let target, let workspaceFilter, let selector, let text, let submit, let replace):
                    return handleWebType(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        text: text,
                        submit: submit,
                        replace: replace,
                        reply: reply
                    )

                case .webQText(let paneID, let target, let workspaceFilter, let selector, let maxBytes):
                    return handleWebQText(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        maxBytes: maxBytes,
                        reply: reply
                    )

                case .webQAttr(let paneID, let target, let workspaceFilter, let selector, let attribute):
                    return handleWebQAttr(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        attribute: attribute,
                        reply: reply
                    )

                case .webQCount(let paneID, let target, let workspaceFilter, let selector):
                    return handleWebQCount(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        reply: reply
                    )

                case .webQExists(let paneID, let target, let workspaceFilter, let selector):
                    return handleWebQExists(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        reply: reply
                    )

                case .webQDom(let paneID, let target, let workspaceFilter, let selector, let maxBytes):
                    return handleWebQDom(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        maxBytes: maxBytes,
                        reply: reply
                    )

                case .webWait(let paneID, let target, let workspaceFilter, let selector, let urlMatch, let forCondition, let timeoutMs):
                    return handleWebWait(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        urlMatch: urlMatch,
                        forCondition: forCondition,
                        timeoutMs: timeoutMs,
                        reply: reply
                    )

                case .webSelect(let paneID, let target, let workspaceFilter, let selector, let valueOrLabel):
                    return handleWebSelect(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        valueOrLabel: valueOrLabel,
                        reply: reply
                    )

                case .webScroll(let paneID, let target, let workspaceFilter, let selector, let block, let behavior):
                    return handleWebScroll(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        block: block,
                        behavior: behavior,
                        reply: reply
                    )

                case .webHover(let paneID, let target, let workspaceFilter, let selector):
                    return handleWebHover(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        selector: selector,
                        reply: reply
                    )

                case .webKey(let paneID, let target, let workspaceFilter, let keyName, let selector):
                    return handleWebKey(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        keyName: keyName,
                        selector: selector,
                        reply: reply
                    )

                case .webExec(let paneID, let target, let workspaceFilter, let script):
                    return handleWebExec(
                        state: state,
                        scope: WebPaneScope(paneID: paneID, target: target, workspaceFilter: workspaceFilter),
                        script: script,
                        reply: reply
                    )
                }

            default:
                return .none
            }
        }
    }

    // MARK: - Socket command helpers

    /// Dispatch `workspace-create` from the CLI. If a `group` is
    /// supplied, the workspace is created first (which synchronously
    /// mutates state) then the new workspace is moved into the group
    /// — creating the group if it doesn't already exist. Resolving
    /// the group name AFTER the workspace is appended means a
    /// pre-existing group is picked up by `resolveGroup`, and a
    /// missing one spawns a new bare group that we can target by id.
    private func handleSocketWorkspaceCreate(
        _ state: inout State,
        name: String?,
        path: String?,
        color: WorkspaceColor?,
        group: String?,
        profile: String? = nil
    ) -> Effect<Action> {
        let createEffect: Effect<Action> = .send(.createWorkspace(
            name: name ?? "Workspace",
            color: color,
            workingDirectory: path,
            profileName: profile
        ))
        // A missing `group` OR a group that's all whitespace falls
        // back to the top-level create path. Whitespace-only names
        // wouldn't survive the existing `createGroup` trim check
        // anyway, so treat them as "no group specified."
        let trimmedGroup = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedGroup, !trimmedGroup.isEmpty else { return createEffect }

        // Resolve BEFORE any state mutation so an ambiguous-name
        // match can cleanly abort the whole message. `resolveGroup`
        // returns nil for both "missing" and "ambiguous" — we
        // disambiguate by checking for ANY match on that name
        // before deciding to create a new group.
        let existingGroup = state.resolveGroup(trimmedGroup)
        if existingGroup == nil,
           state.groups.contains(where: { $0.name == trimmedGroup }) {
            // Multiple groups share this name — don't silently
            // create a third. The user needs to disambiguate (e.g.
            // by passing a UUID) or rename one of the existing
            // groups first.
            return .none
        }

        // `createWorkspace` uses `@Dependency(\.uuid)` so we
        // pre-compute the id here to keep the move-into-group
        // dispatch precise. Then we seed state directly so the
        // follow-up move lands deterministically even when the
        // reducer batches effects.
        let newWorkspaceID = uuid()
        let workspace = WorkspaceFeature.State(
            id: newWorkspaceID,
            name: name ?? "Workspace",
            color: color ?? state.workspaces.nextRandomColor()
        )
        var seeded = workspace
        if let path {
            seeded.panes[seeded.panes.startIndex].workingDirectory = path
        }
        // Must land before `seeded` is appended into state below — a later
        // assignment would mutate a dead local. The surface effect at the
        // bottom of this handler resolves env from this value.
        if let profile {
            let trimmed = profile.trimmingCharacters(in: .whitespaces)
            seeded.profileName = trimmed.isEmpty ? nil : trimmed
        }
        // Capture the anchor for `.nearSelection` BEFORE overwriting
        // `activeWorkspaceID` — the previously active workspace is what
        // we want the new one to land next to within the target group.
        let previousActiveID = state.activeWorkspaceID
        state.workspaces.append(seeded)
        state.topLevelOrder.append(.workspace(newWorkspaceID))
        state.activeWorkspaceID = newWorkspaceID
        // Scroll the new (now-active) workspace into view (issue #187).
        // The sidebar re-resolves this to its parent group header at
        // scroll time if the follow-up `.moveWorkspaceToGroup` lands it
        // inside a collapsed group.
        state.sidebarScrollTarget = .workspace(newWorkspaceID)

        // Resolve or create the group.
        let targetGroupID: UUID
        if let existing = existingGroup {
            targetGroupID = existing.id
        } else {
            let newGroup = WorkspaceGroup(id: uuid(), name: trimmedGroup)
            state.groups.append(newGroup)
            state.topLevelOrder.append(.group(newGroup.id))
            targetGroupID = newGroup.id
        }

        // Mirror the `createWorkspace` + groupID path: honor the
        // `newWorkspacePlacement` setting when picking the slot in
        // the target group's childOrder. `.endOfList` appends (nil),
        // `.nearSelection` inserts right after the previously-active
        // workspace's slot when it's in the same group. A freshly
        // created group has an empty childOrder, so both modes land
        // on append for the "new group" branch above.
        let targetIndex: Int? = {
            switch state.settings.newWorkspacePlacement {
            case .endOfList:
                return nil
            case .nearSelection:
                guard let previousActiveID,
                      let idx = state.groups[id: targetGroupID]?.childOrder.firstIndex(of: previousActiveID)
                else {
                    return nil
                }
                return idx + 1
            }
        }()

        // Create the initial surface for the workspace, then move it
        // under the resolved group, then persist. Mirrors the
        // effects `createWorkspace` would run in the non-group path.
        let paneID = seeded.panes.first!.id
        let cwd = seeded.panes.first!.workingDirectory
        let opacity = ghosttyConfig.backgroundOpacity
        let profileName = seeded.profileName
        // `moveWorkspaceToGroup` persists, so an explicit persist
        // here would race it. Only the surface-creation side-effect
        // needs to fire alongside.
        return .merge(
            .run { _ in
                let env = profileName.map { workspaceProfiles.resolveEnv($0) } ?? [:]
                await surfaceManager.createSurface(
                    paneID: paneID,
                    workingDirectory: cwd,
                    backgroundOpacity: opacity,
                    env: env
                )
            },
            .send(.moveWorkspaceToGroup(
                workspaceID: newWorkspaceID,
                groupID: targetGroupID,
                index: targetIndex
            ))
        )
    }

    /// Dispatch `workspace-move`. `group == nil` targets the top
    /// level; `group` non-nil resolves an existing group (creating
    /// one is deliberately not supported here — use
    /// `workspace-create --group` for that).
    private func handleSocketWorkspaceMove(
        _ state: inout State,
        nameOrID: String,
        group: String?,
        index: Int?
    ) -> Effect<Action> {
        guard let workspace = state.resolveWorkspace(nameOrID) else { return .none }
        let targetGroupID: UUID?
        if let group {
            guard let resolved = state.resolveGroup(group) else { return .none }
            targetGroupID = resolved.id
        } else {
            targetGroupID = nil
        }
        return .send(.moveWorkspaceToGroup(
            workspaceID: workspace.id,
            groupID: targetGroupID,
            index: index
        ))
    }

    /// Dispatch `group-create`. Trims + rejects whitespace-only
    /// names to match the existing `.createGroup` reducer handler
    /// — a blank group name would render as empty header chrome
    /// and isn't reachable by `resolveGroup` once more than one
    /// exists. Icon is intentionally not exposed via this path:
    /// setting an icon is a UI-only affordance (context menu).
    private func handleSocketGroupCreate(
        _ state: inout State,
        name: String,
        color: WorkspaceColor?
    ) -> Effect<Action> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let newID = uuid()
        let createdGroup = WorkspaceGroup(id: newID, name: trimmed, color: color)
        state.groups.append(createdGroup)
        state.topLevelOrder.append(.group(newID))
        // Scroll the new group header into view (issue #187).
        state.sidebarScrollTarget = .group(newID)
        return .send(.persistState)
    }

    /// Shared success reply for `pane-split` / `pane-create`: the new
    /// pane's UUID is minted by the caller and threaded into the
    /// workspace action so the reply can return it before the pane is
    /// actually built. `reply == nil` is the legacy fire-and-forget path.
    /// Success ack for `pane-split` / `pane-create`. The new pane's UUID
    /// is minted inside the WorkspaceFeature effect (not here), so the
    /// reply intentionally omits `pane_id` and reports the resolved
    /// workspace + the requested label instead. Callers that need the id
    /// can read it back via `nex pane list --json` (matching on the
    /// label). `reply == nil` is the legacy fire-and-forget path.
    /// Success ack for `pane-split` / `pane-create`. The new pane's UUID
    /// is minted up front by the handler and threaded into the
    /// WorkspaceFeature action (issue #117) so the reply can return it
    /// before the pane is actually built. `reply == nil` is the legacy
    /// fire-and-forget path.
    func replyPaneCreated(
        _ reply: SocketServer.ReplyHandle?,
        newPaneID: UUID,
        workspace: WorkspaceFeature.State,
        label: String?
    ) {
        guard let reply else { return }
        var payload: [String: Any] = [
            "ok": true,
            "pane_id": newPaneID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name
        ]
        if let label, !label.isEmpty { payload["label"] = label }
        reply.sendAndClose(payload)
    }

    // MARK: - Sync-input helpers (issue #121)

    /// Push the workspace's current sync group to `SurfaceManager`.
    /// Mirrors `WorkspaceFeature.refreshSyncGroup` but callable from
    /// the AppReducer layer — used by `paneMoveToWorkspace` which
    /// mutates `state.workspaces` directly and so bypasses the
    /// per-workspace bookkeeping reducer. Returns `.none` when the
    /// workspace has gone missing (race / typo) so we don't crash.
    private func refreshSyncGroupForWorkspace(
        workspaceID: UUID, state: State
    ) -> Effect<Action> {
        guard let workspace = state.workspaces[id: workspaceID] else { return .none }
        let paneIDs = workspace.syncedPaneIDs
        let mgr = surfaceManager
        return .run { _ in
            mgr.setSyncGroup(workspaceID: workspaceID, paneIDs: paneIDs)
        }
    }

    /// Build and send the standard sync-status reply payload.
    /// Mirrors the structure `pane sync status` returns so every
    /// sync subcommand surfaces consistent fields.
    func replySyncStatus(
        reply: SocketServer.ReplyHandle?,
        workspace: WorkspaceFeature.State
    ) {
        var excluded: [[String: Any]] = []
        // Sort by uuidString so the JSON reply has a stable order across
        // calls — otherwise Set<UUID> iteration order would make scripts
        // diffing `pane sync status --json` output flake intermittently.
        for paneID in workspace.syncInputExcluded.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let pane = workspace.panes[id: paneID] else { continue }
            var entry: [String: Any] = ["id": paneID.uuidString]
            if let label = pane.label { entry["label"] = label }
            excluded.append(entry)
        }
        let synced = workspace.syncedPaneIDs.map(\.uuidString).sorted()
        reply?.send([
            "ok": true,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name,
            "active": workspace.isSyncInputActive,
            "synced_pane_ids": synced,
            "excluded": excluded
        ])
        reply?.close()
    }

    // MARK: - Socket pane-command handlers

    /// Build the `pane-list` response payload and write it to the
    /// reply handle. Pure read of in-memory state — runs on the main
    /// actor and returns before any effects would fire.
    ///
    /// Filter semantics:
    /// - `workspace` and `scope == "current"` are mutually exclusive
    ///   (server replies with an error if both are set).
    /// - `scope == "current"` requires a valid `paneID`; the response
    ///   contains the panes in the workspace that owns it.
    /// - Unknown `workspace` → error response; unknown `scope` (other
    ///   than `nil` / `"all"` / `"current"`) → error response.
    func handlePaneList(
        state: State,
        paneID: UUID?,
        workspaceFilter: String?,
        scope: String?,
        reply: SocketServer.ReplyHandle?
    ) {
        guard let reply else { return }

        // Validate mutually exclusive filters.
        if workspaceFilter != nil, scope == "current" {
            reply.send(["ok": false, "error": "workspace and --current are mutually exclusive"])
            reply.close()
            return
        }

        // Resolve which workspaces to include.
        let workspaces: [WorkspaceFeature.State]
        switch scope {
        case nil, "all":
            if let filter = workspaceFilter {
                guard let ws = state.resolveWorkspace(filter) else {
                    reply.send(["ok": false, "error": "workspace not found: \(filter)"])
                    reply.close()
                    return
                }
                workspaces = [ws]
            } else {
                workspaces = Array(state.workspaces)
            }
        case "current":
            guard let paneID,
                  let ws = state.workspaces.first(where: { $0.panes[id: paneID] != nil }) else {
                reply.send(["ok": false, "error": "no workspace contains the requesting pane"])
                reply.close()
                return
            }
            workspaces = [ws]
        default:
            reply.send(["ok": false, "error": "unknown scope: \(scope ?? "")"])
            reply.close()
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var panes: [[String: Any]] = []
        for workspace in workspaces {
            for paneID in workspace.layout.allPaneIDs {
                guard let pane = workspace.panes[id: paneID] else { continue }
                var entry: [String: Any] = [
                    "id": pane.id.uuidString,
                    "type": pane.type.rawValue,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_name": workspace.name,
                    "working_directory": pane.workingDirectory,
                    "status": pane.status.rawValue,
                    "is_focused": workspace.focusedPaneID == pane.id,
                    "is_active_workspace": state.activeWorkspaceID == workspace.id,
                    "created_at": iso.string(from: pane.createdAt),
                    "last_activity_at": iso.string(from: pane.lastActivityAt)
                ]
                if let label = pane.label { entry["label"] = label }
                if let title = pane.title { entry["title"] = title }
                if let branch = pane.gitBranch { entry["git_branch"] = branch }
                if let sessionID = pane.agentSessionID { entry["agent_session_id"] = sessionID }
                if let filePath = pane.filePath { entry["file_path"] = filePath }
                panes.append(entry)
            }
        }

        reply.send(["ok": true, "panes": panes])
        reply.close()
    }

    /// Resolve + dispatch a `pane-close` request. `paneID` comes from
    /// `NEX_PANE_ID` (no-flag form); `target` is the `--target
    /// <name-or-uuid>` value; `workspaceFilter` optionally narrows
    /// label resolution to a specific workspace. Writes a structured
    /// `{ok,...}` reply and closes the connection. `reply` is nil on
    /// the legacy fire-and-forget path used by older CLIs (pre
    /// request/response) — we still dispatch the close in that case so
    /// old clients keep working against a new server.
    func handlePaneClose(
        state: State,
        paneID: UUID?,
        target: String?,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        var payload: [String: Any] = [
            "ok": true,
            "pane_id": resolvedID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name
        ]
        if let label = workspace.panes[id: resolvedID]?.label {
            payload["label"] = label
        }
        reply?.send(payload)
        reply?.close()
        return .send(.workspaces(.element(id: workspace.id, action: .closePane(resolvedID))))
    }

    /// Resolve + dispatch a `pane-capture` request. Reads the terminal
    /// contents of the resolved pane and replies with a `{ok,text,...}`
    /// payload. Rejects non-terminal panes (markdown / scratchpad / diff)
    /// upfront with a typed error.
    func handlePaneCapture(
        state: State,
        paneID: UUID?,
        target: String?,
        workspaceFilter: String?,
        lines: Int?,
        includeScrollback: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        func fail(_ error: String) -> Effect<Action> {
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        // The CLI rejects `--lines 0` upfront, but raw socket/TCP
        // clients can send any int — guard here so invalid input
        // gets a structured error rather than a silent empty success.
        if let lines, lines <= 0 {
            return fail("lines must be a positive integer (got \(lines))")
        }

        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            return fail(error)
        }

        guard let pane = workspace.panes[id: resolvedID] else {
            return fail("pane not found: \(resolvedID.uuidString)")
        }
        guard pane.type == .shell else {
            return fail("pane is not a terminal (type: \(pane.type.rawValue))")
        }

        let label = pane.label
        let workspaceName = workspace.name
        let workspaceID = workspace.id
        let mgr = surfaceManager
        return .run { _ in
            let text = await mgr.captureContents(paneID: resolvedID, includeScrollback: includeScrollback)
            guard let text else {
                reply?.send(["ok": false, "error": "pane closed during capture"])
                reply?.close()
                return
            }
            let trimmed = lines.map { Self.tailLines(text, $0) } ?? text
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "workspace_name": workspaceName,
                "text": trimmed
            ]
            if let label {
                payload["label"] = label
            }
            reply?.send(payload)
            reply?.close()
        }
    }

    /// Resolve + dispatch a `pane-send` request. Mirrors
    /// `handlePaneClose` / `handlePaneCapture` — uses the shared
    /// `resolvePaneTarget` so label lookup is scoped to the sender's
    /// workspace by default and `--workspace` is the explicit
    /// cross-workspace escape hatch (issue #92). Replies with
    /// `{ok:true,...}` on success, `{ok:false,error:...}` on failure.
    /// `reply == nil` is the legacy fire-and-forget path: dispatch on
    /// success and silently drop on error so older CLIs keep working.
    func handlePaneSend(
        state: State,
        paneID: UUID?,
        target: String,
        text: String,
        workspaceFilter: String?,
        bare: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        var payload: [String: Any] = [
            "ok": true,
            "pane_id": resolvedID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name,
            "bare": bare
        ]
        if let label = workspace.panes[id: resolvedID]?.label {
            payload["label"] = label
        }
        reply?.send(payload)
        reply?.close()

        return paneSendText(paneID: resolvedID, text: text, bare: bare)
    }

    /// Resolve + dispatch a `pane-send-key` request. Mirrors
    /// `handlePaneSend` — same target resolution, same reply
    /// contract, same fire-and-forget back-compat. Adds a key-name
    /// validation step that rejects unknown names with a structured
    /// error before touching the surface (issue #98). The reducer
    /// only knows the allowlist; the actual keystroke is synthesized
    /// inside `SurfaceManager.sendKey` via `GhosttySurface.sendNamedKey`.
    func handlePaneSendKey(
        state: State,
        paneID: UUID?,
        target: String,
        key: String,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        // Validate the key name first so an unknown key never silently
        // resolves a target. The supported set lives on
        // GhosttySurface so the CLI, reducer, and surface layer share
        // one source of truth.
        let normalizedKey = key.lowercased()
        guard GhosttySurface.namedKeyAliases.contains(normalizedKey) else {
            let valid = GhosttySurface.namedKeyAliases.joined(separator: ", ")
            reply?.send(["ok": false, "error": "unknown key '\(key)' (valid: \(valid))"])
            reply?.close()
            return .none
        }

        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        var payload: [String: Any] = [
            "ok": true,
            "pane_id": resolvedID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "workspace_name": workspace.name,
            "key": normalizedKey
        ]
        if let label = workspace.panes[id: resolvedID]?.label {
            payload["label"] = label
        }
        reply?.send(payload)
        reply?.close()

        let mgr = surfaceManager
        return .run { _ in
            await mgr.sendKey(to: resolvedID, keyName: normalizedKey)
        }
    }

    /// Resolve + dispatch a `pane-split` request (issue #117). Works from
    /// outside a Nex pane: `--target` (UUID = global, label = needs
    /// scope) names the pane to split; `--workspace` scopes label lookup
    /// or, on its own, splits the workspace's focused pane. Every exit
    /// acks or errors through `reply` (a no-op when `reply == nil`, so
    /// pre-#117 fire-and-forget clients keep working). Reuses the existing
    /// `splitPane` / `splitPaneAtPath` actions (no new enum case) so the
    /// type-check-sensitive ContentView body is unaffected.
    func handlePaneSplit(
        state: inout State,
        paneID: UUID?,
        direction: PaneLayout.SplitDirection?,
        path: String?,
        name: String?,
        target: String?,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let workspaceID: UUID
        let sourcePaneID: UUID

        // `--workspace` *without* `--target` selects the destination
        // workspace outright — even when the caller forwarded its own
        // NEX_PANE_ID — so a pane in workspace alpha can run
        // `nex pane split --workspace beta` (issue #117). `--target` keeps
        // precedence so `--target X --workspace Y` still scopes the label
        // lookup of X to Y; the caller's pane is only the source when
        // neither `--target` nor `--workspace` is given.
        if target == nil, let workspaceFilter {
            guard let ws = state.resolveWorkspace(workspaceFilter) else {
                reply?.error("workspace not found: \(workspaceFilter)")
                return .none
            }
            guard let source = ws.focusedPaneID ?? ws.panes.first?.id else {
                reply?.error("workspace '\(ws.name)' has no pane to split — use `nex pane create --workspace \(workspaceFilter)`")
                return .none
            }
            workspaceID = ws.id
            sourcePaneID = source
        } else if target != nil || paneID != nil {
            switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
            case .found(let resolved, let ws):
                workspaceID = ws.id
                sourcePaneID = resolved
            case .error(let error):
                reply?.error(error)
                return .none
            }
        } else {
            reply?.error("pane split requires --target or --workspace when called from outside a Nex pane")
            return .none
        }

        guard let workspace = state.workspaces[id: workspaceID] else {
            reply?.error("workspace not found")
            return .none
        }

        // Mint the new pane's id up front so the reply can return it
        // (issue #117); thread it into the action via the defaulted
        // `newPaneID` parameter. `splitPaneAtPath` splits the *focused*
        // pane, so focus the resolved source first; `splitPane` takes the
        // source explicitly.
        let newID = uuid()
        state.workspaces[id: workspaceID]?.setFocus(sourcePaneID)
        replyPaneCreated(reply, newPaneID: newID, workspace: workspace, label: name)

        if let path {
            return .send(.workspaces(.element(
                id: workspaceID,
                action: .splitPaneAtPath(path, label: name, direction: direction ?? .horizontal, newPaneID: newID)
            )))
        }
        return .send(.workspaces(.element(
            id: workspaceID,
            action: .splitPane(direction: direction ?? .horizontal, sourcePaneID: sourcePaneID, label: name, newPaneID: newID)
        )))
    }

    /// Resolve + dispatch a `pane-create` request (issue #117). Resolves
    /// a target *workspace* (via `--target`'s pane, `--workspace`, or the
    /// caller pane) and adds a pane: split off the focused pane when the
    /// workspace already has panes, or create the first pane when it is
    /// empty (the path the old split-only handler had no route for). New
    /// pane UUID minted up front and returned in the reply.
    func handlePaneCreate(
        state: inout State,
        paneID: UUID?,
        path: String?,
        name: String?,
        target: String?,
        workspaceFilter: String?,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let workspaceID: UUID
        var sourcePaneID: UUID?

        // `--workspace` *without* `--target` selects the destination
        // workspace outright — even when the caller forwarded its own
        // NEX_PANE_ID — so a pane in workspace alpha can run
        // `nex pane create --workspace beta` (finding 1). `--target` keeps
        // precedence; the caller's pane is only the anchor when neither
        // `--target` nor `--workspace` is given.
        if target == nil, let workspaceFilter {
            guard let ws = state.resolveWorkspace(workspaceFilter) else {
                reply?.error("workspace not found: \(workspaceFilter)")
                return .none
            }
            workspaceID = ws.id
            sourcePaneID = ws.focusedPaneID ?? ws.panes.first?.id
        } else if target != nil || paneID != nil {
            switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
            case .found(let resolved, let ws):
                workspaceID = ws.id
                sourcePaneID = resolved
            case .error(let error):
                reply?.error(error)
                return .none
            }
        } else {
            reply?.error("pane create requires --target or --workspace when called from outside a Nex pane")
            return .none
        }

        guard let workspace = state.workspaces[id: workspaceID] else {
            reply?.error("workspace not found")
            return .none
        }

        // Mint the new pane's id up front so the reply returns it (issue
        // #117), then thread it into whichever action builds the pane so
        // the acked id actually matches the created pane.
        let newID = uuid()
        replyPaneCreated(reply, newPaneID: newID, workspace: workspace, label: name)

        let source = sourcePaneID ?? workspace.focusedPaneID ?? workspace.panes.first?.id

        // Empty workspace: no pane to split off, so lay out the first pane
        // via `createPane`, carrying `--name` (label) and `--path`
        // (workingDirectory) so the pane the reply acked actually has them
        // (finding 2). This is the route the old split-only handler lacked.
        guard let source else {
            return .send(.workspaces(.element(
                id: workspaceID,
                action: .createPane(newPaneID: newID, label: name, workingDirectory: path)
            )))
        }

        // Populated workspace: split the resolved/focused pane, threading
        // `newID` so the new pane gets the acked id. `splitPaneAtPath`
        // splits the focused pane, so focus first.
        state.workspaces[id: workspaceID]?.setFocus(source)
        if let path {
            return .send(.workspaces(.element(
                id: workspaceID,
                action: .splitPaneAtPath(path, label: name, newPaneID: newID)
            )))
        }
        return .send(.workspaces(.element(
            id: workspaceID,
            action: .splitPane(direction: .horizontal, sourcePaneID: source, label: name, newPaneID: newID)
        )))
    }

    /// Resolve + dispatch a `pane-name` request (issue #117). Without
    /// `--target` it renames the caller pane (`NEX_PANE_ID`); with
    /// `--target` it renames any pane (UUID global, label scoped). Replies
    /// `{ok,pane_id,label,workspace_name}`.
    func handlePaneName(
        state: inout State,
        paneID: UUID?,
        target: String?,
        workspaceFilter: String?,
        name: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.error(error)
            return .none
        }

        let newLabel = name.isEmpty ? nil : name
        state.workspaces[id: workspace.id]?.panes[id: resolvedID]?.label = newLabel

        if let reply {
            var payload: [String: Any] = [
                "ok": true,
                "pane_id": resolvedID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "workspace_name": workspace.name
            ]
            if let newLabel { payload["label"] = newLabel }
            reply.sendAndClose(payload)
        }

        return .send(.persistState)
    }

    // MARK: - Sync-input socket handlers (issue #121)

    /// Dispatch `pane-sync (on|off|toggle|status)`. Resolves the
    /// workspace from `workspaceFilter` first, then `NEX_PANE_ID`.
    /// Replies with `{ok:true,active:Bool,excluded:[...]}` on success;
    /// `status` is read-only and never mutates state.
    func handlePaneSync(
        state: State,
        paneID: UUID?,
        workspaceFilter: String?,
        action: String,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        func fail(_ error: String) -> Effect<Action> {
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        let workspace: WorkspaceFeature.State
        if let workspaceFilter {
            guard let ws = state.resolveWorkspace(workspaceFilter) else {
                return fail("workspace not found: \(workspaceFilter)")
            }
            workspace = ws
        } else if let paneID, let ws = state.workspaceContainingPane(paneID) {
            workspace = ws
        } else {
            return fail("pane sync requires --workspace or NEX_PANE_ID")
        }

        let normalized = action.lowercased()
        let nextActive: Bool
        switch normalized {
        case "on":
            nextActive = true
        case "off":
            nextActive = false
        case "toggle":
            nextActive = !workspace.isSyncInputActive
        case "status":
            // Read-only — reply with current snapshot and bail.
            replySyncStatus(reply: reply, workspace: workspace)
            return .none
        default:
            return fail("unknown sync action '\(action)' (valid: on, off, toggle, status)")
        }

        // Reply with the post-change snapshot. Mirrors the read-only
        // status payload so a CLI caller can rely on the same fields
        // regardless of which subcommand they invoked.
        var snapshot = workspace
        snapshot.isSyncInputActive = nextActive
        if !nextActive { snapshot.syncInputExcluded.removeAll() }
        replySyncStatus(reply: reply, workspace: snapshot)

        return .send(.workspaces(.element(
            id: workspace.id,
            action: .setSyncInputActive(nextActive)
        )))
    }

    /// Dispatch `pane-sync exclude|include`. Reuses `resolvePaneTarget`
    /// so target / workspace resolution matches `pane send` etc.
    func handlePaneSyncExclude(
        state: State,
        paneID: UUID?,
        target: String,
        workspaceFilter: String?,
        excluded: Bool,
        reply: SocketServer.ReplyHandle?
    ) -> Effect<Action> {
        let resolvedID: UUID
        let workspace: WorkspaceFeature.State
        switch resolvePaneTarget(state: state, paneID: paneID, target: target, workspaceFilter: workspaceFilter) {
        case .found(let resolved, let ws):
            resolvedID = resolved
            workspace = ws
        case .error(let error):
            reply?.send(["ok": false, "error": error])
            reply?.close()
            return .none
        }

        var snapshot = workspace
        if excluded {
            snapshot.syncInputExcluded.insert(resolvedID)
        } else {
            snapshot.syncInputExcluded.remove(resolvedID)
        }
        replySyncStatus(reply: reply, workspace: snapshot)

        return .send(.workspaces(.element(
            id: workspace.id,
            action: .setSyncInputExcluded(paneID: resolvedID, excluded: excluded)
        )))
    }
}
