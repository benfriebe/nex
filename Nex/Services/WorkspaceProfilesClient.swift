import ComposableArchitecture
import Foundation
import os.log

/// Named env-var sets ("workspace profiles") defined in ~/.config/nex/config.
///
/// `liveValue` re-reads and re-parses the config file on each call — the file
/// is tiny, and this keeps newly spawned panes fresh without a file watcher.
/// Live PTYs are unaffected: env is injected only at surface spawn.
struct WorkspaceProfilesClient {
    /// The env dict to inject for a workspace assigned profile `name`: the
    /// profile's parsed vars plus `NEX_PROFILE=<name>`. The marker is always
    /// present — even when the profile has no definitions in the config — so
    /// the assignment is observable from inside the pane.
    var resolveEnv: @Sendable (_ name: String) -> [String: String]
    /// Profile names in order of first appearance (drives the pickers).
    var listProfiles: @Sendable () -> [String]
}

extension WorkspaceProfilesClient: DependencyKey {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.benfriebe.nex",
        category: "WorkspaceProfiles"
    )

    static let liveValue = WorkspaceProfilesClient(
        resolveEnv: { name in
            resolveEnv(name, configPath: KeybindingService.configPath)
        },
        listProfiles: {
            ConfigParser.parseProfiles(fromFile: KeybindingService.configPath).map(\.name)
        }
    )

    /// Path-parameterized core of `liveValue.resolveEnv`, split out so tests
    /// can exercise the `NEX_PROFILE` marker and the undefined-profile path
    /// against a temp config file.
    static func resolveEnv(_ name: String, configPath: String) -> [String: String] {
        let profiles = ConfigParser.parseProfiles(fromFile: configPath)
        var env = profiles.first(where: { $0.name == name })?.env ?? [:]
        if env.isEmpty {
            logger.warning("Workspace profile '\(name)' has no definitions in config")
        }
        // Merged last: a config line spoofing NEX_PROFILE loses to the
        // canonical marker.
        env["NEX_PROFILE"] = name
        return env
    }

    static let testValue = WorkspaceProfilesClient(
        resolveEnv: { name in ["NEX_PROFILE": name, "TEST_PROFILE_VAR": "test-\(name)"] },
        listProfiles: { ["work", "personal"] }
    )
}

extension DependencyValues {
    var workspaceProfiles: WorkspaceProfilesClient {
        get { self[WorkspaceProfilesClient.self] }
        set { self[WorkspaceProfilesClient.self] = newValue }
    }
}
