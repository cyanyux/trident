import ServiceManagement

/// Thin wrapper over `SMAppService` for the "Launch at login" toggle.
///
/// Identity note: the system keys this registration to the app's code signature. A
/// bare `xcodebuild` produces an ad-hoc signature that changes every build, which
/// orphans the existing registration (`status` stops reporting `.enabled` and
/// re-registering churns against the stale record). Always build via `./build.sh`,
/// which re-signs with the stable "Trident Dev" identity.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The registration exists but the user switched it off (or hasn't approved it)
    /// in System Settings ▸ Login Items. `register()` cannot flip it back from here —
    /// only the user can, where `openSettings()` leads.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
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
