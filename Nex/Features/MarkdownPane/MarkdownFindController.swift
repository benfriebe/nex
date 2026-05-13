import AppKit
import Foundation

/// Routes find-in-page commands from the workspace reducer to the
/// `MarkdownPaneView.Coordinator` that owns the WKWebView for a given
/// pane. Mirrors the role `SurfaceManager` plays for terminal scrollback
/// search, but for markdown panes.
///
/// Coordinators register on `makeNSView` and unregister on
/// `dismantleNSView`. Results from JS land back in the workspace via the
/// `markdownFindResult` notification, which `ContentView` translates to
/// `searchTotalUpdated` / `searchSelectedUpdated` actions.
@MainActor
final class MarkdownFindController {
    static let shared = MarkdownFindController()

    private var coordinators: [UUID: WeakCoordinator] = [:]
    private var lastNeedles: [UUID: String] = [:]

    private init() {}

    func register(paneID: UUID, coordinator: MarkdownPaneView.Coordinator) {
        coordinators[paneID] = WeakCoordinator(value: coordinator)
    }

    func unregister(paneID: UUID) {
        coordinators[paneID] = nil
        lastNeedles[paneID] = nil
    }

    /// Re-run the active find after a content reload (file watcher firing,
    /// font-size change, etc.) blew the marks out of the DOM.
    func reapply(paneID: UUID) {
        guard let needle = lastNeedles[paneID], !needle.isEmpty else { return }
        coordinators[paneID]?.value?.runFindUpdate(needle: needle)
    }

    func update(paneID: UUID, needle: String) {
        lastNeedles[paneID] = needle
        coordinators[paneID]?.value?.runFindUpdate(needle: needle)
    }

    func navigateNext(paneID: UUID) {
        coordinators[paneID]?.value?.runFindNavigate(forward: true)
    }

    func navigatePrevious(paneID: UUID) {
        coordinators[paneID]?.value?.runFindNavigate(forward: false)
    }

    func close(paneID: UUID) {
        lastNeedles[paneID] = nil
        coordinators[paneID]?.value?.runFindClose()
    }

    private struct WeakCoordinator {
        weak var value: MarkdownPaneView.Coordinator?
    }
}

extension Notification.Name {
    /// Fired by `MarkdownPaneView.Coordinator` after the JS find pass
    /// completes. `userInfo`: `paneID: UUID`, `total: Int`, `current: Int`
    /// (`current` is `-1` when there is no active match).
    static let markdownFindResult = Notification.Name("nex.markdownFindResult")
}
