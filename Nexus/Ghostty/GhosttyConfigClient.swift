import AppKit
import ComposableArchitecture
import SwiftUI

/// Read-only access to ghostty config values.
/// Use `@Dependency(\.ghosttyConfig)` in reducers or `@Environment(\.ghosttyConfig)` in views.
///
/// Populated once after `GhosttyApp.shared.start()` via `GhosttyConfigClient.load()`.
struct GhosttyConfigClient: @unchecked Sendable {
    var backgroundOpacity: Double = 1.0
    var backgroundColor: NSColor = .windowBackgroundColor

    /// Build from the live ghostty config. Call on main actor after `GhosttyApp.shared.start()`.
    @MainActor
    static func load() -> GhosttyConfigClient {
        guard let config = GhosttyApp.shared.config else { return GhosttyConfigClient() }
        return GhosttyConfigClient(
            backgroundOpacity: config.backgroundOpacity,
            backgroundColor: config.backgroundColor
        )
    }
}

// MARK: - TCA Dependency

extension GhosttyConfigClient: DependencyKey {
    /// Populated by NexusApp after ghostty starts. Before that, returns defaults.
    nonisolated(unsafe) static var liveValue = GhosttyConfigClient()
    static let testValue = GhosttyConfigClient()
}

extension DependencyValues {
    var ghosttyConfig: GhosttyConfigClient {
        get { self[GhosttyConfigClient.self] }
        set { self[GhosttyConfigClient.self] = newValue }
    }
}

extension EnvironmentValues {
    @Entry var ghosttyConfig: GhosttyConfigClient = .init()
}
