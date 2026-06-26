import CoreGraphics
import Foundation
import QuartzCore
import os

// MARK: - Shared suppression state
//
// The CGEventTap callback is a `@convention(c)` function and cannot capture context,
// so the suppression state lives in globals guarded by an `os_unfair_lock`. It is
// written from the framework callback thread (via the recognizer) and read from the
// event-tap thread.
//
// Two independent concerns:
//   • Click suppression (`gClickActive` + the per-button tails): swallow the native
//     left/right clicks macOS can synthesize from a sloppy three-finger tap, for the
//     gesture plus a short tail. Active for the whole gesture (tracking included).
//   • Cursor freeze (`gCursorFreeze`): while a *swipe* drives the ⌘Tab HUD, SWALLOW the
//     cursor-motion events (return nil) so the HUD never gets the mouse-hover trigger that
//     would otherwise hijack its selection to the app under the cursor. Active only during a
//     swipe. (The cursor sprite still drifts a little — the OS moves it directly below this
//     tap — but that is cosmetic; denying the HUD the motion event is what holds the selection.)
//
// Both self-heal: if a gesture's frame stream dies without a closing frame (sleep,
// disconnect, Bluetooth drop), `gLastFrameTime` ages past `gStaleGap` and the idle
// timer (or the next event) clears the stuck state — so a dead gesture can never wedge
// input system-wide.

private nonisolated(unsafe) var gSuppressLock = os_unfair_lock()
private nonisolated(unsafe) var gClickActive = false
private nonisolated(unsafe) var gCursorFreeze = false
private nonisolated(unsafe) var gSuppressLeftUntil: CFTimeInterval = 0
private nonisolated(unsafe) var gSuppressRightUntil: CFTimeInterval = 0
/// Last time a touch frame arrived (`noteFrame`). Keeps the self-heal from firing during
/// a live gesture (frames flowing) while letting a dead stream age out.
private nonisolated(unsafe) var gLastFrameTime: CFTimeInterval = 0
/// Whether the gesture currently (or just) active ever entered a swipe. Drives the
/// tail length at gesture end: the long tails exist to absorb the left/right clicks
/// macOS can synthesize from a sloppy *tap-like* lift, but fingers that have
/// travelled (a swipe) don't qualify as a tap to the system — there a long tail only
/// eats the user's own intentional click right after switching apps. Guarded by
/// `gSuppressLock`.
private nonisolated(unsafe) var gWasSwipe = false
private nonisolated(unsafe) var gTap: CFMachPort?
/// Whether the tap is currently enabled. The tap is enabled ONLY while a gesture needs
/// suppression (plus a short tail), and disabled the rest of the time — so when the user
/// is not mid-gesture (e.g. in Settings revoking Accessibility) there is NO active tap in
/// the system-wide input path that could wedge the WindowServer. Guarded by `gSuppressLock`.
private nonisolated(unsafe) var gTapEnabled = false

/// Frame-gap beyond which a still-"active" gesture is assumed dead and self-cleared.
private let gStaleGap = GestureTuning.staleStreamGap

/// Last time we re-enabled the tap after a `.tapDisabledByTimeout`. Lets the callback spot a
/// re-enable that didn't "stick" (was force-disabled again almost immediately) — the signature
/// of the system fighting us rather than a one-off callback overrun. Guarded by `gSuppressLock`.
private nonisolated(unsafe) var gLastTimeoutReenable: CFTimeInterval = 0
/// If a post-timeout re-enable is undone faster than this, treat it as a forced disable (not an
/// overrun) and stop re-enabling — so timeout recovery can never degenerate into the sustained
/// WindowServer re-enable fight that caused the original reboot-level freeze.
private let gTimeoutRefightWindow: CFTimeInterval = 0.5

/// Drop the "active suppression" pair. CALLER MUST HOLD `gSuppressLock`. Single-sources the reset the
/// two self-heal sites (the callback below + `tick()`) and `stop()` all perform when a gesture is done
/// or its stream died — a stale field here is exactly how suppression wedges, so keeping the set in one
/// place stops the copies from drifting.
private func clearActiveSuppressionLocked() {
    gClickActive = false
    gCursorFreeze = false
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByUserInput {
        // The system disabled the tap on user-input grounds — this is what we observe when
        // Accessibility is REVOKED while the tap is live. Do NOT re-enable: re-enabling a tap
        // the system is tearing down on a permission loss pins this synchronous, system-wide
        // tap "on" while the WindowServer blocks behind it, hard-freezing all input (the
        // original reboot-level freeze bug). Just sync our flag to reality; the next gesture's
        // `enableTap()` brings it back if permission returns.
        os_unfair_lock_lock(&gSuppressLock)
        gTapEnabled = false
        os_unfair_lock_unlock(&gSuppressLock)
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout {
        // A callback overran its time budget — recoverable, and DISTINCT from a revoke (which
        // arrives as .tapDisabledByUserInput, above). Conflating the two and never re-enabling
        // meant a single mid-swipe timeout killed cursor-freeze + click-suppression for the
        // rest of that gesture (motion events stop being swallowed, so the ⌘Tab HUD gets the
        // hover-trigger event and hijacks its selection; a sloppy lift could leak a click).
        // Re-enable so the gesture is protected again — but only while a gesture
        // genuinely still needs it (active + fresh frames), so a timeout fired as the gesture
        // ends can't strand the tap on, and a dead stream is left for the self-heal to clear.
        //
        // This rests on one assumption: a revoke is delivered as .tapDisabledByUserInput, never
        // as a timeout. It almost certainly holds (conventional CGEventTap behaviour), but it's
        // the safety-critical invariant of this subsystem — frames keep flowing from
        // MultitouchSupport after a revoke, so `stillNeeded` would stay true through one. So
        // don't rely on it alone: the original reboot-level freeze was the *sustained* re-enable
        // fight, not one transient enable. If our last re-enable was force-disabled again within
        // `gTimeoutRefightWindow` (it didn't "stick" — exactly how a revoke-as-timeout would
        // look), refuse to re-enable. A genuine one-off overrun re-enables and sticks; a forced
        // disable trips the guard after a single enable and the tap stays dead. The freeze loop
        // cannot form regardless of which reason code a revoke surfaces as.
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&gSuppressLock)
        let stillNeeded = (gClickActive || gCursorFreeze) && (now - gLastFrameTime <= gStaleGap)
        let refighting = (now - gLastTimeoutReenable) < gTimeoutRefightWindow
        let willReenable = stillNeeded && !refighting
        gTapEnabled = willReenable
        if willReenable { gLastTimeoutReenable = now }
        let tap = gTap
        os_unfair_lock_unlock(&gSuppressLock)
        if willReenable, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let now = CACurrentMediaTime()
    os_unfair_lock_lock(&gSuppressLock)
    // Self-heal: a gesture whose frame stream died without a closing frame would
    // otherwise keep suppressing input. Once frames are stale, drop the active state so
    // the event in hand — and everything after — passes normally.
    if (gClickActive || gCursorFreeze), now - gLastFrameTime > gStaleGap {
        clearActiveSuppressionLocked()
    }
    let clickActive = gClickActive
    let cursorFreeze = gCursorFreeze   // read after the self-heal above, so a stale gesture reads false
    let leftUntil = gSuppressLeftUntil
    let rightUntil = gSuppressRightUntil
    os_unfair_lock_unlock(&gSuppressLock)

    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        // While a swipe drives the ⌘Tab HUD, SWALLOW the motion event (return nil). The HUD's
        // hover-select is TRIGGERED by a mouse-motion event ARRIVING — it then reads the live
        // (OS-moved) cursor position to pick the app — so consuming the event is what prevents the
        // hijack: with no event delivered, the HUD never re-evaluates which app is under the cursor.
        // Rewriting the event's `location` does NOT work (the HUD ignores it and reads the sprite,
        // which the OS has already moved directly below this tap); 1.0.2 tried exactly that — pinned
        // `location` and passed the event through — and the HUD still jumped to the app under the
        // cursor. Swallowing is what the original working build did, and what holds the selection.
        // See the trident-cmdtab-hud-cursor-hover memory.
        //
        // The cursor SPRITE still drifts a little during the swipe (the OS moves it directly, below
        // this tap) — that is a COSMETIC residual the user accepted, NOT a correctness issue: the
        // swallow holds the HUD regardless of where the sprite sits.
        //
        // RULE D — DO NOT pin that sprite with a synchronous cursor/graphics round-trip on THIS
        // thread. This is an ACTIVE head-insert `.cgSessionEventTap`: the WindowServer BLOCKS on this
        // callback for every mouse event until it returns. The original froze the cursor with a
        // synchronous `CGWarpMouseCursorPosition` HERE — a CGS round-trip into the cursor subsystem
        // that is itself blocked behind this very callback during a native four-finger Spaces /
        // Mission-Control transition, so the two wedged into a reboot-level, system-wide input freeze.
        // (Ordinary 3-finger swipes ran the identical warp but rarely coincide with a system
        // transition, so it returned fast — which is why only four-finger swipes froze.) Forbidden
        // class: CGWarp*, CGAssociate*, CGDisplay*, a cursor-reading `CGEvent(source:)`. (An async
        // off-thread warp is RULE-D-safe but was removed — it was defeated through the very Spaces
        // transition it targeted and bought too little cosmetic value for its race surface.)
        // (Re-enabling the tap PORT via `CGEvent.tapEnable` on the `.tapDisabledByTimeout` path above
        // is a different, sanctioned thing — a trivial enable-bit toggle, not a subsystem round-trip.)
        return cursorFreeze ? nil : Unmanaged.passUnretained(event)
    case .rightMouseDown, .rightMouseUp:
        // Secondary clicks get a longer tail: a stray two-finger secondary click from an
        // uneven three-finger lift is recognized by the system well *after* the fingers
        // leave (tap-recognition delay), occasionally past the (shorter) left tail.
        return (clickActive || now < rightUntil) ? nil : Unmanaged.passUnretained(event)
    case .leftMouseDown, .leftMouseUp:
        // Swallow during the gesture and a short tail, so a sloppy lift can't leak a tap.
        return (clickActive || now < leftUntil) ? nil : Unmanaged.passUnretained(event)
    default:
        // Defensive catch-all: every type in the mask is handled by a case above (the four
        // motion types — including .otherMouseDragged — by the first case, the clicks by the
        // two click cases), so nothing should actually reach here. Pass through unchanged.
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - GestureEventSuppressor

/// A system event tap that — **only while a three-finger gesture needs it** — (1) swallows
/// the native left/right mouse clicks macOS can synthesize from a sloppy tap, and (2) during
/// a *swipe* swallows the cursor-motion events (returns nil) so the ⌘Tab HUD never gets the
/// mouse-hover trigger that would hijack its selection to the app under the cursor. (The cursor
/// sprite still drifts a little — the OS moves it directly, below this tap — but that is
/// cosmetic; denying the HUD the motion event is what holds the selection.)
///
/// **The tap is enabled on demand and disabled when idle.** An always-on session tap is a
/// synchronous, system-wide dependency: if this process can't service it — which is what
/// happens when Accessibility is revoked while it's live — the WindowServer blocks behind it
/// and the whole Mac freezes. By keeping the tap enabled only for the brief life of a gesture
/// (plus a short tail) and disabled otherwise, there is simply no active tap in the input path
/// the rest of the time (including while the user is in Settings toggling permission), so that
/// freeze cannot arise. A dead gesture also self-heals via the idle timer.
///
/// The tap requires Accessibility permission (already required to post events). If it can't be
/// created, gesture remapping still works; only these guards are off.
final class GestureEventSuppressor: @unchecked Sendable {

    private let log = Logger(subsystem: "com.trident.Trident", category: "Suppressor")

    /// How long click suppression lingers after the last finger lifts. Secondary (right)
    /// clicks linger longer: macOS recognizes a stray two-finger secondary click from an
    /// uneven lift well after the fingers leave, occasionally past the left tail.
    private let tail: CFTimeInterval = 0.3
    private let rightTail: CFTimeInterval = 0.6
    /// Tail after a gesture that swiped: fingers that travelled can't be recognized as a
    /// tap by the system, so a stray synthesized click is unlikely — and a user often
    /// clicks deliberately right after switching apps. Keep just enough to cover the lift.
    private let swipeTail: CFTimeInterval = 0.1

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    /// Serializes every `CGEvent.tapEnable` call (gesture-driven enable + idle-driven
    /// disable) onto one queue, so the tap's enabled state can never be raced. Also hosts
    /// the control timer.
    private let controlQueue = DispatchQueue(label: "com.trident.suppressor.control")
    /// Armed only while a gesture (or its tail) is active: it disables the tap once idle and
    /// self-heals a dead gesture, then stops itself. So a quiescent Trident has ZERO periodic
    /// wakeups — the timer exists only for the sub-second life of a gesture.
    private var controlTimer: DispatchSourceTimer?

    deinit { stop() }

    /// Create the tap (left **disabled**) and service it on a dedicated run-loop thread,
    /// plus start the idle timer that disables it when no gesture needs it. Call on the
    /// main thread. Running the tap off the main run loop means events are filtered on
    /// their own thread and never wait on the main thread being responsive.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(type.rawValue) }
        let mask = bit(.leftMouseDown) | bit(.leftMouseUp) | bit(.rightMouseDown) | bit(.rightMouseUp)
            | bit(.mouseMoved) | bit(.leftMouseDragged) | bit(.rightMouseDragged) | bit(.otherMouseDragged)

        // Session-level tap (Accessibility only — no Input Monitoring needed). A HID-level tap was
        // tried to swallow motion before the cursor moves, but the system moved the cursor directly
        // regardless, so it bought nothing and cost an extra permission. The cursor freeze instead
        // SWALLOWS the motion events on this session tap (return nil; see the .mouseMoved case), which
        // denies the ⌘Tab HUD its hover trigger. Do NOT "fix" that into a synchronous CGWarp to pin
        // the sprite — that is exactly the four-finger Spaces deadlock RULE D forbids (see that case).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            log.error("tapCreate failed — click suppression and cursor freeze are off")
            return false
        }
        // tapCreate returns the tap ENABLED; we want it strictly on-demand. Disable it NOW,
        // before the servicing thread starts — otherwise it would sit always-on (an unscoped,
        // system-wide active tap) until the first gesture completes, re-exposing the
        // revoke-while-idle freeze for anyone who revokes before gesturing.
        CGEvent.tapEnable(tap: tap, enable: false)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.runLoopSource = source

        os_unfair_lock_lock(&gSuppressLock)
        gTap = tap
        gTapEnabled = false
        os_unfair_lock_unlock(&gSuppressLock)

        // The semaphore makes start() return only once the run loop is live, so a later
        // stop() always has a valid run loop to tear down. The tap source stays registered
        // (keeping the run loop alive) even while the tap is disabled.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let runLoop = CFRunLoopGetCurrent()
            self.tapRunLoop = runLoop
            if let source = self.runLoopSource {
                CFRunLoopAddSource(runLoop, source, .commonModes)
            }
            // Tap starts DISABLED — enabled on demand by enableTap() when a gesture needs it.
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.trident.eventtap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        thread.start()
        ready.wait()
        // No periodic timer while idle — the control timer is armed only while a gesture (or
        // its tail) is active (see enableTap), so a quiescent Trident has zero wakeups.
        return true
    }

    /// Remove the tap, stop its thread and idle timer, and clear any pending suppression.
    /// Main thread.
    func stop() {
        controlQueue.sync { disarmControlTimer() }

        os_unfair_lock_lock(&gSuppressLock)
        clearActiveSuppressionLocked()
        gWasSwipe = false
        gSuppressLeftUntil = 0
        gSuppressRightUntil = 0
        gTapEnabled = false
        gTap = nil
        os_unfair_lock_unlock(&gSuppressLock)

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)   // drop it from the WindowServer's event chain
        }
        if let source = runLoopSource, let runLoop = tapRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        // Wake the dedicated run loop so CFRunLoopRun() returns and the thread exits.
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
        }

        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
    }

    /// Record that a touch frame arrived. Called per frame on the framework callback
    /// thread; keeps the self-heal from firing during a live gesture while letting a
    /// dead stream age out. Thread-safe.
    func noteFrame() {
        os_unfair_lock_lock(&gSuppressLock)
        gLastFrameTime = CACurrentMediaTime()
        os_unfair_lock_unlock(&gSuppressLock)
    }

    /// Called by the recognizer when a three-finger gesture starts/ends (any phase).
    /// Drives click suppression. Thread-safe.
    func setGestureActive(_ active: Bool) {
        os_unfair_lock_lock(&gSuppressLock)
        gClickActive = active
        if active {
            gWasSwipe = false   // a fresh gesture starts tap-like; setCursorFreeze marks a swipe
        } else {
            let now = CACurrentMediaTime()
            // Swipes get a much shorter tail than tap-like gestures (see gWasSwipe).
            gSuppressLeftUntil = now + (gWasSwipe ? swipeTail : tail)
            gSuppressRightUntil = now + (gWasSwipe ? swipeTail : rightTail)
        }
        os_unfair_lock_unlock(&gSuppressLock)
        if active { enableTap() }   // ensure the tap is live for the duration of the gesture
    }

    /// Called when a swipe begins/ends. Drives the cursor freeze, which swallows cursor-motion events
    /// while the swipe holds the ⌘Tab HUD (see the callback). Touches no CoreGraphics. Thread-safe.
    func setCursorFreeze(_ active: Bool) {
        os_unfair_lock_lock(&gSuppressLock)
        gCursorFreeze = active
        if active {
            gWasSwipe = true      // this gesture swiped → short tail at gesture end
        }
        os_unfair_lock_unlock(&gSuppressLock)
        if active { enableTap() }
    }

    // MARK: - Tap enable/disable + control timer (serialized on controlQueue)

    /// Enable the tap if it isn't already, and arm the control timer for the gesture's
    /// lifetime. Called from the framework callback thread at gesture start; the work is
    /// hopped onto `controlQueue` so the `tapEnable` never races the timer's disable. A
    /// gesture is detected well before any synthesized click, so the enable lands in time.
    private func enableTap() {
        controlQueue.async { [weak self] in
            os_unfair_lock_lock(&gSuppressLock)
            let tap = gTap
            let was = gTapEnabled
            gTapEnabled = true
            os_unfair_lock_unlock(&gSuppressLock)
            if !was, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            self?.armControlTimer()
        }
    }

    /// Start the control timer if it isn't already running. `controlQueue` only.
    private func armControlTimer() {
        guard controlTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        controlTimer = timer
        timer.resume()
    }

    /// Stop the control timer. `controlQueue` only.
    private func disarmControlTimer() {
        controlTimer?.cancel()
        controlTimer = nil
    }

    /// Control-timer tick (`controlQueue`): self-heal a dead gesture, then — once nothing
    /// needs suppression — disable the tap (out of the system-wide input path) and stop the
    /// timer until the next gesture re-arms it.
    private func tick() {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&gSuppressLock)
        if (gClickActive || gCursorFreeze), now - gLastFrameTime > gStaleGap {
            clearActiveSuppressionLocked()
        }
        let needed = gClickActive || gCursorFreeze || now < gSuppressLeftUntil || now < gSuppressRightUntil
        let tap = gTap
        let was = gTapEnabled
        if !needed { gTapEnabled = false }
        os_unfair_lock_unlock(&gSuppressLock)
        guard !needed else { return }    // still active — keep ticking
        if was, let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        disarmControlTimer()             // idle — stop waking until the next gesture
    }
}
