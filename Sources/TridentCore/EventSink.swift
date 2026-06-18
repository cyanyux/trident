import CoreGraphics
import os

/// The low-level event-posting seam used by `ActionSynthesizer`.
///
/// Production posts real CGEvents to the HID tap (`CGEventSink`); tests inject a recorder
/// that can also simulate CGEvent *creation* failure — the only way posting fails, since
/// `CGEvent.post` itself is fire-and-forget (a dropped *delivery* is invisible in-process).
/// `Sendable` because the synthesizer calls it from its serial event queue.
protocol EventSink: Sendable {
    /// Create + post a keyboard event carrying `flags`. Returns whether the event was created
    /// AND posted — `false` means CGEvent creation failed and nothing reached the system, so the
    /// caller can keep its own state in sync with what actually posted.
    @discardableResult
    func postKey(_ key: CGKeyCode, flags: CGEventFlags, down: Bool) -> Bool

    /// Create + post a middle-button mouse event at `location`.
    func postMouse(_ type: CGEventType, at location: CGPoint)

    /// The current cursor location, or `nil` if it can't be read.
    func cursorLocation() -> CGPoint?
}

/// Production `EventSink`: real CGEvents posted to `.cghidEventTap`.
///
/// `@unchecked Sendable` for the same reason as `ActionSynthesizer` — the CoreGraphics sources
/// are configured once in `init` and thereafter only touched from the synthesizer's serial queue.
final class CGEventSink: EventSink, @unchecked Sendable {

    private let log = Logger(subsystem: "com.trident.Trident", category: "EventSink")

    // Keyboard chords combine with the session's modifier state so the switcher sees ⌘ as held;
    // the mouse click stays on a private state to avoid disturbing real input.
    private let keyboardSource = CGEventSource(stateID: .combinedSessionState)
    private let mouseSource = CGEventSource(stateID: .privateState)

    init() {
        // The default local-events suppression interval (0.25 s) drops synthetic keystrokes posted
        // in quick succession from the same source — exactly a fast HUD scrub (several ⌘Tab pairs
        // inside 250 ms) — making it skip steps and land on the wrong app. Zero it so every step lands.
        keyboardSource?.localEventsSuppressionInterval = 0
        if keyboardSource == nil || mouseSource == nil {
            // Events still post against the default source, but the tuning above is lost;
            // surface it rather than failing silently.
            log.error("CGEventSource creation failed; synthetic event tuning unavailable")
        }
    }

    @discardableResult
    func postKey(_ key: CGKeyCode, flags: CGEventFlags, down: Bool) -> Bool {
        guard let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: key, keyDown: down) else {
            return false
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }

    func postMouse(_ type: CGEventType, at location: CGPoint) {
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

    func cursorLocation() -> CGPoint? {
        // No fallback: a `.zero` default would land a click at the top-left screen corner.
        CGEvent(source: nil)?.location
    }
}
