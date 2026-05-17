import ComposableArchitecture
import Foundation
import WebKit

/// Process-wide registry of `WebPaneCoordinator` instances, keyed by
/// pane id. Mirrors `SurfaceManager` for terminal panes: the coordinator
/// (and its WKWebView) survives SwiftUI view rebuilds — `WebPaneView`
/// only re-parents an existing WebView into the new container during
/// layout transitions.
///
/// Coordinators are created lazily by `WebPaneView.makeNSView` (or by
/// the reducer when the pane is first opened) and destroyed only via
/// `destroyCoordinator(paneID:)` from the pane-close path.
final class WebPaneStore: Sendable {
    private let lock = NSLock()
    /// nonisolated(unsafe) because access is protected by lock
    private nonisolated(unsafe) var coordinators: [UUID: WebPaneCoordinator] = [:]

    @MainActor
    func coordinator(for paneID: UUID, isPrivate: Bool = false) -> WebPaneCoordinator {
        if let existing = lock.withLock({ coordinators[paneID] }) {
            return existing
        }
        let dataStore: WKWebsiteDataStore = isPrivate
            ? .nonPersistent()
            : .default()
        let coord = WebPaneCoordinator(
            paneID: paneID,
            dataStore: dataStore
        )
        lock.withLock { coordinators[paneID] = coord }
        return coord
    }

    func coordinatorIfExists(for paneID: UUID) -> WebPaneCoordinator? {
        lock.withLock { coordinators[paneID] }
    }

    @MainActor
    func destroyCoordinator(paneID: UUID) {
        _ = lock.withLock { coordinators.removeValue(forKey: paneID) }
    }

    /// Tear down a single tab inside a pane. No-op when the pane's
    /// coordinator hasn't been created yet (the tab's WKWebView was
    /// never built either).
    @MainActor
    func destroyTab(paneID: UUID, tabID: UUID) {
        guard let coordinator = lock.withLock({ coordinators[paneID] }) else { return }
        coordinator.destroyTab(tabID: tabID)
    }

    @MainActor
    func destroyAll() {
        _ = lock.withLock {
            let copy = coordinators
            coordinators.removeAll()
            return copy
        }
    }
}

// MARK: - TCA Dependency

extension WebPaneStore: DependencyKey {
    static let liveValue = WebPaneStore()
    static let testValue = WebPaneStore()
}

extension DependencyValues {
    var webPaneStore: WebPaneStore {
        get { self[WebPaneStore.self] }
        set { self[WebPaneStore.self] = newValue }
    }
}

// MARK: - SwiftUI Environment

import SwiftUI

extension EnvironmentValues {
    @Entry var webPaneStore: WebPaneStore = .liveValue
}
