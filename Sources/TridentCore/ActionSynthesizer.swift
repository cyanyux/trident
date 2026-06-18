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

    /// Where a held ⌘ is in its lifecycle — tells the watchdog HOW to recover it if a release post
    /// fails to create. `.inProgress`: no terminal action yet, so recover ONLY on a dead frame
    /// stream (the gesture died) and cancel — never commit a stale highlight. `.committing`: a
    /// `.swipeCommit` ran, so retry the ⌘-up (frame-INDEPENDENT: a commit needn't stop the stream)
    /// and never invert into a cancel. `.cancelling`: an abort ran, so retry dismiss-then-release.
    /// Touched only on `eventQueue`.
    private var heldPhase: HeldPhase = .inProgress
    private enum HeldPhase { case inProgress, committing, cancelling }

    /// Within a `.cancelling` recovery: has the dismiss Escape posted yet? Once it has, retries
    /// re-post ONLY the ⌘-up — they must not re-spam ⌘-Escape at the front app. Reset per gesture in
    /// `pressCommand`. Touched only on `eventQueue`.
    private var hudDismissed = false

    /// Closed by `releaseAllAndWait()` on engine stop, reopened by `prepare()` on the
    /// next start. `monitor.stop()` prevents *future* frames, but a callback already
    /// past its enabled-check can still be mid-flight on the framework thread and
    /// enqueue an action *after* the teardown drain — on app quit, a `.swipeBegin`
    /// landing there would press ⌘ with nothing left to ever release it. With the
    /// gate closed such stragglers are no-ops. Touched only on `eventQueue`.
    private var stopped = false

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

    /// How many times a release re-posts its key, and the gap between attempts (NO trailing gap).
    /// One policy for every release path. `CGEvent.post` confirms an event was *posted*, never that
    /// the WindowServer *delivered* it, so a lone up/Escape can be dropped or coalesced during a
    /// Spaces / switcher animation. Re-posting a few times lowers those odds WITHOUT reading
    /// `flagsState` — the union of every event source AND the user's physical keyboard, whose read
    /// was the clobber regression we removed. 3× at 8 ms keeps the burst well below perception so it
    /// can't lag a commit-then-re-flick. (See `repost` for the post-all vs stop-at-first policy.)
    private let repostCount = 3
    private let repostGapMicros: UInt32 = 8_000

    /// Settle between the dismiss Escape and the ⌘ release. Same-tap events are delivered in order,
    /// so the Escape is already processed before the ⌘-up; this is extra margin against coalescing
    /// during the WindowServer's worst-lag moment (a Spaces / switcher animation), so the up can't
    /// slip ahead of the Escape and *commit* the highlighted app. Well above `commandSettleMicros`
    /// because that lag is real under animation; skipped when no Escape posted (nothing to order
    /// against). A genuinely *dropped* Escape is the residual risk, which no settle fixes.
    private let cancelSettleMicros: UInt32 = 50_000

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

    /// Reopen the gate closed by `releaseAllAndWait()`. The engine calls this on start,
    /// before frame delivery is enabled; queued ahead of any possible action on the
    /// same serial queue, so the new run's first action can't be dropped.
    func prepare() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            // Recover from a prior teardown whose release never posted: `commandHeld` still true, the
            // watchdog already stopped, ⌘ possibly stuck with the HUD up. Dismiss-then-release (best
            // effort — creation may have recovered) so a stuck ⌘ clears the moment we can, THEN force
            // `commandHeld` false so the new run's first `.swipeBegin` can press ⌘ fresh.
            // pressCommand's postKey no-ops while creation is still broken (so this can't
            // double-press), and a ⌘-up clears the flag regardless of stacked downs. Runs on the
            // serial queue ahead of any action, before frames are enabled.
            if self.commandHeld {
                // For a dismiss recovery, a teardown Escape may have been DROPPED at delivery
                // (posted ≠ delivered), so re-dismiss on restart rather than trust the latch
                // (`hudDismissed = false`). Resolve by PHASE (a `.committing` ⌘ completes as a commit
                // with no Escape; otherwise dismiss-then-release), then force `commandHeld` false so
                // the next `.swipeBegin` presses fresh (postKey no-ops while creation is still broken,
                // so this can't double-press).
                self.hudDismissed = false
                self.resolveHeldCommand()
                self.commandHeld = false
            }
        }
    }

    /// Release ⌘ and block until the key-up has posted. Used on engine teardown: a serial
    /// `sync` runs after every action already queued (so a release can't race ahead of an
    /// in-flight `.swipeBegin`), and being synchronous guarantees the key-up reaches the
    /// system before the process can exit — so app termination can't leave ⌘ stuck.
    /// Also closes the gate, so an action a still-mid-flight frame enqueues *after* this
    /// drain is a no-op instead of re-pressing ⌘ behind the final release.
    func releaseAllAndWait() {
        eventQueue.sync {
            stopped = true
            stopWatchdog()
            // Release only a ⌘ WE pressed (commandHeld). An unconditional flush would post ⌘-ups
            // even when the user is physically holding ⌘ at quit — ⌘Q with a Trident window focused,
            // or a ⌘-based toggle hotkey — and clobber their real modifier, the exact clobber class
            // we removed with the flagsState read. commandHeld true here means either a gesture is
            // still live (mid-flight `.inProgress` — teardown interrupting a swipe) OR a terminal
            // release ran but its ⌘-up failed to CREATE. Resolve by PHASE, exactly as the watchdog
            // does (`resolveHeldCommand`): complete a `.committing` ⌘ as a COMMIT (⌘-up only, never
            // inverted into a cancel); dismiss-then-release otherwise so we don't commit a stale
            // highlight. `eventQueue.sync` makes the posts provably reach the system before the
            // process can exit. If creation is still broken here (watchdog already stopped, so no
            // in-session retry), `commandHeld` stays true ON PURPOSE — that lets `prepare()` re-run
            // this recovery and force-clear on the next start, so a restartEngine() recovers; a pure
            // quit is exiting anyway.
            if commandHeld {
                resolveHeldCommand()
            }
        }
    }

    // MARK: - eventQueue only

    private func perform(_ action: GestureAction) {
        guard !stopped else { return }
        switch action {
        case .middleClick:
            postMiddleClick()
        case .swipeBegin:
            pressCommand()
        case .swipeStep(let direction):
            tapTab(backward: direction == .backward)
        case .swipeCommit:
            heldPhase = .committing   // a failed commit release must retry as a commit, not a cancel
            releaseCommand()
        case .cancel:
            heldPhase = .cancelling
            dismissAndRelease()
        }
    }

    private func postMiddleClick() {
        // Don't fire a click while the switcher is open (shouldn't happen, but
        // keeps the two paths from colliding).
        guard !commandHeld else { return }
        // No fallback location: a failed cursor read defaulting to .zero would land the
        // click at the top-left screen corner (the Apple menu) instead of under the cursor.
        guard let location = CGEvent(source: nil)?.location else {
            log.error("middle click skipped: cursor location unavailable")
            return
        }
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
        heldPhase = .inProgress    // until a terminal action; a stream death before then cancels
        hudDismissed = false       // fresh gesture: no dismiss Escape has posted yet
        startWatchdog()
        log.notice("press ⌘ (switch begin)")
        // Let the system register ⌘ as held before the first Tab (the next thing queued
        // on this serial queue) posts, so the switch can't be lost to a too-fast chord.
        usleep(commandSettleMicros)
    }

    private func tapTab(backward: Bool) {
        guard commandHeld else { return }
        var flags: CGEventFlags = .maskCommand
        if backward { flags.insert(.maskShift) }
        postChord(Key.tab, flags: flags)
        // Forensics: one line per emitted step. Distinguishes a recognizer over-step (many
        // lines per gesture) from a single Trident step that the system then auto-repeats
        // under a stuck ⌘ (one line, yet the HUD marches) — the open question for the
        // "highlight runs to the last app" report.
        log.notice("tab step backward=\(backward)")
    }

    private func releaseCommand() {
        guard commandHeld else { return }
        // Re-assert OUR ⌘ key-up (see `repostCount` / `repost`). We never verify against
        // `CGEventSource.flagsState(.combinedSessionState)`: it is the UNION of every session source
        // AND the user's physical keyboard and lags ~200 ms (longer mid Spaces animation), so a
        // re-post driven by it fires stray ⌘-ups that cancel a ⌘ the user is physically holding —
        // the regression we removed. We cannot confirm delivery in-process, only lower the drop
        // odds. Stop the watchdog and clear `commandHeld` ONLY once an up was actually created: if
        // creation fails, leaving both set lets the watchdog retry — and it retries per `heldPhase`
        // (a `.committing` stall re-posts the ⌘-up, never an Escape-cancel).
        let posted = repost(untilSuccess: false) { postKey(Key.command, flags: [], down: false) }
        if posted {
            commandHeld = false
            stopWatchdog()
        }
        log.notice("release ⌘ (posted=\(posted))")
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

    /// Post a key down then up (a discrete keypress) carrying the given modifier flags. Returns
    /// whether the full press registered, so a caller whose correctness depends on it (the cancel
    /// Escape) can react to a failure instead of silently turning a cancel into a commit. If the
    /// down's creation fails we post NOTHING (no orphan up); if the down posts but the up's creation
    /// fails — effectively impossible, it's the same path microseconds later — we retry the up so a
    /// partial chord can never strand the key DOWN.
    @discardableResult
    private func postChord(_ key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard postKey(key, flags: flags, down: true) else { return false }
        return repost(untilSuccess: true) { postKey(key, flags: flags, down: false) }
    }

    /// Re-post an event up to `repostCount` times, `repostGapMicros` apart with NO trailing gap.
    /// `untilSuccess` selects the policy:
    ///  - `false` (⌘-up insurance): post all N even after one succeeds — `CGEvent.post` confirms
    ///    *posted*, never *delivered*, so a lone up can still be dropped/coalesced during a Spaces
    ///    animation and several lower those odds. Extra ⌘-ups are otherwise harmless EXCEPT against
    ///    a ⌘ the user physically holds, so every caller gates on `commandHeld` (release only OUR ⌘).
    ///  - `true` (Escape creation-retry): stop at the first success — we retry only to survive a
    ///    transient CGEvent *creation* failure and must NOT over-post Escape (an extra ⌘-Escape once
    ///    the HUD is gone would reach the front app).
    /// Returns whether any attempt was created+posted. Never reads global modifier state. `eventQueue` only.
    @discardableResult
    private func repost(untilSuccess: Bool, _ body: () -> Bool) -> Bool {
        var any = false
        for i in 0..<repostCount {
            if body() {
                any = true
                if untilSuccess { break }
            }
            if i < repostCount - 1 { usleep(repostGapMicros) }
        }
        return any
    }

    /// Dismiss the switcher HUD, then release ⌘ — the shared path for every place a held ⌘ must end
    /// WITHOUT committing: a 4-finger `.cancel`, the frame-stall watchdog, engine teardown, and
    /// restart recovery. Once the HUD is up a plain ⌘ release ACTIVATES the highlighted app, so the
    /// HUD must be dismissed with Escape FIRST, leaving the original app frontmost. `eventQueue` only.
    ///
    /// No-ops unless `commandHeld` (so a stray `.cancel` after the watchdog already released can't
    /// fire a spurious ⌘-Escape at the front app). Releases ⌘ ONLY once `hudDismissed` is set: when
    /// the Escape's creation fails the ⌘-up's creation fails too (same path), so holding ⌘ and
    /// letting the watchdog retry loses nothing and removes any chance of releasing onto a live HUD
    /// (a mis-commit). Once dismissed, retries re-post only the ⌘-up — never re-spamming Escape.
    private func dismissAndRelease() {
        guard commandHeld else { return }
        if !hudDismissed {
            // Retry until the Escape posts (stop-at-first-success: don't over-post ⌘-Escape).
            hudDismissed = repost(untilSuccess: true) { postChord(Key.escape, flags: .maskCommand) }
            if hudDismissed {
                // Order the Escape ahead of the ⌘-up against coalescing during the WindowServer's
                // worst-lag moment (a Spaces / switcher animation).
                usleep(cancelSettleMicros)
            }
        }
        guard hudDismissed else {
            // Escape's creation is failing — the ⌘-up's would too — so releasing now can't free ⌘
            // and could only commit onto a still-live HUD. Hold ⌘ and let the watchdog retry.
            log.error("dismiss pending: Escape not yet posted — holding ⌘ for watchdog retry")
            return
        }
        log.notice("dismiss HUD + release ⌘")
        releaseCommand()
    }

    /// Resolve a still-held ⌘ by its phase — shared by teardown (`releaseAllAndWait`) and restart
    /// recovery (`prepare`) so both honor the SAME commit-vs-cancel policy as the watchdog. Without
    /// it, a `.swipeCommit` whose ⌘-up failed to create (commandHeld still true) would be torn down
    /// via the CANCEL path (Escape + release), inverting the user's commit into a cancel. Caller
    /// holds `commandHeld`. `eventQueue` only.
    private func resolveHeldCommand() {
        switch heldPhase {
        case .committing:
            // User committed; only the ⌘-up failed to post. Complete the COMMIT — no Escape.
            releaseCommand()
        case .inProgress, .cancelling:
            // No commit intent (a mid-gesture teardown) or an explicit cancel: dismiss the HUD
            // before releasing so a plain ⌘-up can't commit a stale highlight.
            dismissAndRelease()
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
            switch self.heldPhase {
            case .inProgress:
                // No terminal action yet, so the only safe trigger is a DEAD frame stream — the
                // gesture's device slept / disconnected and the user can no longer end it. The frame
                // gap matters here (a resting hold is alive). Cancel, never commit a stale highlight.
                let last = self.lastFrameTime.withLock { $0 }
                let gap = CACurrentMediaTime() - last
                guard gap > self.staleFrameThreshold else { return }
                self.log.error("frame stream stalled \(gap, format: .fixed(precision: 2))s mid-switch — cancelling held ⌘")
                self.heldPhase = .cancelling
                self.dismissAndRelease()
            case .committing:
                // `.swipeCommit` ran but its ⌘-up never posted (commandHeld still set). Retry it —
                // frame-INDEPENDENT, because a commit may leave fingers resting (stream still alive),
                // so a frame-gap gate could wait forever. Retrying as a commit never inverts it.
                self.log.error("commit ⌘-up still pending — retrying release")
                self.releaseCommand()
            case .cancelling:
                // A cancel ran but isn't complete. Retry; `dismissAndRelease` + `hudDismissed` re-post
                // Escape only until it lands, then only the ⌘-up — no front-app ⌘-Escape spam.
                self.log.error("cancel still pending — retrying dismiss/release")
                self.dismissAndRelease()
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
