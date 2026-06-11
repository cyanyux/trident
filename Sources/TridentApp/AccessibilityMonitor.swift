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
    ///
    /// The probe must be **inert**: `tapCreate` returns the tap ENABLED, and between the
    /// WindowServer registering it and processing our disable/invalidate there is a window in
    /// which any event matching its mask is routed to a synchronous tap nobody services — the
    /// WindowServer stalls that event until the tap timeout. Masked on `leftMouseDown` (the
    /// old probe), running every poll tick, that window occasionally ate a real click and hung
    /// input for up to a second. So the probe masks only `.null` — an event type that never
    /// flows through the session stream — making it unhittable while keeping the gate: the
    /// Accessibility check on an active tap happens at creation and is independent of the mask
    /// (verified: with permission missing, `tapCreate` returns nil for a `.null`-mask
    /// `.defaultTap` exactly as it does for a `leftMouseDown` one).
    private static func canCreateTap() -> Bool {
        if createAndDropProbe(mask: CGEventMask(1) << CGEventMask(CGEventType.null.rawValue)) {
            return true
        }
        // nil is almost certainly "permission revoked", but guard the one untestable corner —
        // some future OS rejecting the never-firing mask outright — by confirming with the
        // old real-event mask. Untrusted, this creates no tap (tapCreate returns nil), so the
        // fallback never puts a hittable tap in the input path unless the inert probe is
        // genuinely unavailable.
        return createAndDropProbe(mask: CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue))
    }

    private static func createAndDropProbe(mask: CGEventMask) -> Bool {
        let noop: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
        guard let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,    // probe order is irrelevant; stay out of head position
            options: .defaultTap,          // active tap ⇒ gated on Accessibility (matches our real tap)
            eventsOfInterest: mask,
            callback: noop,
            userInfo: nil
        ) else { return false }
        // Never added to a run loop — disable immediately and drop it.
        CGEvent.tapEnable(tap: probe, enable: false)
        CFMachPortInvalidate(probe)
        return true
    }
}
