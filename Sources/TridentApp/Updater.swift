import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater.
///
/// `SPUStandardUpdaterController` owns the whole update lifecycle — scheduled
/// background checks (governed by `SUEnableAutomaticChecks` /
/// `SUScheduledCheckInterval` in Info.plist), the user-facing "update available"
/// UI, download, signature verification against `SUPublicEDKey`, and the install +
/// relaunch. We just hold it for the app's lifetime and expose a manual check for
/// the menu item.
///
/// Updates are verified with our EdDSA key (not Apple notarization), so auto-update
/// works on the free, self-signed distribution. Because every release is signed
/// with the same stable identity, the Accessibility grant carries across updates.
@MainActor
final class Updater {

    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` begins the scheduled-check timer immediately.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// User-initiated check ("Check for Updates…"). Always shows UI, even when no
    /// update is found, so the user gets feedback. Sparkle coalesces a click made
    /// while a check is already in flight, so the menu item needs no extra gating.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
