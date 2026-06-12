import Foundation
import os

// MARK: - Shared gesture defaults

/// Canonical defaults for gesture recognition, shared between the recognizer's
/// fallback `Config` and the app's preference layer so the shipping defaults have a
/// single source of truth. The app always pushes these into the engine at launch;
/// the recognizer's struct defaults are only a safety net for a path that forgot to.
public enum GestureTuning {
    /// Horizontal travel (mm) required per app-switch step.
    public static let swipeDistanceDefaultMM: Float = 3.5
    /// Frame-gap (seconds) beyond which the touch stream is treated as stalled — the
    /// device slept, disconnected, or a Bluetooth trackpad dropped — rather than a
    /// gesture continuing. One source of truth shared by the recognizer (abandons an
    /// in-flight gesture), the synthesizer's stuck-⌘ watchdog, and the suppressor's
    /// stuck-suppression self-heal, so all three agree on what "stalled" means.
    public static let staleStreamGap: Double = 2.0
    /// Ignored edge band (mm in from the rim) at gesture start.
    public static let palmEdgeBandDefaultMM: Float = 7
    /// Upper bound of the palm edge band, used to normalize the size-cap derivation.
    public static let palmEdgeBandMaxMM: Float = 15
    /// Contact-size cap derived from the edge band: a wider ignored band pairs with a
    /// stricter cutoff — 2.0 at 0 mm down to 1.2 at the maximum band.
    public static func palmMaxSize(forEdgeBandMM mm: Float) -> Float {
        let t = max(0, min(1, mm / palmEdgeBandMaxMM))
        return 2.0 - t * (2.0 - 1.2)
    }
}

// MARK: - Abstract actions
//
// The recognizer emits intent, not events. `ActionSynthesizer` turns these into
// CGEvents. Keeping the recognizer free of CGEvent/AppKit dependencies makes the
// whole gesture pipeline unit-testable without Accessibility permission.

/// Direction of an app-switch step. `forward` = right swipe (⌘Tab), `backward` =
/// left swipe (⌘⇧Tab).
enum SwipeDirection: Sendable, Equatable {
    case forward
    case backward
}

/// A recognized gesture intent.
enum GestureAction: Sendable, Equatable {
    case middleClick
    case swipeBegin              // first threshold crossing — hold ⌘
    case swipeStep(SwipeDirection)
    case swipeCommit             // fingers lifted — release ⌘, commit the switch
    case cancel                  // aborted (e.g. 4+ fingers) — release ⌘, no switch
}

// MARK: - GestureRecognizer

/// Three-finger tap and horizontal-swipe state machine.
///
/// `process(_:count:timestamp:)` runs on the framework callback thread and is the
/// hot path: it reads the live touch buffer in place, allocates nothing, and takes
/// no locks except a single uncontended read of the swipe threshold. All mutable
/// state is touched only on that thread; `onAction` is set once before `start()`.
final class GestureRecognizer: @unchecked Sendable {

    // Tap timing — a tap is a brief, near-stationary three-finger contact.
    private let tapMaxDuration: Double = 0.15
    private let tapMinDuration: Double = 0.035
    private let tapMinFrames: Int = 2
    /// Any centroid travel (mm) beyond this — that isn't a swipe — disqualifies the
    /// tap, so vertical three-finger swipes don't register as middle clicks.
    private let tapMoveCancelMM: Float = 3.0
    /// Any single touch path travelling more than this (mm) disqualifies the tap.
    ///
    /// Identity-based, anchored where each touch first lands and tracked by the
    /// sensor's persistent `pathIndex` — for EVERY contact, palm-rejected ones
    /// included. This is the load-bearing pinch/spread guard (Launchpad, show
    /// desktop: thumb + three fingers), and it closes the two holes that survived
    /// the earlier centroid- and spread-delta heuristics:
    ///   • those were re-anchored on every contact-count change (different contact
    ///     sets aren't comparable), and a pinch's count flickers constantly as
    ///     fingertips merge — laundering all the motion evidence through re-anchors;
    ///   • the palm filter hid the pinching thumb from the centroid entirely.
    /// Per-path travel can't be laundered (the anchor never moves while the touch
    /// lives) and the thumb's own travel counts. 4 mm sits above a firm tap's
    /// landing skid but far below any pinch finger's travel.
    private let tapPathTravelCancelMM: Float = 4.0
    /// A path index absent longer than this many frames is a NEW touch when it
    /// reappears (the framework recycles path slots): re-anchor it rather than
    /// charging it with travel that spans two different touches. Short enough to
    /// bridge a one-or-two-frame sensor dropout mid-pinch without re-anchoring.
    private let pathGapFrames = 8

    /// After a gesture ends abnormally — 4+ fingers seen (a system gesture like
    /// Launchpad / show desktop / Mission Control), the sub-3 dwell bound, or a stalled
    /// stream — a re-armed gesture starting within this window is tap-disqualified from
    /// birth (swipes are unaffected). The tail of a system gesture flickers through
    /// exactly three contacts as fingers merge and lift; without the quarantine each
    /// flicker re-armed tracking with a fresh, pristine tap window, so the *end* of a
    /// Launchpad pinch could still fire a middle click no matter what the earlier
    /// frames showed. A clean lift to zero never quarantines, so deliberate rapid
    /// re-taps stay instant.
    private let tapQuarantine: Double = 0.3

    // Swipe geometry.
    private let entryDominance: Float = 1.5   // |Δx| must beat |Δy| by this to start a swipe
    private let stepDominance: Float = 1.0    // looser once a swipe is underway

    /// While swiping, only three fingers drive the switch. A contact count below three
    /// must persist this many frames before the swipe commits — absorbing a one- or
    /// two-frame dropout (a fingertip flickering below the contact threshold) so a glitch
    /// doesn't cut a scrub short. A clean lift to zero contacts commits immediately.
    private let endDebounceFrames: Int = 3

    /// While a swipe is underway but the system app-switcher HUD has not yet been
    /// drawn, only the initial switch is allowed — extra step thresholds crossed in
    /// this window are swallowed. A fast flick-and-lift therefore switches exactly one
    /// app: you never blind-cycle past an unknown number of apps you can't see. To
    /// scrub through several, hold long enough for the HUD to appear, then keep moving.
    ///
    /// 250 ms mirrors macOS's own ⌘Tab HUD reveal delay: the native switcher (and
    /// AltTab, which reverse-engineers it) waits ~250 ms before drawing so a quick tap
    /// doesn't flash the overlay. Erring slightly long is the safe direction here —
    /// it favours one clean switch over a blind second step. Retune if that shifts.
    private let hudRevealDelay: Double = 0.25

    /// On the first frame after a stalled stream any in-flight gesture is abandoned (see
    /// `process`): by then the synthesizer's watchdog has cancelled the held-⌘ switch and
    /// the suppressor has self-healed, so resuming would only fire steps into a dead
    /// session. A live gesture — even fingers resting to read the HUD — delivers frames
    /// far more often than this. Shared with the synthesizer and suppressor so all agree.
    private let staleFrameGap = GestureTuning.staleStreamGap

    /// Tunables read on the hot path and written from the UI thread. Bundling them
    /// behind one unfair lock means the per-frame path takes a single lock.
    private struct Config {
        var swipeDistanceMM = GestureTuning.swipeDistanceDefaultMM   // horizontal travel (mm) per app-switch step
        var middleClickEnabled = true
        var appSwitchEnabled = true
        var palmEdgeBandMM = GestureTuning.palmEdgeBandDefaultMM      // edge exclusion band (mm in from the rim)
        var palmMaxSize = GestureTuning.palmMaxSize(forEdgeBandMM: GestureTuning.palmEdgeBandDefaultMM)  // contact-size cap above which it's a palm
    }
    private let config = OSAllocatedUnfairLock(initialState: Config())

    /// One compact line per ended 3-finger gesture (`log show --predicate 'subsystem ==
    /// "com.trident.Trident"'`). Forensics for stray middle clicks: the pinch→tap leak
    /// took three attempts to corner blind; this records exactly why each lift did or
    /// didn't click, so the next report comes with data instead of guesses.
    private let log = Logger(subsystem: "com.trident.Trident", category: "Recognizer")

    init() {
        pathAnchors.reserveCapacity(16)   // hot path never grows it
    }

    /// Sink for recognized actions. Invoked on the callback thread.
    var onAction: ((GestureAction) -> Void)?

    /// Fires `true` the moment three fingers are down and `false` when the gesture
    /// ends (whatever the outcome). Drives the event suppressor that blocks stray
    /// native clicks. Invoked on the callback thread.
    var onGestureActiveChanged: ((Bool) -> Void)?

    /// Horizontal travel, in millimetres, required to trigger one app-switch step.
    func setSwipeDistance(_ mm: Float) {
        config.withLock { $0.swipeDistanceMM = mm }
    }

    func setMiddleClickEnabled(_ enabled: Bool) {
        config.withLock { $0.middleClickEnabled = enabled }
    }

    func setAppSwitchEnabled(_ enabled: Bool) {
        config.withLock { $0.appSwitchEnabled = enabled }
    }

    func setPalmRejection(edgeBandMM: Float, maxSize: Float) {
        config.withLock {
            $0.palmEdgeBandMM = edgeBandMM
            $0.palmMaxSize = maxSize
        }
    }

    // MARK: State (callback-thread only)

    private enum Phase { case idle, tracking, swiping }
    private var phase: Phase = .idle
    private var anchorX: Float = 0
    private var anchorY: Float = 0
    /// Where each live touch path first landed (see `tapPathTravelCancelMM`).
    /// A handful of entries at most — linear scans are free. The buffer's capacity is
    /// reserved once; clears keep it, so the hot path never allocates.
    private struct PathAnchor {
        var id: Int32
        var x: Float
        var y: Float
        var lastSeenFrame: Int
    }
    private var pathAnchors: [PathAnchor] = []
    /// Monotone frame counter for `PathAnchor.lastSeenFrame` / `pathGapFrames`.
    private var frameIndex = 0
    /// Largest per-path travel seen during the current gesture — forensics only.
    private var gestureMaxTravel: Float = 0
    private var startTime: Double = 0
    private var frameCount: Int = 0
    private var lastValidCount: Int = 0
    private var movedTooFar = false
    private var swipeStartTime: Double = 0
    /// Timestamp of the previous frame, used to detect a stalled-then-resumed stream.
    private var lastTimestamp: Double = 0
    /// Gestures re-armed before this (device-stream) timestamp start tap-disqualified
    /// (see `tapQuarantine`).
    private var quarantineUntil: Double = 0
    /// Consecutive frames seen with fewer than three contacts while swiping (debounce).
    private var lowFrameCount: Int = 0

    // MARK: Hot path

    func process(_ touches: UnsafePointer<MTTouch>, count: Int, timestamp: Double,
                 widthMM: Float, heightMM: Float) {
        let cfg = config.withLock { $0 }

        // If the stream stalled and resumed, abandon any in-flight gesture instead of
        // resuming it: the synthesizer's watchdog has released a held ⌘ and the switcher
        // is gone, so further steps would silently no-op while still firing phantom
        // feedback. Emitting .cancel also releases ⌘ through the normal path in case the
        // watchdog hasn't fired yet (it's a no-op if it has). Resuming fingers then begin
        // a fresh gesture via the .idle case below.
        if phase != .idle, timestamp - lastTimestamp > staleFrameGap {
            if phase == .swiping { onAction?(.cancel) }
            quarantineUntil = timestamp + tapQuarantine
            reset()
        }
        lastTimestamp = timestamp

        // The edge band only filters palms when a gesture is *starting*; once we're
        // tracking, fingers are free to sweep toward an edge without being dropped.
        let entering = phase == .idle

        // One pass: centroid of valid (non-palm) contacts, plus per-path travel for
        // EVERY contact — palm-rejected ones included, so a pinching thumb the palm
        // filter hides still disqualifies a tap. Tight and allocation-free.
        frameIndex &+= 1
        var sumX: Float = 0
        var sumY: Float = 0
        var valid = 0
        var anyContact = false
        var maxPathTravelMM: Float = 0
        for i in 0..<count {
            let t = touches[i]
            guard TouchState.isContact(t.state) else { continue }
            anyContact = true
            let p = t.normalizedVector.position
            let travel = notePathTravel(id: t.pathIndex, position: p,
                                        widthMM: widthMM, heightMM: heightMM)
            if travel > maxPathTravelMM { maxPathTravelMM = travel }
            if isPalm(position: p, size: t.zTotal, edgeBandMM: cfg.palmEdgeBandMM,
                      maxSize: cfg.palmMaxSize, widthMM: widthMM, heightMM: heightMM,
                      applyEdgeBand: entering) {
                continue
            }
            sumX += p.x
            sumY += p.y
            valid += 1
        }
        // All touches gone: the next landing is a new story — drop the path anchors.
        // (Keeps capacity, so this never allocates on re-fill.)
        if !anyContact { pathAnchors.removeAll(keepingCapacity: true) }
        let cx = valid > 0 ? sumX / Float(valid) : 0
        let cy = valid > 0 ? sumY / Float(valid) : 0

        switch phase {
        case .idle:
            // Only arm a gesture when at least one mapping can actually fire; otherwise
            // three fingers would needlessly drive the click suppressor for no benefit.
            if valid == 3, cfg.middleClickEnabled || cfg.appSwitchEnabled {
                beginTracking(cx: cx, cy: cy, maxPathTravelMM: maxPathTravelMM, timestamp: timestamp)
            }
        case .tracking:
            handleTracking(valid: valid, cx: cx, cy: cy, maxPathTravelMM: maxPathTravelMM,
                           timestamp: timestamp, config: cfg, widthMM: widthMM, heightMM: heightMM)
        case .swiping:
            handleSwiping(valid: valid, cx: cx, cy: cy, timestamp: timestamp,
                          distanceMM: cfg.swipeDistanceMM, widthMM: widthMM, heightMM: heightMM)
        }
        lastValidCount = valid
    }

    // MARK: Phases

    /// Look up (or anchor) a touch path and return how far it has travelled, in mm,
    /// since it first landed. A path slot unseen for more than `pathGapFrames` is a
    /// recycled index — a new touch — and is re-anchored at zero travel.
    private func notePathTravel(id: Int32, position p: MTPoint,
                                widthMM: Float, heightMM: Float) -> Float {
        for i in pathAnchors.indices where pathAnchors[i].id == id {
            if frameIndex - pathAnchors[i].lastSeenFrame > pathGapFrames {
                pathAnchors[i] = PathAnchor(id: id, x: p.x, y: p.y, lastSeenFrame: frameIndex)
                return 0
            }
            pathAnchors[i].lastSeenFrame = frameIndex
            return hypotf((p.x - pathAnchors[i].x) * widthMM,
                          (p.y - pathAnchors[i].y) * heightMM)
        }
        pathAnchors.append(PathAnchor(id: id, x: p.x, y: p.y, lastSeenFrame: frameIndex))
        return 0
    }

    private func beginTracking(cx: Float, cy: Float, maxPathTravelMM: Float, timestamp: Double) {
        phase = .tracking
        anchorX = cx
        anchorY = cy
        startTime = timestamp
        frameCount = 1
        gestureMaxTravel = maxPathTravelMM
        // Born inside the quarantine window (the flickering tail of a system gesture),
        // or from touches that have already travelled (a pinch mid-flight whose thumb
        // just slid into the palm filter's edge band) → tap-disqualified from the
        // start. Swipes don't consult this flag.
        movedTooFar = timestamp < quarantineUntil || maxPathTravelMM > tapPathTravelCancelMM
        onGestureActiveChanged?(true)
    }

    private func handleTracking(valid: Int, cx: Float, cy: Float, maxPathTravelMM: Float,
                                timestamp: Double, config: Config, widthMM: Float, heightMM: Float) {
        if valid >= 4 {
            // 4+ fingers belong to the system (Mission Control, Launchpad, show
            // desktop). Quarantine the re-arm: those gestures' tails flicker through
            // exactly three contacts, which must not open a fresh tap window.
            quarantineUntil = timestamp + tapQuarantine
            reset()
            return
        }
        if valid == 0 {
            // All fingers lifted: fire a middle click if this was a clean tap.
            let elapsed = timestamp - startTime
            let tap = config.middleClickEnabled && !movedTooFar && frameCount >= tapMinFrames
                && elapsed >= tapMinDuration && elapsed <= tapMaxDuration
            if tap { onAction?(.middleClick) }
            log.notice("""
                gesture end: tap=\(tap) elapsed=\(elapsed, format: .fixed(precision: 3))s \
                frames=\(self.frameCount) moved=\(self.movedTooFar) \
                maxPathTravel=\(self.gestureMaxTravel, format: .fixed(precision: 1))mm
                """)
            reset()
            return
        }
        // Identity-based tap guard, independent of contact-count bookkeeping: a path
        // that has travelled was not tapping, no matter how the count flickered.
        if maxPathTravelMM > gestureMaxTravel { gestureMaxTravel = maxPathTravelMM }
        if maxPathTravelMM > tapPathTravelCancelMM {
            movedTooFar = true
        }
        if valid != lastValidCount {
            // Contact count changed (a dip, a re-acquired finger, or fingertips
            // merging mid-pinch) — re-anchor so the centroid jump between different
            // contact sets doesn't read as travel.
            anchorX = cx
            anchorY = cy
        } else {
            if valid == 3 { frameCount += 1 }
            let dxMM = (cx - anchorX) * widthMM
            let dyMM = (cy - anchorY) * heightMM
            let adx = abs(dxMM), ady = abs(dyMM)
            if valid == 3, config.appSwitchEnabled,
               adx >= config.swipeDistanceMM, adx > entryDominance * ady {
                enterSwiping(cx: cx, cy: cy, timestamp: timestamp)
                return
            }
            if hypotf(dxMM, dyMM) > tapMoveCancelMM {
                movedTooFar = true   // centroid travel that isn't a swipe — not a tap
            }
        }
        // Below three contacts, wait only inside the tap window. Beyond it nothing
        // pending can fire (a tap is already too old, and a swipe needs three fingers
        // back — which re-arms just as well from idle), while the gesture-active latch
        // keeps the suppressor eating every click system-wide. Without this bound, two
        // fingers left resting after a three-finger touch suppressed clicks forever.
        // Quarantined: the dwell often *is* a system gesture's tail mid-merge.
        if valid < 3, timestamp - startTime > tapMaxDuration {
            quarantineUntil = timestamp + tapQuarantine
            reset()
        }
    }

    private func enterSwiping(cx: Float, cy: Float, timestamp: Double) {
        phase = .swiping
        swipeStartTime = timestamp
        onAction?(.swipeBegin)
        // The first step always opens forward (⌘Tab), regardless of swipe direction.
        // Tapping ⌘Tab opens the switcher already moved one app forward (to the previous
        // app), so a quick flick *either* way lands on the previous app — a left flick
        // never jumps to the oldest app. Direction only starts to matter once the HUD is
        // up and you scrub: handleSwiping steps backward (⌘⇧Tab) for leftward travel.
        onAction?(.swipeStep(.forward))
        anchorX = cx
        anchorY = cy
    }

    private func handleSwiping(valid: Int, cx: Float, cy: Float, timestamp: Double,
                               distanceMM: Float, widthMM: Float, heightMM: Float) {
        if valid >= 4 {
            onAction?(.cancel)
            quarantineUntil = timestamp + tapQuarantine
            reset()
            return
        }
        if valid == 0 {
            // All fingers lifted — commit the highlighted app.
            onAction?(.swipeCommit)
            reset()
            return
        }
        if valid < 3 {
            // Only three fingers drive the switch. One or two contacts means the user is
            // lifting to commit, or a contact momentarily dropped out mid-scrub. Don't
            // step — two-finger motion isn't an app-switch (and would fight macOS's own
            // two-finger swipe). Debounce a few frames so a one-frame dropout doesn't cut
            // a scrub short, then commit if the low count persists. Re-anchor so a
            // recovered third contact's centroid shift isn't read as travel.
            lowFrameCount += 1
            if lowFrameCount >= endDebounceFrames {
                onAction?(.swipeCommit)
                reset()
                return
            }
            anchorX = cx
            anchorY = cy
            return
        }
        // valid == 3: the only state that steps.
        lowFrameCount = 0
        if valid != lastValidCount {
            anchorX = cx          // re-anchor after the third contact returns
            anchorY = cy
            return
        }
        let dxMM = (cx - anchorX) * widthMM
        let dyMM = (cy - anchorY) * heightMM
        let adx = abs(dxMM), ady = abs(dyMM)
        if adx >= distanceMM, adx > stepDominance * ady {
            // Suppress steps until the HUD is up: travel before then only ever yields
            // the single switch already emitted on `.swipeBegin`. Re-anchor either way
            // so the swallowed travel is consumed — no catch-up burst the instant the
            // HUD appears.
            if timestamp - swipeStartTime >= hudRevealDelay {
                onAction?(.swipeStep(dxMM > 0 ? .forward : .backward))
            }
            anchorX = cx          // reset anchor so a long sweep steps repeatedly
            anchorY = cy
        }
    }

    /// Clear all state back to idle without emitting any action. The engine calls this
    /// before `start()` so a restart never resumes a stale phase left by a run that
    /// stopped mid-gesture; it is safe because frame delivery is not yet enabled when
    /// the engine calls it. Also drops the tap quarantine: a fresh stream's timestamp
    /// domain may differ, so a stale deadline could quarantine forever (or not at all).
    func resetState() {
        clearGesture()
        quarantineUntil = 0
        pathAnchors.removeAll(keepingCapacity: true)
        frameIndex = 0
    }

    /// End the current gesture (back to idle) without emitting any action. The tap
    /// quarantine deliberately survives — the sites that set it do so right before
    /// calling this.
    private func reset() {
        clearGesture()
        onGestureActiveChanged?(false)
    }

    /// Per-gesture state only. `pathAnchors` deliberately survives: while touches
    /// remain on the surface, the tail of an aborted system gesture keeps carrying
    /// its accumulated travel into any re-armed gesture. The anchors clear when all
    /// contacts lift (see `process`) or on `resetState()`.
    private func clearGesture() {
        phase = .idle
        anchorX = 0
        anchorY = 0
        startTime = 0
        frameCount = 0
        lastValidCount = 0
        movedTooFar = false
        swipeStartTime = 0
        lastTimestamp = 0
        lowFrameCount = 0
    }

    /// A contact is a palm if it's too large, or — only while a gesture is just
    /// starting (`applyEdgeBand`) — if it sits in the edge/bottom exclusion band.
    /// The edge band is dropped once a gesture is underway so a finger sweeping
    /// toward an edge during a horizontal swipe stays counted (otherwise the
    /// centroid jumps and accumulated travel resets). A real palm dropping in
    /// mid-gesture is still caught by the size cap.
    private func isPalm(position p: MTPoint, size: Float, edgeBandMM: Float,
                        maxSize: Float, widthMM: Float, heightMM: Float,
                        applyEdgeBand: Bool) -> Bool {
        if size > maxSize { return true }
        if applyEdgeBand {
            let xMM = p.x * widthMM
            let yMM = p.y * heightMM
            if xMM < edgeBandMM || xMM > widthMM - edgeBandMM { return true }
            if yMM < edgeBandMM { return true }
        }
        return false
    }
}
