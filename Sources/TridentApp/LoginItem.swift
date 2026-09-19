import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` for the "Launch at login" toggle.
///
/// Identity note: the system keys this registration to the app's code signature. A
/// bare `xcodebuild` produces an ad-hoc signature that changes every build, which
/// orphans the existing registration (`status` stops reporting `.enabled` and
/// re-registering churns against the stale record). Always build via `./build.sh`,
/// which re-signs with the stable "Trident Dev" identity.
enum LoginItem {

    /// `SMAppService.mainApp.status` is a synchronous call into the service-management
    /// daemon — cheap, but NOT free enough to run at slider-tick rates (the menu
    /// refreshes on every continuous-slider event). Cache it briefly; the status
    /// can't legitimately change sub-second except through our own register call,
    /// which invalidates the cache.
    private static let cacheTTL: TimeInterval = 0.5
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedStatus: (status: SMAppService.Status, at: TimeInterval)?

    private static var status: SMAppService.Status {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedStatus, Date().timeIntervalSinceReferenceDate - cached.at < cacheTTL {
            return cached.status
        }
        let fresh = SMAppService.mainApp.status
        cachedStatus = (fresh, Date().timeIntervalSinceReferenceDate)
        return fresh
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// The registration exists but the user switched it off (or hasn't approved it)
    /// in System Settings ▸ Login Items. `register()` cannot flip it back from here —
    /// only the user can, where `openSettings()` leads.
    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        defer {
            // The registration just changed — drop the cache so the next read reflects it.
            cacheLock.lock()
            cachedStatus = nil
            cacheLock.unlock()
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// System Settings ▸ General ▸ Login Items & Extensions — where the user resolves
    /// an approval-gated or otherwise stuck registration.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
