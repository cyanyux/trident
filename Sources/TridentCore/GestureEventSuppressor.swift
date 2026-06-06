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
//   • Cursor freeze (`gCursorFreeze`): pin the cursor while a *swipe* drives the ⌘Tab
//     HUD, so the swipe's incidental nudge can't move the cursor onto the HUD (whose
//     mouse-hover would otherwise hijack the selection). Active only during a swipe.
//
// Both self-heal: if a gesture's frame stream dies without a closing frame (sleep,
// disconnect, Bluetooth drop), `gLastFrameTime` ages past `gStaleGap` and the next
// event clears the stuck state — so a dead gesture can never wedge input system-wide.

private nonisolated(unsafe) var gSuppressLock = os_unfair_lock()
private nonisolated(unsafe) var gClickActive = false
private nonisolated(unsafe) var gCursorFreeze = false
private nonisolated(unsafe) var gSuppressLeftUntil: CFTimeInterval = 0
private nonisolated(unsafe) var gSuppressRightUntil: CFTimeInterval = 0
/// Last time a touch frame arrived (`noteFrame`). Keeps the self-heal from firing during
/// a live gesture (frames flowing) while letting a dead stream age out.
private nonisolated(unsafe) var gLastFrameTime: CFTimeInterval = 0
/// Where to pin the cursor during a swipe, captured lazily from the first cursor-motion
/// event after the freeze begins — so there is no synchronous CG round-trip on the
/// framework callback (hot) thread.
private nonisolated(unsafe) var gFrozen = CGPoint.zero
private nonisolated(unsafe) var gFrozenValid = false
private nonisolated(unsafe) var gTap: CFMachPort?

/// Frame-gap beyond which a still-"active" gesture is assumed dead and self-cleared.
private let gStaleGap = GestureTuning.staleStreamGap

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    // The system disables a tap that runs too long or is interrupted — re-enable.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        os_unfair_lock_lock(&gSuppressLock)
        let tap = gTap
        os_unfair_lock_unlock(&gSuppressLock)
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let now = CACurrentMediaTime()
    os_unfair_lock_lock(&gSuppressLock)
    // Self-heal: a gesture whose frame stream died without a closing frame would
    // otherwise keep suppressing input forever. Once frames are stale, drop the active
    // state so the event in hand — and everything after — passes normally.
    if (gClickActive || gCursorFreeze), now - gLastFrameTime > gStaleGap {
        gClickActive = false
        gCursorFreeze = false
        gFrozenValid = false
    }
    let clickActive = gClickActive
    let cursorFreeze = gCursorFreeze
    let frozenValid = gFrozenValid
    let frozen = gFrozen
    let leftUntil = gSuppressLeftUntil
    let rightUntil = gSuppressRightUntil
    os_unfair_lock_unlock(&gSuppressLock)

    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        // While a swipe is live, freeze the cursor: pin it where the swipe began and
        // swallow the motion, so the swipe's incidental nudge never reaches the cursor
        // or the HUD. (Warp, not disassociate — disassociation is a no-op for a
        // background agent; the per-event warp keeps the cursor put, modulo a sub-pixel
        // residual on a firm slide.)
        guard cursorFreeze else { return Unmanaged.passUnretained(event) }
        if frozenValid {
            _ = CGWarpMouseCursorPosition(frozen)
        } else {
            // Capture the pin point from the first motion event itself, rather than a
            // synchronous CGEvent location read on the framework callback thread. The
            // cursor has moved at most one event's worth by now — a negligible offset.
            os_unfair_lock_lock(&gSuppressLock)
            if gCursorFreeze, !gFrozenValid {
                gFrozen = event.location
                gFrozenValid = true
            }
            os_unfair_lock_unlock(&gSuppressLock)
        }
        return nil
    case .rightMouseDown, .rightMouseUp:
        // Secondary clicks get a longer tail: a stray two-finger secondary click from an
        // uneven three-finger lift is recognized by the system well *after* the fingers
        // leave (tap-recognition delay), occasionally past the (shorter) left tail.
        return (clickActive || now < rightUntil) ? nil : Unmanaged.passUnretained(event)
    default:  // left clicks
        // Swallow during the gesture and a short tail, so a sloppy lift can't leak a tap.
        return (clickActive || now < leftUntil) ? nil : Unmanaged.passUnretained(event)
    }
}

// MARK: - GestureEventSuppressor

/// While a three-finger gesture is in progress, a system event tap does two things:
/// (1) swallows the native left/right mouse clicks macOS can synthesize from a sloppy
/// tap (so a momentary one/two-finger reading can't leak a tap-to-click or a secondary
/// click alongside the middle click), for the gesture plus a short tail; and (2) while a
/// *swipe* drives the ⌘Tab HUD, freezes the cursor — swallowing cursor-motion events and
/// pinning it where the swipe began — so the swipe can't nudge the cursor onto the HUD,
/// whose mouse-hover would otherwise hijack the app selection. Both self-heal if the
/// touch stream dies mid-gesture, so a dead gesture can never wedge input.
///
/// The tap requires Accessibility permission (already required to post events). If it
/// can't be created, gesture remapping still works; only these guards are off.
final class GestureEventSuppressor: @unchecked Sendable {

    /// How long click suppression lingers after the last finger lifts. Secondary (right)
    /// clicks linger longer: macOS recognizes a stray two-finger secondary click from an
    /// uneven lift well after the fingers leave, occasionally past the left tail.
    private let tail: CFTimeInterval = 0.3
    private let rightTail: CFTimeInterval = 0.6

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    deinit { stop() }

    /// Create the tap and service it on a dedicated run-loop thread. Call on the main
    /// thread. Running the tap off the main run loop means every system-wide left/
    /// right mouse event is filtered on its own thread and never waits on the main
    /// thread being responsive.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(type.rawValue) }
        let mask = bit(.leftMouseDown) | bit(.leftMouseUp) | bit(.rightMouseDown) | bit(.rightMouseUp)
            | bit(.mouseMoved) | bit(.leftMouseDragged) | bit(.rightMouseDragged) | bit(.otherMouseDragged)

        // Session-level tap (Accessibility only — no Input Monitoring needed). A HID-level
        // tap was tried to swallow motion before the cursor moves, but the system moves the
        // cursor directly regardless, so it bought nothing and cost an extra permission.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.runLoopSource = source

        os_unfair_lock_lock(&gSuppressLock)
        gTap = tap
        os_unfair_lock_unlock(&gSuppressLock)

        // The semaphore makes start() return only once the run loop is live, so a
        // later stop() always has a valid run loop to tear down.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let runLoop = CFRunLoopGetCurrent()
            self.tapRunLoop = runLoop
            if let source = self.runLoopSource {
                CFRunLoopAddSource(runLoop, source, .commonModes)
            }
            if let tap = self.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.trident.eventtap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        thread.start()
        ready.wait()
        return true
    }

    /// Remove the tap, stop its thread, and clear any pending suppression. Main thread.
    func stop() {
        os_unfair_lock_lock(&gSuppressLock)
        gClickActive = false
        gCursorFreeze = false
        gFrozenValid = false
        gSuppressLeftUntil = 0
        gSuppressRightUntil = 0
        gTap = nil
        os_unfair_lock_unlock(&gSuppressLock)

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
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
        if !active {
            let now = CACurrentMediaTime()
            gSuppressLeftUntil = now + tail
            gSuppressRightUntil = now + rightTail
        }
        os_unfair_lock_unlock(&gSuppressLock)
    }

    /// Called when a swipe begins/ends. Drives the cursor freeze; the pin point is
    /// captured lazily from the first cursor-motion event (see the callback), so this
    /// never touches CoreGraphics on the hot path. Thread-safe.
    func setCursorFreeze(_ active: Bool) {
        os_unfair_lock_lock(&gSuppressLock)
        gCursorFreeze = active
        if active { gFrozenValid = false }  // re-capture for this swipe
        os_unfair_lock_unlock(&gSuppressLock)
    }
}
