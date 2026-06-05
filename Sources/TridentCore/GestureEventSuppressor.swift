import CoreGraphics
import Foundation
import QuartzCore
import os

// MARK: - Shared suppression state
//
// The CGEventTap callback is a `@convention(c)` function and cannot capture
// context, so the suppression window lives in globals guarded by an
// `os_unfair_lock`. `gGestureActive` is written from the framework callback
// thread (via the recognizer) and read from the event-tap thread; the deadline
// extends suppression briefly past the gesture so an uneven finger-lift can't
// leak a click.

private nonisolated(unsafe) var gSuppressLock = os_unfair_lock()
private nonisolated(unsafe) var gGestureActive = false
private nonisolated(unsafe) var gSuppressUntil: CFTimeInterval = 0
private nonisolated(unsafe) var gTap: CFMachPort?

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    // The system disables a tap that runs too long or is interrupted — re-enable.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        os_unfair_lock_lock(&gSuppressLock)
        let tap = gTap
        os_unfair_lock_unlock(&gSuppressLock)
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    os_unfair_lock_lock(&gSuppressLock)
    let suppress = gGestureActive || CACurrentMediaTime() < gSuppressUntil
    os_unfair_lock_unlock(&gSuppressLock)

    // Swallow native left/right clicks during the window; pass everything else.
    return suppress ? nil : Unmanaged.passUnretained(event)
}

// MARK: - GestureEventSuppressor

/// Suppresses the native left/right mouse clicks that macOS can synthesize from a
/// trackpad tap, but only while a three-finger gesture is in progress (and for a
/// short tail afterwards). This stops a sloppy three-finger tap — where the
/// trackpad momentarily sees one or two fingers — from leaking a tap-to-click or a
/// two-finger secondary (right) click alongside Trident's middle click.
///
/// The tap requires Accessibility permission (already required to post events). If
/// it can't be created, gesture remapping still works; only the leak-guard is off.
final class GestureEventSuppressor: @unchecked Sendable {

    /// How long suppression lingers after the last finger lifts.
    private let tail: CFTimeInterval = 0.3

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
        gGestureActive = false
        gSuppressUntil = 0
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

    /// Called by the recognizer when a three-finger gesture starts/ends. Thread-safe.
    func setGestureActive(_ active: Bool) {
        os_unfair_lock_lock(&gSuppressLock)
        gGestureActive = active
        if !active {
            gSuppressUntil = CACurrentMediaTime() + tail
        }
        os_unfair_lock_unlock(&gSuppressLock)
    }
}
