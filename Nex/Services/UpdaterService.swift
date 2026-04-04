import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle's `SPUStandardUpdaterController` as an `ObservableObject`
/// so SwiftUI views can bind to `canCheckForUpdates`.
@MainActor
final class UpdaterViewModel: ObservableObject {
    private var controller: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false

    init(startUpdater: Bool = true) {
        guard startUpdater else { return }
        startController()
    }

    /// Deferred start — call from `.onAppear` when the updater was created
    /// with `startUpdater: false` to avoid Sparkle framework loading during
    /// early app initialization (reduces dyld lock contention).
    func startController() {
        guard controller == nil else { return }
        let ctrl = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller = ctrl

        ctrl.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
