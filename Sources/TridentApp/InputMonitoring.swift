import AppKit
import IOKit

/// Thin wrapper over the Input Monitoring TCC check (`IOHIDCheckAccess` /
/// `IOHIDRequestAccess`).
///
/// Why it exists: Trident's raw `MultitouchSupport` contact frames travel the
/// IOHID family path, and other consumers of the same private framework
/// (verified on-device on macOS 26.3+) found that frames simply never arrive
/// until the app is granted **Input Monitoring** — a separate TCC switch from
/// Accessibility, which only covers event posting/tapping. Denied, the app
/// shows "Active" while receiving zero frames: the worst kind of failure —
/// total and invisible.
enum InputMonitoring {

    /// Whether the user has explicitly denied Input Monitoring. Only this state
    /// justifies a "Needs Input Monitoring" surface — `.unknown` resolves itself
    /// the first time `requestAccess()` runs at launch.
    ///
    /// `IOHIDCheckAccess` is a synchronous TCC daemon round-trip, so the result is
    /// cached briefly: `update()` reads this on every continuous-slider tick, the
    /// same hot path `LoginItem.isEnabled`'s cache was added for. 0.5 s is short
    /// enough that a grant in Settings is picked up on the next poll anyway.
    static var isDenied: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let (denied, at) = deniedCache,
           Date().timeIntervalSinceReferenceDate - at < deniedCacheTTL {
            return denied
        }
        let denied = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
        deniedCache = (denied, Date().timeIntervalSinceReferenceDate)
        return denied
    }

    private static let deniedCacheTTL: TimeInterval = 0.5
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var deniedCache: (Bool, TimeInterval)?

    /// Ask the system for Input Monitoring. Shows the one-time permission prompt
    /// only when the status is undetermined; a no-op once granted or denied.
    /// Called once at launch — the app's entire function is listening to trackpad
    /// input, so the prompt is expected rather than alarming.
    static func requestAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// System Settings ▸ Privacy & Security ▸ Input Monitoring — where a denial
    /// (or an entry the system never prompted for) is fixed by hand.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
