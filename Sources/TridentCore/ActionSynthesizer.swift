import CoreGraphics
import Foundation
import QuartzCore
import os

// MARK: - Virtual key codes (ANSI)
private enum Key {
    static let command: CGKeyCode = 0x37
    static let tab: CGKeyCode = 0x30
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
    private let staleFrameThreshold: CFTimeInterval = 1.0
    private let lastFrameTime = OSAllocatedUnfairLock<CFTimeInterval>(initialState: 0)

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

    // MARK: - eventQueue only

    private func perform(_ action: GestureAction) {
        switch action {
        case .middleClick:
            postMiddleClick()
        case .swipeBegin:
            pressCommand()
        case .swipeStep(let direction):
            tapTab(backward: direction == .backward)
        case .swipeCommit, .cancel:
            releaseCommand()
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
        commandHeld = true
        startWatchdog()
        if let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: Key.command, keyDown: true) {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    private func tapTab(backward: Bool) {
        guard commandHeld else { return }
        var flags: CGEventFlags = .maskCommand
        if backward { flags.insert(.maskShift) }
        for keyDown in [true, false] {
            if let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: Key.tab, keyDown: keyDown) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func releaseCommand() {
        stopWatchdog()
        guard commandHeld else { return }
        commandHeld = false
        if let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: Key.command, keyDown: false) {
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
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
                self.releaseCommand()
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
