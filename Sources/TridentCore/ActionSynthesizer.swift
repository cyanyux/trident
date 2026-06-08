import CoreGraphics
import Foundation
import QuartzCore
import os

// MARK: - Virtual key codes (ANSI)
private enum Key {
    static let command: CGKeyCode = 0x37
    static let tab: CGKeyCode = 0x30
    static let escape: CGKeyCode = 0x35
}

/// Turns `GestureAction`s into posted CGEvents.
///
/// Every action runs on a serial `eventQueue`, off the framework callback thread,
/// so the hot path never blocks on event posting. The app-switch uses a *held* ⌘:
/// Command is pressed on `.swipeBegin` and not released until `.swipeCommit` /
/// `.cancel`. Holding it as a real key-down (not just a flag on each Tab) is what
/// keeps the system switcher session alive between steps and lets a swipe scrub
/// through more than two apps. A quick swipe releases ⌘ within tens of
/// milliseconds, before macOS draws the switcher HUD — so fast gestures feel like
/// an instant, HUD-less switch.
final class ActionSynthesizer: @unchecked Sendable {

    private let log = Logger(subsystem: "com.trident.Trident", category: "ActionSynthesizer")
    private let eventQueue = DispatchQueue(label: "com.trident.events", qos: .userInteractive)

    // Keyboard chords combine with the session's modifier state so the switcher
    // sees ⌘ as held; the mouse click stays on a private state to avoid disturbing
    // real input.
    private let keyboardSource = CGEventSource(stateID: .combinedSessionState)
    private let mouseSource = CGEventSource(stateID: .privateState)

    /// Whether ⌘ is currently held. Touched only on `eventQueue`.
    private var commandHeld = false

    // Watchdog: a held ⌘ must never wedge the keyboard. While ⌘ is down we expect a
    // steady touch-frame stream (the gesture is alive — even just resting fingers).
    // If frames stop arriving — a Bluetooth trackpad drops, the device disconnects,
    // the Mac sleeps mid-swipe — this timer force-releases ⌘ so it can't stay stuck
    // system-wide. Detecting on the *frame* gap (not the swipe-step gap) is what lets
    // a long resting hold keep ⌘ down while still recovering from a dead stream.
    private var watchdog: DispatchSourceTimer?
    private let watchdogInterval: CFTimeInterval = 0.25
    // A live gesture — even fingers resting to read the HUD — delivers frames far more
    // often than this, so it only trips on a real stall. Shared with the recognizer and
    // suppressor via GestureTuning.staleStreamGap so all three agree on "stalled".
    private let staleFrameThreshold = GestureTuning.staleStreamGap
    private let lastFrameTime = OSAllocatedUnfairLock<CFTimeInterval>(initialState: 0)

    /// Pause after pressing ⌘ before the first Tab can post. Posted back-to-back with
    /// zero gap, the WindowServer can process Tab before the ⌘Tab session is armed —
    /// the Tab then leaks to the front app and no switch happens. ~12 ms is below
    /// perception but reliably orders the two (mirrors the middle-click down→up gap).
    private let commandSettleMicros: UInt32 = 12_000

    init() {
        // The default local-events suppression interval (0.25 s) drops synthetic
        // keystrokes posted in quick succession from the same source — exactly a fast
        // HUD scrub (several ⌘Tab pairs inside 250 ms) — making it skip steps and land
        // on the wrong app. Zero it so every step lands.
        keyboardSource?.localEventsSuppressionInterval = 0
        if keyboardSource == nil || mouseSource == nil {
            // Events still post against the default source, but the tuning above is lost;
            // surface it rather than failing silently.
            log.error("CGEventSource creation failed; synthetic event tuning unavailable")
        }
    }

    /// Record that a touch frame arrived. Called per frame on the framework callback
    /// thread; lets the watchdog tell a resting gesture (frames still flowing) from a
    /// dead device whose stream has stopped.
    func noteFrame() {
        lastFrameTime.withLock { $0 = CACurrentMediaTime() }
    }

    func handle(_ action: GestureAction) {
        eventQueue.async { [weak self] in self?.perform(action) }
    }

    /// Release ⌘ if it is held. Call on engine stop so ⌘ can never get stuck.
    func releaseAll() {
        eventQueue.async { [weak self] in self?.releaseCommand() }
    }

    /// Release ⌘ and block until the key-up has posted. Used on engine teardown: a serial
    /// `sync` runs after every action already queued (so a release can't race ahead of an
    /// in-flight `.swipeBegin`), and being synchronous guarantees the key-up reaches the
    /// system before the process can exit — so app termination can't leave ⌘ stuck.
    func releaseAllAndWait() {
        eventQueue.sync { releaseCommand() }
    }

    // MARK: - eventQueue only

    private func perform(_ action: GestureAction) {
        switch action {
        case .middleClick:
            postMiddleClick()
        case .swipeBegin:
            pressCommand()
        case .swipeStep(let direction):
            tapTab(backward: direction == .backward)
        case .swipeCommit:
            releaseCommand()
        case .cancel:
            cancelSwitch()
        }
    }

    private func postMiddleClick() {
        // Don't fire a click while the switcher is open (shouldn't happen, but
        // keeps the two paths from colliding).
        guard !commandHeld else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        postMouse(.otherMouseDown, at: location)
        usleep(10_000)  // 10 ms so the down/up register as a discrete click
        postMouse(.otherMouseUp, at: location)
    }

    private func postMouse(_ type: CGEventType, at location: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: mouseSource,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func pressCommand() {
        guard !commandHeld else { return }
        // Mark ⌘ held only once the key-down actually posts. If event creation fails,
        // leaving the flag false keeps tapTab/releaseCommand correctly no-op rather than
        // leaking a bare Tab to the front app under a phantom-held ⌘.
        guard postKey(Key.command, flags: .maskCommand, down: true) else { return }
        commandHeld = true
        startWatchdog()
        // Let the system register ⌘ as held before the first Tab (the next thing queued
        // on this serial queue) posts, so the switch can't be lost to a too-fast chord.
        usleep(commandSettleMicros)
    }

    private func tapTab(backward: Bool) {
        guard commandHeld else { return }
        var flags: CGEventFlags = .maskCommand
        if backward { flags.insert(.maskShift) }
        postChord(Key.tab, flags: flags)
    }

    private func releaseCommand() {
        stopWatchdog()
        guard commandHeld else { return }
        commandHeld = false
        postKey(Key.command, flags: [], down: false)
    }

    /// Post a single key event. Returns whether it was created and posted, so a caller
    /// can keep its state in sync with what actually reached the system.
    @discardableResult
    private func postKey(_ key: CGKeyCode, flags: CGEventFlags, down: Bool) -> Bool {
        guard let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: key, keyDown: down) else {
            return false
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Post a key down then up (a discrete keypress) carrying the given modifier flags.
    private func postChord(_ key: CGKeyCode, flags: CGEventFlags) {
        postKey(key, flags: flags, down: true)
        postKey(key, flags: flags, down: false)
    }

    /// Abort the switch without committing. Once the HUD is up, simply releasing ⌘
    /// *activates* the highlighted app — so a cancel must press Escape first (while ⌘
    /// is still held) to dismiss the switcher, leaving the original app frontmost, then
    /// release ⌘. Without the Escape, a 4-finger "cancel" would do the opposite of
    /// cancelling and switch to whatever was highlighted.
    private func cancelSwitch() {
        // Dismiss the HUD with Escape while ⌘ is still held (a plain ⌘ release would
        // *activate* the highlighted app), then release ⌘ — net effect: no switch.
        if commandHeld { postChord(Key.escape, flags: .maskCommand) }
        releaseCommand()
    }

    // MARK: - Watchdog (eventQueue only)

    private func startWatchdog() {
        stopWatchdog()
        lastFrameTime.withLock { $0 = CACurrentMediaTime() }   // seed so a stale read can't fire instantly
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.commandHeld else { return }
            let last = self.lastFrameTime.withLock { $0 }
            if CACurrentMediaTime() - last > self.staleFrameThreshold {
                // Frames stopped mid-switch (sleep, disconnect, Bluetooth drop). Abandon
                // via Escape — a plain ⌘ release here would silently commit whatever app
                // the now-dead HUD had highlighted.
                self.cancelSwitch()
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
