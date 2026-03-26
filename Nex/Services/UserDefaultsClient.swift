import ComposableArchitecture
import Foundation

/// Dependency wrapper around UserDefaults. Uses `UserDefaults.standard` in
/// production and an in-memory store during tests so tests never pollute the
/// app's persisted settings.
struct UserDefaultsClient {
    var boolForKey: @Sendable (String) -> Bool
    var doubleForKey: @Sendable (String) -> Double
    var stringForKey: @Sendable (String) -> String?
    var hasKey: @Sendable (String) -> Bool
    var setBool: @Sendable (Bool, String) -> Void
    var setDouble: @Sendable (Double, String) -> Void
    var setString: @Sendable (String, String) -> Void
}

extension UserDefaultsClient: DependencyKey {
    static let liveValue: UserDefaultsClient = {
        // UserDefaults.standard is thread-safe but not Sendable in Swift 6.
        // Use nonisolated(unsafe) to allow capture in @Sendable closures.
        nonisolated(unsafe) let defaults = UserDefaults.standard
        return UserDefaultsClient(
            boolForKey: { defaults.bool(forKey: $0) },
            doubleForKey: { defaults.double(forKey: $0) },
            stringForKey: { defaults.string(forKey: $0) },
            hasKey: { defaults.object(forKey: $0) != nil },
            setBool: { defaults.set($0, forKey: $1) },
            setDouble: { defaults.set($0, forKey: $1) },
            setString: { defaults.set($0, forKey: $1) }
        )
    }()

    static let testValue: UserDefaultsClient = {
        let storage = NSLock()
        nonisolated(unsafe) var dict: [String: Any] = [:]
        return UserDefaultsClient(
            boolForKey: { key in storage.withLock { dict[key] as? Bool ?? false } },
            doubleForKey: { key in storage.withLock { dict[key] as? Double ?? 0 } },
            stringForKey: { key in storage.withLock { dict[key] as? String } },
            hasKey: { key in storage.withLock { dict[key] != nil } },
            setBool: { val, key in storage.withLock { dict[key] = val } },
            setDouble: { val, key in storage.withLock { dict[key] = val } },
            setString: { val, key in storage.withLock { dict[key] = val } }
        )
    }()
}

extension DependencyValues {
    var userDefaults: UserDefaultsClient {
        get { self[UserDefaultsClient.self] }
        set { self[UserDefaultsClient.self] = newValue }
    }
}
