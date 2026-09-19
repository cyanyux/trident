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
/// `process(_:count:timestamp:)` runs on the framework's per-device callback
/// threads and is the hot path: it reads the live touch buffer in place and
/// allocates nothing. MultitouchSupport calls back on a DIFFERENT thread per
/// device, so with two trackpads (built-in + Magic Trackpad) two frames can be
/// in flight at once — all mutable state is serialized behind `processLock`,
/// which `resetState()` takes too, so a restart can't clear state underneath an
/// in-flight frame. The lock is held for microseconds and never while calling
/// out to code that could re-enter it. `onAction`/`onGestureActiveChanged` are
/// invoked under it, from whichever device thread delivered the frame.
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
    /// lives, except the one deliberate re-base when parking is earned) and the
    /// thumb's own travel counts. 4 mm sits above a firm tap's landing skid but
    /// far below any pinch finger's travel.
    private let tapPathTravelCancelMM: Float = 4.0
    /// Per-frame movement below this (mm) counts as still — resting-thumb jitter is
    /// sub-millimetre, a real finger in a gesture moves more.
    private let stillnessEps: Float = 1.0
    /// Still frames at ~125 Hz before a rim contact settles into a parked thumb —
    /// ~64 ms. Parking is earned by this much consecutive stillness inside the band.
    private let parkSettleFrames: Int = 8
    /// Displacement over a still window that counts as movement evidence: a window
    /// reaching this is dirty (the evidence latch stays or sets); a full window
    /// under it is clean (the latch releases, parking can be earned). ~0.09 mm per
    /// frame over `parkSettleFrames` — roughly a 12 mm/s drift at 125 Hz — so any
    /// creep at gesture-relevant speed trips it while resting jitter (~0.3 mm of
    /// wander, not sustained one-way displacement) does not.
    private let streakEvidenceMM: Float = 0.75
    /// A path index absent longer than this many frames is a NEW touch when it
    /// reappears (the framework recycles path slots): re-anchor it rather than
    /// charging it with travel that spans two different touches. Short enough to
    /// bridge a one-or-two-frame sensor dropout mid-pinch without re-anchoring.
    private let pathGapFrames = 8

    /// A single touch path already beyond this travel when a gesture is born means
    /// a finger was DOWN AND MOVING before three contacts were ever present — the
    /// signature of a two-finger scroll (Safari back/forward, a horizontal
    /// scrollbar) whose remaining finger two fresh contacts just joined. One is
    /// enough: the gesture bars its swipe for life (like `bornInSystemGestureTail`)
    /// because the accumulated scroll travel would otherwise carry straight over
    /// the step threshold and fire a phantom ⌘Tab. A real three-finger swipe arms
    /// within a frame or two of landing, so its paths read ~0; even a fast flick's
    /// staggered landing can't put a path past 30 mm before the arm. An edge-band
    /// start sweeps out of a ≤15 mm band, also under the bound.
    private let bornScrollTravelMM: Float = 30

    /// After 4+ fingers are seen (a system gesture: Launchpad, show desktop, Mission
    /// Control, a Spaces swipe) or a gesture ends abnormally (the sub-3 dwell bound, a
    /// stalled stream), a gesture born within this window is quarantined for its whole
    /// life. The tail of a system gesture flickers through exactly three contacts as
    /// fingers merge and lift; without the quarantine each flicker re-armed tracking
    /// pristine, so the *end* of a Launchpad pinch could fire a middle click — and,
    /// worse, the fast-moving three-contact tail of a four-finger Spaces swipe crossed
    /// the swipe threshold and posted a phantom ⌘Tab into the middle of the system's
    /// own space transition. On-device that collision wedged the Dock's Spaces state
    /// machine ("Not finished animating space changes"), leaving four-finger gestures
    /// dead until the Dock was restarted.
    ///
    /// What the quarantine bars depends on what armed it: every abnormal end bars the
    /// tap, but only an actual 4+-finger sighting bars the swipe — a dwell or stall is
    /// no evidence of a four-finger transition, and a third finger returning to two
    /// dwelling ones should swipe freely. A clean lift to zero from a *three*-finger
    /// gesture never quarantines, so deliberate rapid re-taps and re-swipes stay
    /// instant.
    ///
    /// The swipe bar is fixed at the gesture's BIRTH and lasts its whole life, not
    /// just this window — so after a 4th-finger graze cancels a live switch, keeping
    /// three fingers down bars swiping until they all lift and re-plant. Deliberate: a
    /// 4-contact frame is indistinguishable from the user starting a real system
    /// gesture, an entry-time check would let a four-finger swipe that sheds a finger
    /// simply outlive the window and fire the phantom ⌘Tab late, and the re-plant is
    /// instant. Safety wins the tie.
    private let reArmQuarantine: Double = 0.3

    // Swipe geometry.
    private let entryDominance: Float = 1.5   // |Δx| must beat |Δy| by this to start a swipe
    private let stepDominance: Float = 1.0    // looser once a swipe is underway

    /// A swipe entry is HELD this long before anything is posted, to confirm no 4th
    /// finger is still landing. The quarantine (`reArmQuarantine`) covers 4+ fingers
    /// seen BEFORE a gesture arms, but it cannot see a finger that hasn't landed: a
    /// four-finger Spaces swipe's fingers can land a frame or two apart, so the first
    /// three arm tracking as a clean gesture — and a fast hand crosses the step
    /// threshold before the 4th contact registers, posting the phantom ⌘Tab
    /// mid-space-transition all over again. Holding the entry lets the straggler show
    /// up and kill the gesture silently: nothing has been posted, so there is nothing
    /// to cancel. The feel cost is nil where it matters — fingers lifting during the
    /// hold confirm immediately (a landing count doesn't fall), so a quick
    /// flick-and-lift still switches the instant it always did; only a held scrub's
    /// first step lands these few ms later, invisible against the HUD's own 250 ms
    /// reveal. 40 ms ≈ 5 frames at the built-in trackpad's ~125 Hz.
    private let entryConfirmDelay: Double = 0.04

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

    /// Sink for recognized actions. Invoked on the callback thread (whichever
    /// device delivered the frame), under `processLock`.
    var onAction: ((GestureAction) -> Void)?

    /// Fires `true` the moment three fingers are down and `false` when the gesture
    /// ends (whatever the outcome) — and also when a gesture outlives the tap
    /// window, since only tap-like contacts can make macOS synthesize a click.
    /// Drives the event suppressor that blocks stray native clicks. Invoked on
    /// the callback thread, under `processLock`.
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

    // MARK: State (`processLock` only)

    /// Serializes every frame's state access — the framework can invoke the
    /// contact callback on a different thread PER DEVICE, so two trackpads can
    /// deliver frames concurrently. Uncontended in the common single-device case;
    /// held for microseconds either way. Also taken by `resetState()` so an
    /// engine restart can't clear state underneath an in-flight frame.
    private let processLock = NSLock()

    private enum Phase { case idle, tracking, swiping }
    private var phase: Phase = .idle
    private var anchorX: Float = 0
    private var anchorY: Float = 0
    /// Where each live touch path first landed or last parked (see
    /// `tapPathTravelCancelMM` and `notePathTravel`).
    /// A handful of entries at most — linear scans are free. The buffer's capacity is
    /// reserved once; clears keep it, so the hot path never allocates.
    private struct PathAnchor {
        var id: Int32
        var x: Float
        var y: Float
        var lastX: Float
        var lastY: Float
        /// Where the current still streak began — displacement from here, not the
        /// frame count alone, decides whether a contact is truly "settled" (a
        /// uniform sub-eps creep racks up stillFrames while physically moving).
        var stillX: Float
        var stillY: Float
        var lastSeenFrame: Int
        /// Consecutive frames with per-frame movement below `stillnessEps`.
        var stillFrames: Int
        /// Latched resting-thumb flag. Earned ONLY by proof — a full clean still
        /// window inside the edge band while a gesture is starting — or carried
        /// across a one-frame sensor flicker (gap ≤ 2). Re-earned the same way on
        /// every clean window, so a parked contact that re-seats slides its
        /// anchor. Never granted at landing: an unproven band landing is
        /// indistinguishable from a system-gesture straggler, so it must re-prove
        /// like everything else. A contact that lands in the band MID-gesture can
        /// never park.
        var parked: Bool
        /// Quarantine-evidence latch for a FILTERED contact. Set by any movement
        /// evidence — a supra-eps frame, `streakEvidenceMM` of window displacement,
        /// or (re)appearing mid-gesture — and cleared ONLY by a full clean window
        /// (`parkSettleFrames` consecutive still frames whose total displacement
        /// stayed under the bound). A latch, not a per-frame reading: otherwise a
        /// slow uniform creep would amnesty itself between measurement windows,
        /// leaving gaps wide enough for a pending swipe to complete in.
        var movingEvidence: Bool
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
    /// Whether this gesture was born inside the four-finger quarantine window — the
    /// tail of a system gesture. Fixed at birth; bars the swipe (the tap is barred
    /// through `movedTooFar`). See `reArmQuarantine`.
    private var bornInSystemGestureTail = false
    /// Whether this gesture was born inside the tap quarantine window. Feeds
    /// `movedTooFar`; kept separately only so the gesture-end forensic line can tell
    /// a quarantine-barred tap from a travel-cancelled one.
    private var bornTapQuarantined = false
    /// When the swipe's entry conditions were first met, while the entry is held to
    /// confirm no 4th finger is still landing (see `entryConfirmDelay`). `nil` when no
    /// entry is pending.
    private var swipePendingSince: Double?
    private var swipeStartTime: Double = 0
    /// Timestamp of the previous frame, used to detect a stalled-then-resumed stream.
    private var lastTimestamp: Double = 0
    /// Gestures re-armed before this (device-stream) timestamp start tap-disqualified
    /// (see `reArmQuarantine`).
    private var quarantineUntil: Double = 0
    /// Gestures re-armed before this timestamp are the tail of a four-finger system
    /// gesture and start swipe-disqualified too (see `reArmQuarantine`). Advanced only
    /// by actual 4+-finger sightings, never by the dwell/stall re-arms.
    private var swipeQuarantineUntil: Double = 0
    /// Consecutive frames seen with fewer than three contacts while swiping (debounce).
    private var lowFrameCount: Int = 0
    /// Whether the click-suppression latch is currently held for this gesture.
    /// Released early once a gesture can no longer be a tap (see `handleTracking`),
    /// re-latched if a swipe confirms.
    private var suppressionLatched = false

    // MARK: Hot path

    /// Serialized entry point — the framework may call back on a different thread
    /// per device, so two frames can be in flight at once on multi-trackpad Macs.
    func process(_ touches: UnsafePointer<MTTouch>, count: Int, timestamp: Double,
                 widthMM: Float, heightMM: Float) {
        processLock.lock()
        defer { processLock.unlock() }
        processLocked(touches, count: count, timestamp: timestamp,
                      widthMM: widthMM, heightMM: heightMM)
    }

    private func processLocked(_ touches: UnsafePointer<MTTouch>, count: Int, timestamp: Double,
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
            quarantineUntil = timestamp + reArmQuarantine
            // The swipe quarantine is CLEARED, not rebased: a stall is no evidence of a
            // four-finger transition, and a resumed stream's timestamp domain may
            // differ — comparing a stale deadline against it is meaningless in either
            // direction (resetState() clears both for the same reason).
            swipeQuarantineUntil = 0
            reset()
        }
        lastTimestamp = timestamp

        // The edge band only filters palms when a gesture is *starting*; once we're
        // tracking, fingers are free to sweep toward an edge without being dropped.
        let entering = phase == .idle

        // One pass: centroid of valid (non-palm) contacts, plus per-path travel for
        // EVERY contact — palm-rejected ones included, so a pinching thumb the palm
        // filter hides still disqualifies a tap. Two contact counts are kept:
        //   • `physical` — every contact on the surface before the palm filter.
        //   • `quarantineCount` — what the system-gesture quarantine keys on: an
        //     UNFILTERED contact always counts, but a palm-filtered one counts only
        //     while its evidence latch is up — it moved recently (a supra-eps
        //     frame, `streakEvidenceMM` of window displacement, or appearing
        //     mid-gesture) and hasn't yet proven stillness with a full clean
        //     window. A filtered contact that simply SITS — resting thumb, resting
        //     palm heel — is no evidence: counting it barred all gestures for
        //     users who park a thumb at the pad's rim. A real fourth finger (the
        //     phantom-⌘Tab vector: oversized from a hard press, or landing inside
        //     the edge band) is always in motion while a system gesture is in
        //     flight, so the latch exposes it every frame.
        // Tight and allocation-free.
        frameIndex &+= 1
        var sumX: Float = 0
        var sumY: Float = 0
        var valid = 0
        var physical = 0
        var quarantineCount = 0
        var scrollBornPaths = 0
        var maxPathTravelMM: Float = 0
        for i in 0..<count {
            let t = touches[i]
            guard TouchState.isContact(t.state) else { continue }
            physical += 1
            let p = t.normalizedVector.position
            let atBand = inEdgeBand(p, edgeBandMM: cfg.palmEdgeBandMM,
                                    widthMM: widthMM, heightMM: heightMM)
            let (travel, parked, moving) = notePathTravel(
                id: t.pathIndex, position: p, inBand: atBand, canPark: entering,
                widthMM: widthMM, heightMM: heightMM)
            if travel > maxPathTravelMM { maxPathTravelMM = travel }
            if travel > bornScrollTravelMM { scrollBornPaths += 1 }
            // A contact is filtered OUT of the gesture's set when it's a palm:
            //   • oversized right now (re-checked every frame — a palm heel stays
            //     filtered however long it rests), or
            //   • a path PARKED at the rim — proven still there for a beat while
            //     idle — the resting thumb. The latch is earned at idle only (a
            //     mid-gesture band landing is a straggler, never a thumb), persists
            //     while the contact never flickers out for more than a frame and
            //     never drifts 4 mm from where it parked, and dies the moment it
            //     does either — supra-eps movement kills it on the spot.
            //   • currently inside the band while a gesture is only just starting
            //     (the band's original job — rim contacts are filtered at birth).
            let palm = t.zTotal > cfg.palmMaxSize || parked || (entering && atBand)
            if !palm {
                sumX += p.x
                sumY += p.y
                valid += 1
            }
            // Quarantine evidence: every unfiltered contact counts; a filtered one
            // counts only while it's behaving like a finger (see `moving` in
            // notePathTravel — moving, or travelled and not settled back). A
            // filtered contact that simply SITS (resting thumb, resting palm
            // heel) is no evidence of a four-finger system gesture.
            if !palm || moving { quarantineCount += 1 }
        }
        // All touches gone: the next landing is a new story — drop the path anchors.
        // (Keeps capacity, so this never allocates on re-fill.)
        if physical == 0 { pathAnchors.removeAll(keepingCapacity: true) }
        let cx = valid > 0 ? sumX / Float(valid) : 0
        let cy = valid > 0 ? sumY / Float(valid) : 0

        switch phase {
        case .idle:
            if quarantineCount >= 4 {
                // A system gesture is in flight. Refreshing the quarantine every frame
                // extends it to 0.3 s past the LAST 4-finger sighting, so the gesture's
                // three-contact tail is quarantined however it lands. Without this, a
                // four-finger Spaces swipe whose fingers all land in the same frame never
                // passes through .tracking — the only place the quarantine was armed —
                // and its tail could tap or (worse) fire a phantom ⌘Tab app-switch.
                // Keyed on QUARANTINE-counted contacts: a fourth finger the palm filter
                // rejects (oversized from a hard press, or inside the edge band) still
                // makes this a four-finger contact set the OS can read as a system
                // gesture — but only once it's moving, so a resting thumb doesn't
                // quarantine the pad forever.
                // (The reverse direction — a 4th finger landing AFTER three armed a
                // clean gesture — is covered by the `entryConfirmDelay` hold.)
                quarantineFourFingerSighting(at: timestamp)
            } else if valid == 3, cfg.middleClickEnabled || cfg.appSwitchEnabled {
                // Only arm a gesture when at least one mapping can actually fire; otherwise
                // three fingers would needlessly drive the click suppressor for no benefit.
                beginTracking(cx: cx, cy: cy, maxPathTravelMM: maxPathTravelMM,
                              scrollBornPaths: scrollBornPaths, timestamp: timestamp)
            }
        case .tracking:
            handleTracking(quarantineCount: quarantineCount, valid: valid, cx: cx, cy: cy,
                           maxPathTravelMM: maxPathTravelMM,
                           timestamp: timestamp, config: cfg, widthMM: widthMM, heightMM: heightMM)
        case .swiping:
            handleSwiping(quarantineCount: quarantineCount, valid: valid, cx: cx, cy: cy, timestamp: timestamp,
                          distanceMM: cfg.swipeDistanceMM, widthMM: widthMM, heightMM: heightMM)
        }
        lastValidCount = valid
    }

    // MARK: Phases

    /// Look up (or anchor) a touch path and return (cumulative travel in mm, parked,
    /// "behaving like an active finger"). `canPark` is true only while a gesture is
    /// starting — parking is an idle-time latch a contact must EARN by settling,
    /// so a system-gesture straggler landing in the band mid-gesture always counts
    /// as a fourth finger. `moving` is the quarantine evidence a FILTERED contact
    /// provides: it moved this frame, or it has crept far enough over its current
    /// still streak that it isn't settled — a parked or oversized contact that
    /// truly sits is no evidence.
    private func notePathTravel(id: Int32, position p: MTPoint, inBand: Bool, canPark: Bool,
                                widthMM: Float, heightMM: Float)
        -> (travel: Float, parked: Bool, moving: Bool) {
        for i in pathAnchors.indices where pathAnchors[i].id == id {
            var a = pathAnchors[i]
            let gap = frameIndex - a.lastSeenFrame
            if gap > pathGapFrames {
                // Recycled slot — treat as a fresh landing (same rule as below).
                a = PathAnchor(id: id, x: p.x, y: p.y, lastX: p.x, lastY: p.y,
                               stillX: p.x, stillY: p.y, lastSeenFrame: frameIndex,
                               stillFrames: 0, parked: false, movingEvidence: !canPark)
                pathAnchors[i] = a
                return (0, false, !canPark)
            }
            if gap > 2 {
                // Missing more than one frame — a re-landing, not a flicker. The
                // parked latch is dropped outright: even a band re-landing must
                // re-prove itself, so a recycled identity can't inherit parked
                // status. The evidence latch is NOT dropped — a re-landing
                // mid-gesture reads exactly like a fresh straggler below.
                a.stillFrames = 0
                a.stillX = p.x
                a.stillY = p.y
                a.parked = false
            }
            // gap <= 2 is a continuing contact: a one-frame dropout is routine
            // sensor flicker at the rim — the latches AND the still streak survive
            // untouched so it can't read as a phantom fourth finger.
            let delta = hypotf((p.x - a.lastX) * widthMM, (p.y - a.lastY) * heightMM)
            let streakMoved = hypotf((p.x - a.stillX) * widthMM, (p.y - a.stillY) * heightMM)
            // Quarantine evidence is a LATCH, not a per-frame reading: once a
            // contact moves — a supra-eps frame, streakEvidenceMM of window
            // displacement, or (re)appearing mid-gesture — it keeps counting until
            // a full clean window proves it stopped. Otherwise a slow uniform
            // creep would amnesty itself between measurement windows, leaving
            // gaps a pending swipe could complete inside.
            var moving = a.movingEvidence || delta >= stillnessEps
                || streakMoved >= streakEvidenceMM || (gap > 2 && !canPark)
            if delta >= stillnessEps {
                a.stillFrames = 0
                a.stillX = p.x     // window restarts here
                a.stillY = p.y
                a.parked = false   // any real movement un-parks — parked thumbs don't move
            } else {
                a.stillFrames += 1
                if a.stillFrames >= parkSettleFrames {
                    // Window boundary — stillness is judged over whole windows,
                    // never frame counts alone.
                    if streakMoved >= streakEvidenceMM {
                        // Dirty window — the evidence latched above. Roll the
                        // window anyway so a contact that has STOPPED gets a
                        // fresh measurement in which it can prove stillness,
                        // instead of latching `moving` on a frozen streak.
                        a.stillFrames = 0
                        a.stillX = p.x
                        a.stillY = p.y
                    } else {
                        // A full clean window — the ONLY place the evidence latch
                        // releases: stillness proven in mm, not frames.
                        moving = false
                        a.stillFrames = 0
                        a.stillX = p.x
                        a.stillY = p.y
                        if canPark && inBand {
                            // Parking is earned by that same proof — and a parked
                            // contact that re-proves stillness slides its anchor
                            // to the new seat, so "travel" stays drift-from-
                            // settlement rather than accruing against a stale spot.
                            a.parked = true
                            a.x = p.x
                            a.y = p.y
                        }
                    }
                }
            }
            a.lastX = p.x
            a.lastY = p.y
            a.lastSeenFrame = frameIndex
            let travel = hypotf((p.x - a.x) * widthMM, (p.y - a.y) * heightMM)
            // Slow drift past the tap threshold un-parks too — a thumb that has
            // crept 4 mm from where it parked is a finger again, however slowly.
            // Its stillness credit goes with it: re-earning the latch needs a
            // fresh clean window, and the evidence latch stays up until one lands.
            if a.parked, travel > tapPathTravelCancelMM {
                a.parked = false
                a.stillFrames = 0
                a.stillX = p.x
                a.stillY = p.y
            }
            a.movingEvidence = moving
            pathAnchors[i] = a
            return (travel, a.parked, moving)
        }
        // Fresh landing. A contact appearing mid-gesture is a straggler candidate —
        // its evidence latch starts SET so it counts for quarantine from the exact
        // frame it lands (e.g. the pending-confirm frame) until it proves still;
        // at idle `canPark` makes this false.
        pathAnchors.append(PathAnchor(id: id, x: p.x, y: p.y, lastX: p.x, lastY: p.y,
                                      stillX: p.x, stillY: p.y, lastSeenFrame: frameIndex,
                                      stillFrames: 0, parked: false, movingEvidence: !canPark))
        return (0, false, !canPark)
    }

    /// A 4+-finger sighting quarantines re-arms from BOTH the tap and the swipe (the
    /// dwell/stall sites advance only `quarantineUntil` — see `reArmQuarantine`).
    private func quarantineFourFingerSighting(at timestamp: Double) {
        quarantineUntil = timestamp + reArmQuarantine
        swipeQuarantineUntil = timestamp + reArmQuarantine
    }

    private func beginTracking(cx: Float, cy: Float, maxPathTravelMM: Float,
                               scrollBornPaths: Int, timestamp: Double) {
        phase = .tracking
        anchorX = cx
        anchorY = cy
        startTime = timestamp
        frameCount = 1
        gestureMaxTravel = maxPathTravelMM
        // Born inside the four-finger quarantine window: this "gesture" is the
        // flickering tail of a system gesture — barred from swiping for its whole life
        // (see `reArmQuarantine`). Birth-time, not entry-time: a four-finger swipe that
        // sheds a finger and continues on three would otherwise just outlive the window
        // and fire the phantom ⌘Tab 0.3 s late. Also barred when ANY path arrives
        // already well-travelled: 30 mm of pre-birth motion is a contact that was
        // moving long before this gesture armed — a two-finger scroll a third finger
        // just dropped onto (or whose other scroll finger just lifted) — which would
        // carry its scroll momentum straight over the step threshold.
        bornInSystemGestureTail = timestamp < swipeQuarantineUntil || scrollBornPaths >= 1
        // The tap is additionally barred by every abnormal-end quarantine, and by
        // touches that have already travelled (a pinch mid-flight whose thumb just slid
        // into the palm filter's edge band). Travel does NOT bar the swipe: a
        // legitimate swipe can arm late with accumulated travel when a finger starts
        // inside the edge band and sweeps out of it.
        bornTapQuarantined = timestamp < quarantineUntil
        movedTooFar = bornTapQuarantined || maxPathTravelMM > tapPathTravelCancelMM
        suppressionLatched = true
        onGestureActiveChanged?(true)
    }

    private func handleTracking(quarantineCount: Int, valid: Int, cx: Float, cy: Float, maxPathTravelMM: Float,
                                timestamp: Double, config: Config, widthMM: Float, heightMM: Float) {
        if quarantineCount >= 4 {
            // 4+ fingers belong to the system (Mission Control, Launchpad, show
            // desktop, Spaces). Quarantine the re-arm: those gestures' tails flicker
            // through exactly three contacts, which must not open a fresh tap OR
            // swipe window. Quarantine-counted, not merely physical: a palm-filtered
            // fourth contact only counts once it moves, so a resting thumb mid-pad
            // doesn't kill an in-flight gesture — but a moving filtered fourth finger
            // still exposes a system gesture within a frame or two.
            quarantineFourFingerSighting(at: timestamp)
            reset()
            return
        }
        if let pending = swipePendingSince {
            // A swipe entry is held awaiting confirmation that no 4th finger is still
            // landing (see `entryConfirmDelay`). Nothing has been posted yet, so the
            // 4+ branch above disposes of a straggler-revealed system gesture silently.
            if valid == 0 {
                // Clean lift during the hold: a quick flick. No 4th finger can be
                // arriving through a falling count — confirm and commit right now, so
                // the hold adds zero latency to the flick-and-lift switch. Re-validate
                // the toggle at commit like the timed path below. (No quarantine
                // re-check needed here or in the debounce path: pending can only
                // exist when !bornInSystemGestureTail, and any sighting that would
                // advance swipeQuarantineUntil resets the gesture — clearing
                // pending — before this code runs.)
                if config.appSwitchEnabled {
                    onAction?(.swipeBegin)
                    onAction?(.swipeStep(.forward))
                    onAction?(.swipeCommit)
                }
                reset()
                return
            }
            if valid < 3 {
                // Sub-3 during the hold: a staggered lift, or a one-frame dropout.
                // Debounce exactly like handleSwiping's commit path — don't emit while
                // a dropout could still be a landing straggler mid-flicker.
                lowFrameCount += 1
                if lowFrameCount >= endDebounceFrames {
                    if config.appSwitchEnabled {
                        onAction?(.swipeBegin)
                        onAction?(.swipeStep(.forward))
                        onAction?(.swipeCommit)
                    }
                    reset()
                }
                return
            }
            lowFrameCount = 0
            if timestamp - pending >= entryConfirmDelay {
                // Re-validate at commit time, not just at arm: the user can toggle
                // app-switching off mid-hold, and the quarantine can also have
                // armed (a 4+ sighting during the delay) since the entry fired.
                if config.appSwitchEnabled, !bornInSystemGestureTail,
                   timestamp >= swipeQuarantineUntil {
                    enterSwiping(cx: cx, cy: cy, timestamp: timestamp)
                } else {
                    swipePendingSince = nil   // silently abandon — nothing posted yet
                }
            }
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
                tapQuar=\(self.bornTapQuarantined) swipeQuar=\(self.bornInSystemGestureTail) \
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
            if valid == 3, config.appSwitchEnabled, !bornInSystemGestureTail,
               adx >= config.swipeDistanceMM, adx > entryDominance * ady {
                // Entry conditions met — HOLD rather than emit (see `entryConfirmDelay`
                // and the pending block above). The anchor stays put: travel keeps
                // accumulating, and enterSwiping re-anchors at confirmation anyway.
                swipePendingSince = timestamp
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
            quarantineUntil = timestamp + reArmQuarantine
            reset()
            return
        }
        // valid == 3 at this point. macOS only synthesizes a native click from a
        // TAP-like contact — brief and near-stationary — so once this gesture has
        // outlived the tap window there is no synthesized click left to suppress:
        // release the latch instead of eating the user's real clicks (on a mouse
        // too — the tap is system-wide) for as long as three fingers happen to
        // rest on the surface. Tracking continues — a swipe can still start —
        // and enterSwiping re-latches. Unreachable while a swipe is pending (the
        // pending branch above returns first); a pending that began AFTER a release
        // simply stays unlatched until enterSwiping fires — fine, since a post-window
        // gesture can't synthesize a click anyway. Tails armed by this `false` cover
        // the exact release moment.
        if suppressionLatched, swipePendingSince == nil, timestamp - startTime > tapMaxDuration {
            suppressionLatched = false
            onGestureActiveChanged?(false)
        }
    }

    private func enterSwiping(cx: Float, cy: Float, timestamp: Double) {
        phase = .swiping
        swipePendingSince = nil
        swipeStartTime = timestamp
        // Re-latch click suppression if the gesture outlived the tap window before
        // swiping (handleTracking released it): real user clicks are eaten for the
        // duration of a switch, same as a scrub that started inside the window.
        if !suppressionLatched {
            suppressionLatched = true
            onGestureActiveChanged?(true)
        }
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

    private func handleSwiping(quarantineCount: Int, valid: Int, cx: Float, cy: Float, timestamp: Double,
                               distanceMM: Float, widthMM: Float, heightMM: Float) {
        if quarantineCount >= 4 {
            onAction?(.cancel)
            quarantineFourFingerSighting(at: timestamp)
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
        if adx >= distanceMM {
            if adx > stepDominance * ady {
                // Suppress steps until the HUD is up: travel before then only ever yields
                // the single switch already emitted on `.swipeBegin`. Re-anchor either way
                // so the swallowed travel is consumed — no catch-up burst the instant the
                // HUD appears.
                if timestamp - swipeStartTime >= hudRevealDelay {
                    onAction?(.swipeStep(dxMM > 0 ? .forward : .backward))
                }
                anchorX = cx          // reset anchor so a long sweep steps repeatedly
                anchorY = cy
            } else {
                // Enough horizontal travel but the diagonal component broke dominance —
                // a curved swipe drifting vertically. Absorb the vertical excursion
                // (horizontal progress keeps accumulating toward the step): otherwise
                // the stale Y anchor lets the curve block stepping until the hand
                // travels far enough horizontally to out-grow it.
                anchorY = cy
            }
        }
    }

    /// Clear all state back to idle without emitting any action. The engine calls this
    /// before `start()` so a restart never resumes a stale phase left by a run that
    /// stopped mid-gesture. Serialized behind `processLock` — a frame already in
    /// flight on a device thread can't tear the state mid-reset. Also drops both
    /// quarantines: a fresh stream's timestamp domain may differ, so a stale deadline
    /// could quarantine forever (or not at all).
    func resetState() {
        processLock.lock()
        defer { processLock.unlock() }
        clearGesture()
        quarantineUntil = 0
        swipeQuarantineUntil = 0
        pathAnchors.removeAll(keepingCapacity: true)
        frameIndex = 0
    }

    /// End the current gesture (back to idle) without emitting any action. The tap
    /// quarantine deliberately survives — the sites that set it do so right before
    /// calling this.
    private func reset() {
        // Emit the "gesture over" edge only when the click-suppression latch is still
        // ours to release. A gesture that already outlived its tap window released the
        // latch mid-rest (see handleTracking); a second `false` here would re-arm the
        // post-gesture suppression tails and swallow the user's real click that lands
        // right after those fingers lift — a lift that old can't synthesize a click,
        // so the tail has nothing to suppress.
        let wasLatched = suppressionLatched
        clearGesture()
        if wasLatched { onGestureActiveChanged?(false) }
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
        bornInSystemGestureTail = false
        bornTapQuarantined = false
        swipePendingSince = nil
        swipeStartTime = 0
        lastTimestamp = 0
        lowFrameCount = 0
        suppressionLatched = false
    }

    /// Whether a position sits inside the edge/bottom exclusion band (measured in mm
    /// in from the left, right, and bottom rim — the top edge is deliberately exempt
    /// since real swipes start there). The band filters rim contacts while a gesture
    /// is only just starting, and feeds the `parked` latch in `notePathTravel` — a
    /// contact that lands or settles inside it and never moves stays filtered for
    /// its whole still life: the resting-thumb case.
    private func inEdgeBand(_ p: MTPoint, edgeBandMM: Float,
                            widthMM: Float, heightMM: Float) -> Bool {
        let xMM = p.x * widthMM
        let yMM = p.y * heightMM
        return xMM < edgeBandMM || xMM > widthMM - edgeBandMM || yMM < edgeBandMM
    }
}
