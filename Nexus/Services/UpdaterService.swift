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
