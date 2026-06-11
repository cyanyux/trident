import Foundation

/// A user-visible action Trident performed — used by the app layer for optional
/// feedback (e.g. haptics).
public enum TridentAction: Sendable {
    case middleClick
    case appSwitchStep
}

/// The public entry point to Trident's gesture pipeline.
///
/// Wires the device monitor → recognizer → synthesizer and exposes a tiny
/// lifecycle the app target drives from the menu bar and Accessibility state.
/// One instance lives for the lifetime of the app.
public final class TridentEngine: @unchecked Sendable {

    private let monitor = DeviceMonitor()
    private let recognizer = GestureRecognizer()
    private let synthesizer = ActionSynthesizer()
    private let suppressor = GestureEventSuppressor()

    /// Invoked on the callback thread after a user-visible action is performed.
    /// The app layer uses this for optional haptic feedback.
    public var onActionPerformed: ((TridentAction) -> Void)?

    public init() {
        // Recognizer emits intents; synthesizer turns them into events. Both
        // closures are set once here, before any frame can arrive.
        recognizer.onAction = { [synthesizer, suppressor, weak self] action in
            synthesizer.handle(action)
            switch action {
            case .middleClick:
                self?.onActionPerformed?(.middleClick)
            case .swipeBegin:
                // Freeze the cursor for the duration of the switch so the swipe can't
                // nudge it onto the ⌘Tab HUD, whose hover would hijack the selection.
                suppressor.setCursorFreeze(true)
            case .swipeStep:
                self?.onActionPerformed?(.appSwitchStep)
            case .swipeCommit, .cancel:
                suppressor.setCursorFreeze(false)
            }
        }
        // While three fingers are down (and briefly after), block the native
        // left/right clicks an uneven tap could otherwise leak.
        recognizer.onGestureActiveChanged = { [suppressor] active in
            suppressor.setGestureActive(active)
        }
        monitor.onTouches = { [recognizer, synthesizer, suppressor] touches, count, timestamp, widthMM, heightMM in
            // Heartbeat for the synthesizer's stuck-⌘ watchdog and the suppressor's
            // stuck-suppression self-heal: held state is only safe while frames arrive.
            synthesizer.noteFrame()
            suppressor.noteFrame()
            recognizer.process(touches, count: count, timestamp: timestamp,
                               widthMM: widthMM, heightMM: heightMM)
        }
    }

    /// Start reading the trackpad. Returns `false` if no multitouch device exists.
    /// Must be called on the main thread (the suppressor taps the main run loop).
    @discardableResult
    public func start() -> Bool {
        // A previous run may have stopped mid-gesture; clear any stale phase before
        // frames start flowing again. Re-arming the synthesizer first (its queue is
        // serial) guarantees no action from the new run can land behind the gate that
        // stop() closed.
        synthesizer.prepare()
        recognizer.resetState()
        let started = monitor.start()
        suppressor.start()
        return started
    }

    /// Stop reading the trackpad, remove the event tap, and release any held modifier.
    public func stop() {
        // Stop frame production FIRST. `monitor.stop()` clears `gEnabled` under the callback's
        // own lock, so no further frame can drive the recognizer to emit a fresh `.swipeBegin`
        // — which would otherwise enqueue a ⌘ key-DOWN *after* our release and leave ⌘ stuck.
        // (Releasing first, the old order, lost that race: an in-flight frame could re-press ⌘
        // behind the release. Order doesn't change whether the key-up lands on a revoke — that
        // is gated by TCC, not by stopping the monitor — so nothing is lost by going last.)
        monitor.stop()
        // Now release ⌘ and BLOCK until the key-up has actually posted. Synchronous matters on
        // app termination: an async release can be abandoned when the process exits, leaving ⌘
        // held system-wide. The drain also flushes any action an in-flight frame enqueued just
        // before `monitor.stop()` took hold, so the release is the last word.
        synthesizer.releaseAllAndWait()
        suppressor.stop()
    }

    /// Whether the set of attached trackpads differs from what the engine is reading
    /// (one connected or dropped since `start()`). Reconcile by restarting the engine.
    public func deviceListChanged() -> Bool {
        monitor.deviceListChanged()
    }

    /// Horizontal travel, in millimetres, required per app-switch step. Physical
    /// distance, so the feel is identical on any size of trackpad.
    public func setSwipeDistance(_ mm: Float) {
        recognizer.setSwipeDistance(mm)
    }

    /// Enable/disable three-finger tap → middle click.
    public func setMiddleClickEnabled(_ enabled: Bool) {
        recognizer.setMiddleClickEnabled(enabled)
    }

    /// Enable/disable three-finger swipe → app switch.
    public func setAppSwitchEnabled(_ enabled: Bool) {
        recognizer.setAppSwitchEnabled(enabled)
    }

    /// Palm-rejection strength: `edgeBandMM` is the ignored edge band in millimetres
    /// in from the rim, `maxSize` the contact-size cap above which a contact is
    /// treated as a palm.
    public func setPalmRejection(edgeBandMM: Float, maxSize: Float) {
        recognizer.setPalmRejection(edgeBandMM: edgeBandMM, maxSize: maxSize)
    }
}
