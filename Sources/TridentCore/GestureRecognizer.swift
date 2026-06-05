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

    // Swipe geometry.
    private let entryDominance: Float = 1.5   // |Δx| must beat |Δy| by this to start a swipe
    private let stepDominance: Float = 1.0    // looser once a swipe is underway

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
    private var startTime: Double = 0
    private var frameCount: Int = 0
    private var lastValidCount: Int = 0
    private var movedTooFar = false
    private var swipeStartTime: Double = 0

    // MARK: Hot path

    func process(_ touches: UnsafePointer<MTTouch>, count: Int, timestamp: Double,
                 widthMM: Float, heightMM: Float) {
        let cfg = config.withLock { $0 }

        // The edge band only filters palms when a gesture is *starting*; once we're
        // tracking, fingers are free to sweep toward an edge without being dropped.
        let entering = phase == .idle

        // Centroid of valid (non-palm) contacts — a tight, allocation-free loop.
        var sumX: Float = 0
        var sumY: Float = 0
        var valid = 0
        for i in 0..<count {
            let t = touches[i]
            guard TouchState.isContact(t.state) else { continue }
            let p = t.normalizedVector.position
            if isPalm(position: p, size: t.zTotal, edgeBandMM: cfg.palmEdgeBandMM,
                      maxSize: cfg.palmMaxSize, widthMM: widthMM, heightMM: heightMM,
                      applyEdgeBand: entering) {
                continue
            }
            sumX += p.x
            sumY += p.y
            valid += 1
        }
        let cx = valid > 0 ? sumX / Float(valid) : 0
        let cy = valid > 0 ? sumY / Float(valid) : 0

        switch phase {
        case .idle:
            // Only arm a gesture when at least one mapping can actually fire; otherwise
            // three fingers would needlessly drive the click suppressor for no benefit.
            if valid == 3, cfg.middleClickEnabled || cfg.appSwitchEnabled {
                beginTracking(cx: cx, cy: cy, timestamp: timestamp)
            }
        case .tracking:
            handleTracking(valid: valid, cx: cx, cy: cy, timestamp: timestamp,
                           config: cfg, widthMM: widthMM, heightMM: heightMM)
        case .swiping:
            handleSwiping(valid: valid, cx: cx, cy: cy, timestamp: timestamp,
                          distanceMM: cfg.swipeDistanceMM, widthMM: widthMM, heightMM: heightMM)
        }
        lastValidCount = valid
    }

    // MARK: Phases

    private func beginTracking(cx: Float, cy: Float, timestamp: Double) {
        phase = .tracking
        anchorX = cx
        anchorY = cy
        startTime = timestamp
        frameCount = 1
        movedTooFar = false
        onGestureActiveChanged?(true)
    }

    private func handleTracking(valid: Int, cx: Float, cy: Float, timestamp: Double,
                                config: Config, widthMM: Float, heightMM: Float) {
        if valid >= 4 {
            reset()  // 4+ fingers belong to the system (Mission Control, etc.)
            return
        }
        if valid == 0 {
            // All fingers lifted: fire a middle click if this was a clean tap.
            let elapsed = timestamp - startTime
            if config.middleClickEnabled, !movedTooFar, frameCount >= tapMinFrames,
               elapsed >= tapMinDuration, elapsed <= tapMaxDuration {
                onAction?(.middleClick)
            }
            reset()
            return
        }
        if valid == 3 {
            if lastValidCount != 3 {
                // Re-acquired three fingers after a dip — re-anchor so the
                // centroid jump doesn't read as travel.
                anchorX = cx
                anchorY = cy
                return
            }
            frameCount += 1
            let dxMM = (cx - anchorX) * widthMM
            let dyMM = (cy - anchorY) * heightMM
            let adx = abs(dxMM), ady = abs(dyMM)
            if config.appSwitchEnabled, adx >= config.swipeDistanceMM, adx > entryDominance * ady {
                enterSwiping(dx: dxMM, cx: cx, cy: cy, timestamp: timestamp)
            } else if hypotf(dxMM, dyMM) > tapMoveCancelMM {
                movedTooFar = true
            }
        }
        // valid == 1 or 2: a transitional lift — keep waiting.
    }

    private func enterSwiping(dx: Float, cx: Float, cy: Float, timestamp: Double) {
        phase = .swiping
        swipeStartTime = timestamp
        onAction?(.swipeBegin)
        onAction?(.swipeStep(dx > 0 ? .forward : .backward))
        anchorX = cx
        anchorY = cy
    }

    private func handleSwiping(valid: Int, cx: Float, cy: Float, timestamp: Double,
                               distanceMM: Float, widthMM: Float, heightMM: Float) {
        if valid >= 4 {
            onAction?(.cancel)
            reset()
            return
        }
        if valid <= 1 {
            onAction?(.swipeCommit)
            reset()
            return
        }
        // 2 or 3 fingers still down.
        if valid != lastValidCount {
            anchorX = cx          // re-anchor on a finger add/relift
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
    /// the engine calls it.
    func resetState() {
        phase = .idle
        anchorX = 0
        anchorY = 0
        startTime = 0
        frameCount = 0
        lastValidCount = 0
        movedTooFar = false
        swipeStartTime = 0
    }

    private func reset() {
        resetState()
        onGestureActiveChanged?(false)
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
