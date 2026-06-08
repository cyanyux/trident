import ApplicationServices
import CoreGraphics

/// Authoritative runtime check for whether this process currently holds Accessibility
/// permission.
///
/// `AXIsProcessTrusted()` reads a **per-process cache that goes stale on revoke**: after the
/// user turns Accessibility off in System Settings, a still-running process keeps seeing
/// `true` (this is why macOS says "quit and reopen"). The cache *does* update on grant. So:
///   • `AXIsProcessTrusted() == false` is reliable — never granted, or pre-grant.
///   • `AXIsProcessTrusted() == true`  is ambiguous — genuinely trusted, or stale after a revoke.
///
/// To resolve the ambiguous case we probe the **live** TCC state the only reliable way there
/// is: attempt to create an Accessibility-gated event tap. `CGEvent.tapCreate` returns `nil`
/// exactly when the permission is actually missing — a result that cannot come from the stale
/// cache. `tapCreate` returns the tap *enabled*, so the probe immediately disables and
/// invalidates it (never adding a run-loop source); it therefore never services events and
/// never enters the live input path (no relation to the suppressor's tap, and no freeze risk).
enum AccessibilityMonitor {

    /// True iff this process can use the Accessibility APIs right now (post events / tap).
    /// Reflects a live revoke that `AXIsProcessTrusted()` alone would miss.
    static func isTrusted() -> Bool {
        // Cheap, reliable gate: `false` is never a stale lie, and this skips the probe in the
        // common not-yet-granted state.
        guard AXIsProcessTrusted() else { return false }
        // `true` may be stale after a revoke — confirm against the live TCC state.
        return canCreateTap()
    }

    /// Live TCC probe: can we create an Accessibility-gated event tap this instant? Returns
    /// `false` once permission is actually revoked, even while `AXIsProcessTrusted()` still lies.
    private static func canCreateTap() -> Bool {
        let noop: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)
        guard let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // active tap ⇒ gated on Accessibility (matches our real tap)
            eventsOfInterest: mask,
            callback: noop,
            userInfo: nil
        ) else { return false }
        // tapCreate returns the tap ENABLED, and we never add it to a run loop — so disable it
        // immediately (before an event could route to an unserviced tap) and drop it. It never
        // actually filters anything.
        CGEvent.tapEnable(tap: probe, enable: false)
        CFMachPortInvalidate(probe)
        return true
    }
}
