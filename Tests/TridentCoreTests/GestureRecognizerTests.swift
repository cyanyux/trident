import XCTest
@testable import TridentCore

/// Drives `GestureRecognizer` with synthetic touch frames and asserts the stream
/// of abstract actions it emits — no Accessibility permission or event posting.
final class GestureRecognizerTests: XCTestCase {

    private var recognizer: GestureRecognizer!
    private var actions: [GestureAction]!

    override func setUp() {
        super.setUp()
        recognizer = GestureRecognizer()
        actions = []
        recognizer.onAction = { [weak self] action in self?.actions.append(action) }
        // Frames are fed against a 100 mm × 100 mm reference surface (see `feed`), so
        // a normalized delta of 0.12 is 12 mm. Pinning the distance here keeps these
        // frame distances meaningful even as the shipping default is tuned.
        recognizer.setSwipeDistance(12)
    }

    /// Reference trackpad size for the tests: 100 mm square, so 1 normalized unit =
    /// 100 mm and every fractional threshold reads as that many millimetres.
    private let refMM: Float = 100

    // MARK: - Helpers

    /// A single active contact at a normalized position (size below the palm cutoff).
    private func contact(_ x: Float, _ y: Float) -> MTTouch {
        MTTouch(
            frame: 0, timestamp: 0, pathIndex: 0, state: TouchState.active,
            fingerID: 0, handID: 0,
            normalizedVector: MTVector(position: MTPoint(x: x, y: y), velocity: MTPoint(x: 0, y: 0)),
            zTotal: 1.0, field9: 0, angle: 0, majorAxis: 0, minorAxis: 0,
            absoluteVector: MTVector(position: MTPoint(x: 0, y: 0), velocity: MTPoint(x: 0, y: 0)),
            field14: 0, field15: 0, zDensity: 0
        )
    }

    /// Three contacts whose centroid is (`centerX`, `centerY`), all clear of the edges.
    private func threeFingers(centerX: Float, centerY: Float = 0.5) -> [MTTouch] {
        [contact(centerX - 0.03, centerY), contact(centerX, centerY), contact(centerX + 0.03, centerY)]
    }

    /// Feed one frame. An empty frame still passes a valid pointer with count 0.
    private func feed(_ touches: [MTTouch], at timestamp: Double) {
        if touches.isEmpty {
            var dummy = contact(0, 0)
            withUnsafePointer(to: &dummy) {
                recognizer.process($0, count: 0, timestamp: timestamp, widthMM: refMM, heightMM: refMM)
            }
        } else {
            touches.withUnsafeBufferPointer { buffer in
                recognizer.process(buffer.baseAddress!, count: buffer.count, timestamp: timestamp,
                                   widthMM: refMM, heightMM: refMM)
            }
        }
    }

    // MARK: - Tap

    func testThreeFingerTapEmitsMiddleClick() {
        feed(threeFingers(centerX: 0.5), at: 0.00)   // begin tracking
        feed(threeFingers(centerX: 0.5), at: 0.05)   // second frame
        feed([], at: 0.08)                            // lift within tap window
        XCTAssertEqual(actions, [.middleClick])
    }

    /// A staggered lift (3 → 2 → 0) still resolves to a single middle click — the
    /// transitional two-finger frame neither swipes nor blocks the tap.
    func testStaggeredLiftStillMiddleClicks() {
        feed(threeFingers(centerX: 0.5), at: 0.00)                       // begin
        feed(threeFingers(centerX: 0.5), at: 0.04)                       // settle (2 frames)
        feed([contact(0.48, 0.5), contact(0.52, 0.5)], at: 0.06)         // one finger lifts
        feed([], at: 0.08)                                                // last fingers lift → click
        XCTAssertEqual(actions, [.middleClick])
    }

    /// A quick Launchpad pinch (thumb + three fingers) whose thumb was palm-rejected
    /// presents as three brief contacts converging on a *stationary centroid* — the
    /// blind spot of the centroid-travel check. The spread change must disqualify the
    /// tap, or launching Launchpad fires a stray middle click.
    func testThumbRejectedPinchDoesNotMiddleClick() {
        feed([contact(0.40, 0.5), contact(0.50, 0.5), contact(0.60, 0.5)], at: 0.00)
        feed([contact(0.46, 0.5), contact(0.50, 0.5), contact(0.54, 0.5)], at: 0.05)  // converging
        feed([], at: 0.08)                                                            // quick lift
        XCTAssertEqual(actions, [])
    }

    /// Same for show desktop: fingers fanning out around a stationary centroid.
    func testThumbRejectedSpreadDoesNotMiddleClick() {
        feed([contact(0.45, 0.5), contact(0.50, 0.5), contact(0.55, 0.5)], at: 0.00)
        feed([contact(0.38, 0.5), contact(0.50, 0.5), contact(0.62, 0.5)], at: 0.05)  // fanning out
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    /// Mid-pinch, converging fingertips merge into fewer sensor contacts — much of the
    /// travel shows up at *two* contacts. The spread check must keep watching there.
    func testPinchConvergingAtTwoContactsDoesNotMiddleClick() {
        feed([contact(0.40, 0.5), contact(0.50, 0.5), contact(0.60, 0.5)], at: 0.00)
        feed([contact(0.40, 0.5), contact(0.50, 0.5), contact(0.60, 0.5)], at: 0.02)
        feed([contact(0.44, 0.5), contact(0.56, 0.5)], at: 0.04)   // two fingers merged
        feed([contact(0.48, 0.5), contact(0.52, 0.5)], at: 0.06)   // still converging
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    /// A Launchpad pinch whose thumb IS counted shows 4 contacts mid-gesture, and its
    /// tail flickers back through exactly three as fingers merge and lift. The
    /// post-4-finger quarantine must keep that flicker from opening a fresh tap window.
    func testThreeContactFlickerAfterFourFingersDoesNotMiddleClick() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed([contact(0.35, 0.5), contact(0.45, 0.5), contact(0.55, 0.5), contact(0.65, 0.35)], at: 0.03)
        feed(threeFingers(centerX: 0.5), at: 0.05)   // tail flicker — re-arms quarantined
        feed(threeFingers(centerX: 0.5), at: 0.08)
        feed([], at: 0.10)                            // quick lift inside the tap window
        XCTAssertEqual(actions, [])
    }

    /// Same for the sub-3 dwell bound: a slow pinch dwells at two merged contacts long
    /// enough to trip it, then flickers back to three on the way out.
    func testThreeContactFlickerAfterDwellResetDoesNotMiddleClick() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed([contact(0.48, 0.5), contact(0.52, 0.5)], at: 0.20)   // dwell past tap window
        feed(threeFingers(centerX: 0.5), at: 0.25)                  // tail flicker
        feed(threeFingers(centerX: 0.5), at: 0.28)
        feed([], at: 0.31)
        XCTAssertEqual(actions, [])
    }

    /// A clean tap never quarantines — an immediate deliberate re-tap still clicks.
    func testRapidDoubleTapClicksTwice() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed(threeFingers(centerX: 0.5), at: 0.05)
        feed([], at: 0.08)
        feed(threeFingers(centerX: 0.5), at: 0.12)
        feed(threeFingers(centerX: 0.5), at: 0.16)
        feed([], at: 0.19)
        XCTAssertEqual(actions, [.middleClick, .middleClick])
    }

    func testSingleFrameTapIsIgnored() {
        feed(threeFingers(centerX: 0.5), at: 0.00)   // only one frame before lift
        feed([], at: 0.02)
        XCTAssertEqual(actions, [])
    }

    func testHeldTooLongIsNotATap() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed(threeFingers(centerX: 0.5), at: 0.10)
        feed([], at: 0.40)                            // elapsed > tapMaxDuration
        XCTAssertEqual(actions, [])
    }

    // MARK: - Swipe

    func testSwipeRightEmitsForwardThenCommit() {
        feed(threeFingers(centerX: 0.40), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)  // small move, not yet a swipe
        feed(threeFingers(centerX: 0.56), at: 0.04)  // crosses threshold → forward
        feed([], at: 0.08)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// A quick left flick (lifted before the HUD) switches to the *previous* app, not
    /// the oldest one: the first step always opens forward (⌘Tab), like tapping ⌘Tab.
    /// Direction only governs scrubbing once the HUD is up (next test).
    func testQuickLeftFlickSwitchesToPreviousApp() {
        feed(threeFingers(centerX: 0.60), at: 0.00)
        feed(threeFingers(centerX: 0.44), at: 0.02)  // crosses threshold leftward
        feed([], at: 0.06)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// Held past the HUD reveal, a leftward sweep scrubs *backward* (⌘⇧Tab): the first
    /// step opens forward, then each further leftward threshold steps back.
    func testLeftScrubWithHUDStepsBackward() {
        feed(threeFingers(centerX: 0.70), at: 0.00)
        feed(threeFingers(centerX: 0.54), at: 0.02)  // begin + first step (opens forward)
        feed(threeFingers(centerX: 0.38), at: 0.35)  // HUD up → backward
        feed(threeFingers(centerX: 0.22), at: 0.70)  // backward
        feed([], at: 0.75)
        XCTAssertEqual(actions, [
            .swipeBegin, .swipeStep(.forward), .swipeStep(.backward), .swipeStep(.backward), .swipeCommit,
        ])
    }

    /// A fast flick crosses several thresholds before the system app-switcher HUD can
    /// appear. Since the user can't see what they'd be cycling through, only the
    /// initial switch fires — the extra pre-HUD crossings are swallowed.
    func testFastSweepSwitchesOnce() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.44), at: 0.02)  // begin + step
        feed(threeFingers(centerX: 0.58), at: 0.04)  // crossing, but pre-HUD → swallowed
        feed(threeFingers(centerX: 0.72), at: 0.06)  // crossing, but pre-HUD → swallowed
        feed([], at: 0.08)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// Spacing the threshold crossings past the HUD reveal delay lets a deliberate
    /// sweep scrub through several apps — once the HUD is up, each further threshold
    /// steps again.
    func testSlowSweepStepsOncePerThresholdWithHUD() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.44), at: 0.02)  // begin + first step
        feed(threeFingers(centerX: 0.58), at: 0.35)  // HUD up → step
        feed(threeFingers(centerX: 0.72), at: 0.70)  // step
        feed([], at: 0.75)
        XCTAssertEqual(actions, [
            .swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeStep(.forward), .swipeCommit,
        ])
    }

    func testVerticalSwipeDoesNothing() {
        feed(threeFingers(centerX: 0.5, centerY: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.5, centerY: 0.50), at: 0.02)
        feed(threeFingers(centerX: 0.5, centerY: 0.70), at: 0.04)
        feed([], at: 0.30)
        XCTAssertEqual(actions, [])
    }

    // MARK: - Cancellation

    func testFourFingersCancelActiveSwipe() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)  // begin + step
        feed([contact(0.2, 0.5), contact(0.4, 0.5), contact(0.6, 0.5), contact(0.8, 0.5)], at: 0.04)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .cancel])
    }

    func testFourFingersInTrackingResetsSilently() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed([contact(0.2, 0.5), contact(0.4, 0.5), contact(0.6, 0.5), contact(0.8, 0.5)], at: 0.02)
        feed([], at: 0.04)
        XCTAssertEqual(actions, [])
    }

    /// A stalled touch stream (sleep, disconnect, Bluetooth drop) that resumes mid-swipe
    /// is abandoned, not continued: the recognizer emits `.cancel` — releasing ⌘ even if
    /// the synthesizer's watchdog hasn't yet — and returns to idle, so the resuming
    /// fingers start a fresh gesture instead of stepping a switcher that's already gone.
    func testStalledStreamAbandonsInFlightSwipe() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)  // swipeBegin + forward step
        feed(threeFingers(centerX: 0.62), at: 2.50)  // >2 s gap → abandon (.cancel), re-arm fresh
        feed([], at: 2.54)                            // fresh tracking, single frame → no tap
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .cancel])
    }

    /// A frame gap of *exactly* `staleStreamGap` is not a stall (the check is strict
    /// `>`), so the gesture continues rather than being abandoned — guards the boundary.
    func testFrameGapAtStaleThresholdDoesNotAbandon() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)   // begin + forward; lastTimestamp = 0.02
        feed(threeFingers(centerX: 0.62), at: 2.02)   // gap == 2.0 (not > 2.0) → continues; HUD up → step
        feed([], at: 2.05)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// A threshold crossing landing *exactly* at the HUD-reveal delay steps (the check is
    /// `>=`), not swallowed — guards the boundary between the pre-HUD single switch and
    /// post-HUD scrubbing.
    func testStepAtHUDRevealBoundaryEmits() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)   // begin + forward; swipeStartTime = 0.02
        feed(threeFingers(centerX: 0.62), at: 0.27)   // 0.27 - 0.02 == 0.25 == hudRevealDelay → steps
        feed([], at: 0.30)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// Only three fingers drive the switch. Dropping to two fingers mid-swipe must NOT
    /// keep stepping (that would switch on two fingers and fight the native two-finger
    /// swipe); after the short debounce the gesture just commits.
    func testTwoFingersDoNotStep() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)                  // begin + first step
        feed([contact(0.50, 0.5), contact(0.56, 0.5)], at: 0.04)    // 2 fingers, moving — no step
        feed([contact(0.66, 0.5), contact(0.72, 0.5)], at: 0.06)    // 2 fingers, moving — no step
        feed([contact(0.82, 0.5), contact(0.88, 0.5)], at: 0.08)    // 2 fingers persist → commit
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// A one-frame contact dropout mid-scrub is absorbed (debounced): the swipe neither
    /// commits early nor steps on the dip, and resumes stepping once three fingers return.
    func testTransientFingerDipDoesNotCommit() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)   // begin + first step
        feed([contact(0.50, 0.5)], at: 0.04)          // 1-frame dropout to one contact — absorbed
        feed(threeFingers(centerX: 0.62), at: 0.40)   // three back, HUD up → re-anchor, no phantom step
        feed(threeFingers(centerX: 0.80), at: 0.42)   // real travel → one more step
        feed([], at: 0.45)                            // lift → commit
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    // MARK: - Suppression lifecycle

    func testGestureActiveTogglesAroundTap() {
        var changes: [Bool] = []
        recognizer.onGestureActiveChanged = { changes.append($0) }
        feed(threeFingers(centerX: 0.5), at: 0.00)   // active true
        feed(threeFingers(centerX: 0.5), at: 0.05)
        feed([], at: 0.08)                            // active false
        XCTAssertEqual(changes, [true, false])
    }

    func testGestureStaysActiveThroughSwipeUntilCommit() {
        var changes: [Bool] = []
        recognizer.onGestureActiveChanged = { changes.append($0) }
        feed(threeFingers(centerX: 0.30), at: 0.00)  // active true
        feed(threeFingers(centerX: 0.46), at: 0.02)  // mid-swipe, no change
        feed(threeFingers(centerX: 0.62), at: 0.04)  // mid-swipe, no change
        feed([], at: 0.06)                            // active false on commit
        XCTAssertEqual(changes, [true, false])
    }

    /// Fingers left resting below three (e.g. a three-finger touch reduced to two) must
    /// release the gesture-active latch once the tap window has passed — otherwise the
    /// suppressor keeps eating every click system-wide for as long as the fingers rest.
    func testRestingTwoFingersReleaseGestureAfterTapWindow() {
        var changes: [Bool] = []
        recognizer.onGestureActiveChanged = { changes.append($0) }
        feed(threeFingers(centerX: 0.5), at: 0.00)                       // active true
        feed([contact(0.48, 0.5), contact(0.52, 0.5)], at: 0.05)         // dip — keep waiting
        feed([contact(0.48, 0.5), contact(0.52, 0.5)], at: 0.10)         // still inside tap window
        feed([contact(0.48, 0.5), contact(0.52, 0.5)], at: 0.20)         // window passed → release
        feed([contact(0.48, 0.5), contact(0.52, 0.5)], at: 1.00)         // resting on — stays released
        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(actions, [])
    }

    /// After that release, a returning third finger arms a fresh gesture — nothing is
    /// lost by ending the dangling one.
    func testThirdFingerReturningAfterReleaseStartsFreshGesture() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed([contact(0.28, 0.5), contact(0.32, 0.5)], at: 0.20)          // dangling → released
        feed(threeFingers(centerX: 0.30), at: 0.30)                       // re-armed from idle
        feed(threeFingers(centerX: 0.46), at: 0.32)                       // swipes normally
        feed([], at: 0.36)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    // MARK: - Per-feature toggles

    func testMiddleClickDisabledSuppressesTap() {
        recognizer.setMiddleClickEnabled(false)
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed(threeFingers(centerX: 0.5), at: 0.05)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    func testAppSwitchDisabledDoesNotSwitch() {
        recognizer.setAppSwitchEnabled(false)
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.50), at: 0.02)  // would normally start a swipe
        feed(threeFingers(centerX: 0.70), at: 0.04)
        feed([], at: 0.06)
        XCTAssertEqual(actions, [])
    }

    func testAppSwitchDisabledStillAllowsMiddleClick() {
        recognizer.setAppSwitchEnabled(false)
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed(threeFingers(centerX: 0.5), at: 0.05)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [.middleClick])
    }

    /// With both mappings off, three fingers must not arm a gesture at all — so the
    /// click suppressor is never driven and no native clicks are needlessly eaten.
    func testBothFeaturesDisabledNeverActivatesGesture() {
        recognizer.setMiddleClickEnabled(false)
        recognizer.setAppSwitchEnabled(false)
        var changes: [Bool] = []
        recognizer.onGestureActiveChanged = { changes.append($0) }
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed(threeFingers(centerX: 0.5), at: 0.05)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
        XCTAssertEqual(changes, [])
    }

    // MARK: - Palm rejection

    /// The left contact sits 8 mm from the edge (0.08 × 100 mm) — inside the 'Strong'
    /// 11 mm band but outside the 'Standard' 7 mm band, so the two levels diverge.
    /// The other two are well clear of every band.
    private func nearEdgeThreeFingers() -> [MTTouch] {
        [contact(0.08, 0.5), contact(0.5, 0.5), contact(0.85, 0.5)]
    }

    func testStrongPalmRejectionDropsEdgeContact() {
        recognizer.setPalmRejection(edgeBandMM: 11, maxSize: 1.2)
        feed(nearEdgeThreeFingers(), at: 0.00)   // only 2 valid → never tracks 3
        feed(nearEdgeThreeFingers(), at: 0.05)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    func testStandardPalmRejectionKeepsContactNearEdge() {
        recognizer.setPalmRejection(edgeBandMM: 7, maxSize: 1.5)
        feed(nearEdgeThreeFingers(), at: 0.00)   // 3 valid → clean tap
        feed(nearEdgeThreeFingers(), at: 0.05)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [.middleClick])
    }

    /// A finger that sweeps into the edge band *after* the gesture has started must
    /// stay counted — the edge band only filters palms at gesture start. Otherwise a
    /// rightward swipe would drop its leading finger, jump the centroid, and stall.
    func testFingerSweepingIntoEdgeBandMidSwipeStillSteps() {
        recognizer.setPalmRejection(edgeBandMM: 5, maxSize: 1.5)
        feed([contact(0.40, 0.5), contact(0.50, 0.5), contact(0.60, 0.5)], at: 0.00)  // clean start
        // Sweep right until the leading finger is inside the 0.95 edge band.
        feed([contact(0.78, 0.5), contact(0.88, 0.5), contact(0.98, 0.5)], at: 0.02)
        feed([], at: 0.06)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    func testOversizedContactRejectedAsPalm() {
        var palm = contact(0.5, 0.5)
        palm.zTotal = 3.0                         // bigger than any level's cap
        let frame = [contact(0.4, 0.5), contact(0.6, 0.5), palm]
        feed(frame, at: 0.00)                      // palm dropped → only 2 valid
        feed(frame, at: 0.05)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }
}
