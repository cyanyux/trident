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
    /// `path` is the sensor's persistent per-touch identity — frames describing the
    /// same physical finger across time must reuse the same path, like the hardware.
    private func contact(_ x: Float, _ y: Float, path: Int32 = 0) -> MTTouch {
        MTTouch(
            frame: 0, timestamp: 0, pathIndex: path, state: TouchState.touching,
            fingerID: 0, handID: 0,
            normalizedVector: MTVector(position: MTPoint(x: x, y: y), velocity: MTPoint(x: 0, y: 0)),
            zTotal: 1.0, field9: 0, angle: 0, majorAxis: 0, minorAxis: 0,
            absoluteVector: MTVector(position: MTPoint(x: 0, y: 0), velocity: MTPoint(x: 0, y: 0)),
            field14: 0, field15: 0, zDensity: 0
        )
    }

    /// Three contacts whose centroid is (`centerX`, `centerY`), all clear of the edges.
    /// Paths 0/1/2 left-to-right, consistently across frames.
    private func threeFingers(centerX: Float, centerY: Float = 0.5) -> [MTTouch] {
        [contact(centerX - 0.03, centerY, path: 0),
         contact(centerX, centerY, path: 1),
         contact(centerX + 0.03, centerY, path: 2)]
    }

    /// Four contacts whose centroid is (`centerX`, `centerY`) — a system gesture
    /// (Spaces swipe, Mission Control) as the sensor sees it. Paths 0/1/2/3.
    private func fourFingers(centerX: Float, centerY: Float = 0.5) -> [MTTouch] {
        [contact(centerX - 0.045, centerY, path: 0),
         contact(centerX - 0.015, centerY, path: 1),
         contact(centerX + 0.015, centerY, path: 2),
         contact(centerX + 0.045, centerY, path: 3)]
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
        feed([contact(0.48, 0.5, path: 0), contact(0.52, 0.5, path: 2)], at: 0.06)  // one finger lifts
        feed([], at: 0.08)                                                // last fingers lift → click
        XCTAssertEqual(actions, [.middleClick])
    }

    /// A quick Launchpad pinch (thumb + three fingers) whose thumb was palm-rejected
    /// presents as three brief contacts converging on a *stationary centroid* — the
    /// blind spot of the centroid-travel check. The spread change must disqualify the
    /// tap, or launching Launchpad fires a stray middle click.
    func testThumbRejectedPinchDoesNotMiddleClick() {
        feed([contact(0.40, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.60, 0.5, path: 2)], at: 0.00)
        feed([contact(0.46, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.54, 0.5, path: 2)], at: 0.05)  // converging
        feed([], at: 0.08)                                                            // quick lift
        XCTAssertEqual(actions, [])
    }

    /// Same for show desktop: fingers fanning out around a stationary centroid.
    func testThumbRejectedSpreadDoesNotMiddleClick() {
        feed([contact(0.45, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.55, 0.5, path: 2)], at: 0.00)
        feed([contact(0.38, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.62, 0.5, path: 2)], at: 0.05)  // fanning out
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    /// Mid-pinch, converging fingertips merge into fewer sensor contacts — much of the
    /// travel shows up at *two* contacts. The spread check must keep watching there.
    func testPinchConvergingAtTwoContactsDoesNotMiddleClick() {
        feed([contact(0.40, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.60, 0.5, path: 2)], at: 0.00)
        feed([contact(0.40, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.60, 0.5, path: 2)], at: 0.02)
        feed([contact(0.44, 0.5, path: 0), contact(0.56, 0.5, path: 2)], at: 0.04)   // two fingers merged
        feed([contact(0.48, 0.5, path: 0), contact(0.52, 0.5, path: 2)], at: 0.06)   // still converging
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    /// A Launchpad pinch whose thumb IS counted shows 4 contacts mid-gesture, and its
    /// tail flickers back through exactly three as fingers merge and lift. The
    /// post-4-finger quarantine must keep that flicker from opening a fresh tap window.
    func testThreeContactFlickerAfterFourFingersDoesNotMiddleClick() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed([contact(0.35, 0.5, path: 0), contact(0.45, 0.5, path: 1), contact(0.55, 0.5, path: 2), contact(0.65, 0.35, path: 3)], at: 0.03)
        feed(threeFingers(centerX: 0.5), at: 0.05)   // tail flicker — re-arms quarantined
        feed(threeFingers(centerX: 0.5), at: 0.08)
        feed([], at: 0.10)                            // quick lift inside the tap window
        XCTAssertEqual(actions, [])
    }

    /// Same for the sub-3 dwell bound: a slow pinch dwells at two merged contacts long
    /// enough to trip it, then flickers back to three on the way out.
    func testThreeContactFlickerAfterDwellResetDoesNotMiddleClick() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed([contact(0.48, 0.5, path: 0), contact(0.52, 0.5, path: 2)], at: 0.20)   // dwell past tap window
        feed(threeFingers(centerX: 0.5), at: 0.25)                  // tail flicker
        feed(threeFingers(centerX: 0.5), at: 0.28)
        feed([], at: 0.31)
        XCTAssertEqual(actions, [])
    }

    /// Contact-count flicker must not launder pinch travel. The centroid (and the old
    /// spread) checks re-anchor on every count change — necessary, since different
    /// contact sets aren't comparable — so a pinch whose count alternates 3→2→3 shed
    /// all its motion evidence and still clicked. Per-path travel is identity-based
    /// and survives the flicker.
    func testCountFlickerDoesNotLaunderPinchTravel() {
        feed([contact(0.40, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.60, 0.5, path: 2)], at: 0.00)
        feed([contact(0.40, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.60, 0.5, path: 2)], at: 0.02)
        feed([contact(0.44, 0.5, path: 0), contact(0.56, 0.5, path: 2)], at: 0.04)   // dip while converging
        feed([contact(0.46, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.54, 0.5, path: 2)], at: 0.06)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    /// The pinching thumb itself — palm-rejected for size, so invisible to the
    /// centroid — must still disqualify the tap by its own travel.
    func testPalmRejectedMovingThumbCancelsTap() {
        var thumb = contact(0.5, 0.2, path: 9)
        thumb.zTotal = 3.0                            // over the size cap → palm-rejected
        var thumbLater = contact(0.5, 0.4, path: 9)   // slid 20 mm
        thumbLater.zTotal = 3.0
        feed(threeFingers(centerX: 0.5) + [thumb], at: 0.00)
        feed(threeFingers(centerX: 0.5) + [thumbLater], at: 0.05)
        feed([], at: 0.08)
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
        feed(threeFingers(centerX: 0.56), at: 0.04)  // crosses threshold → entry held
        feed([], at: 0.08)                            // lift confirms → begin + forward + commit
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// A quick left flick (lifted before the HUD) switches to the *previous* app, not
    /// the oldest one: the first step always opens forward (⌘Tab), like tapping ⌘Tab.
    /// Direction only governs scrubbing once the HUD is up (next test).
    func testQuickLeftFlickSwitchesToPreviousApp() {
        feed(threeFingers(centerX: 0.60), at: 0.00)
        feed(threeFingers(centerX: 0.44), at: 0.02)  // crosses threshold leftward → held
        feed([], at: 0.06)                            // lift confirms instantly — no added latency
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// Held past the HUD reveal, a leftward sweep scrubs *backward* (⌘⇧Tab): the first
    /// step opens forward, then each further leftward threshold steps back.
    func testLeftScrubWithHUDStepsBackward() {
        feed(threeFingers(centerX: 0.70), at: 0.00)
        feed(threeFingers(centerX: 0.54), at: 0.02)  // crosses threshold → entry held
        feed(threeFingers(centerX: 0.54), at: 0.07)  // hold confirmed → begin + first step (opens forward)
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
        feed(threeFingers(centerX: 0.44), at: 0.02)  // crosses threshold → entry held
        feed(threeFingers(centerX: 0.58), at: 0.04)  // still inside the hold
        feed(threeFingers(centerX: 0.72), at: 0.06)  // hold confirmed → begin + step
        feed([], at: 0.08)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// Spacing the threshold crossings past the HUD reveal delay lets a deliberate
    /// sweep scrub through several apps — once the HUD is up, each further threshold
    /// steps again.
    func testSlowSweepStepsOncePerThresholdWithHUD() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.44), at: 0.02)  // crosses threshold → entry held
        feed(threeFingers(centerX: 0.44), at: 0.07)  // hold confirmed → begin + first step
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
        feed(threeFingers(centerX: 0.46), at: 0.02)  // crosses threshold → entry held
        feed(threeFingers(centerX: 0.46), at: 0.07)  // hold confirmed → begin + step
        feed([contact(0.2, 0.5, path: 0), contact(0.4, 0.5, path: 1), contact(0.6, 0.5, path: 2), contact(0.8, 0.5, path: 3)], at: 0.09)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .cancel])
    }

    func testFourFingersInTrackingResetsSilently() {
        feed(threeFingers(centerX: 0.5), at: 0.00)
        feed([contact(0.2, 0.5, path: 0), contact(0.4, 0.5, path: 1), contact(0.6, 0.5, path: 2), contact(0.8, 0.5, path: 3)], at: 0.02)
        feed([], at: 0.04)
        XCTAssertEqual(actions, [])
    }

    /// A stalled touch stream (sleep, disconnect, Bluetooth drop) that resumes mid-swipe
    /// is abandoned, not continued: the recognizer emits `.cancel` — releasing ⌘ even if
    /// the synthesizer's watchdog hasn't yet — and returns to idle, so the resuming
    /// fingers start a fresh gesture instead of stepping a switcher that's already gone.
    func testStalledStreamAbandonsInFlightSwipe() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)  // crosses threshold → entry held
        feed(threeFingers(centerX: 0.46), at: 0.07)  // hold confirmed → swipeBegin + forward step
        feed(threeFingers(centerX: 0.62), at: 2.50)  // >2 s gap → abandon (.cancel), re-arm fresh
        feed([], at: 2.54)                            // fresh tracking, single frame → no tap
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .cancel])
    }

    /// A frame gap of *exactly* `staleStreamGap` is not a stall (the check is strict
    /// `>`), so the gesture continues rather than being abandoned — guards the boundary.
    func testFrameGapAtStaleThresholdDoesNotAbandon() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)   // crosses threshold → entry held
        feed(threeFingers(centerX: 0.46), at: 0.07)   // hold confirmed → begin + forward; lastTimestamp = 0.07
        feed(threeFingers(centerX: 0.62), at: 2.07)   // gap == 2.0 (not > 2.0) → continues; HUD up → step
        feed([], at: 2.10)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// A threshold crossing landing *exactly* at the HUD-reveal delay steps (the check is
    /// `>=`), not swallowed — guards the boundary between the pre-HUD single switch and
    /// post-HUD scrubbing.
    func testStepAtHUDRevealBoundaryEmits() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)   // crosses threshold → entry held
        feed(threeFingers(centerX: 0.46), at: 0.07)   // hold confirmed → begin + forward; swipeStartTime = 0.07
        feed(threeFingers(centerX: 0.62), at: 0.32)   // 0.32 - 0.07 == 0.25 == hudRevealDelay → steps
        feed([], at: 0.35)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// Only three fingers drive the switch. Dropping to two fingers mid-swipe must NOT
    /// keep stepping (that would switch on two fingers and fight the native two-finger
    /// swipe); after the short debounce the gesture just commits.
    func testTwoFingersDoNotStep() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)                  // begin + first step
        feed([contact(0.50, 0.5, path: 1), contact(0.56, 0.5, path: 2)], at: 0.04)    // 2 fingers, moving — no step
        feed([contact(0.66, 0.5, path: 1), contact(0.72, 0.5, path: 2)], at: 0.06)    // 2 fingers, moving — no step
        feed([contact(0.82, 0.5, path: 1), contact(0.88, 0.5, path: 2)], at: 0.08)    // 2 fingers persist → commit
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// A one-frame contact dropout mid-scrub is absorbed (debounced): the swipe neither
    /// commits early nor steps on the dip, and resumes stepping once three fingers return.
    func testTransientFingerDipDoesNotCommit() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)   // crosses threshold → entry held
        feed(threeFingers(centerX: 0.46), at: 0.07)   // hold confirmed → begin + first step
        feed([contact(0.50, 0.5, path: 1)], at: 0.09)  // 1-frame dropout to one contact — absorbed
        feed(threeFingers(centerX: 0.62), at: 0.40)   // three back, HUD up → re-anchor, no phantom step
        feed(threeFingers(centerX: 0.80), at: 0.42)   // real travel → one more step
        feed([], at: 0.45)                            // lift → commit
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    // MARK: - System-gesture tail quarantine
    //
    // The tail of a four-finger system gesture (a Spaces swipe, Mission Control)
    // passes through exactly three fast-moving contacts as fingers lift. That tail
    // must never fire an app-switch: a phantom ⌘Tab posted mid-space-transition
    // wedged the Dock's Spaces state machine on-device ("Not finished animating
    // space changes"), killing four-finger gestures until the Dock was restarted.

    /// Four fingers landing in the same frame never pass through `.tracking`, so the
    /// quarantine must be armed from `.idle` — the swipe's three-contact tail, still
    /// moving fast enough to cross the step threshold, must not switch apps.
    func testFourFingerSwipeTailDoesNotAppSwitch() {
        feed(fourFingers(centerX: 0.70), at: 0.00)   // system Spaces swipe — recognizer idle
        feed(fourFingers(centerX: 0.60), at: 0.02)
        feed(threeFingers(centerX: 0.50), at: 0.04)  // one finger lifts first — tail arms quarantined
        feed(threeFingers(centerX: 0.34), at: 0.06)  // 16 mm left, over threshold — must not swipe
        feed([], at: 0.10)
        XCTAssertEqual(actions, [])
    }

    /// A four-finger swipe that sheds one finger and *continues* on three is still the
    /// system gesture's tail. The bar is fixed at the gesture's birth — it must not
    /// simply outlive the quarantine window and fire the phantom switch late.
    func testThreeFingerContinuationOfFourFingerSwipeDoesNotAppSwitch() {
        feed(fourFingers(centerX: 0.80), at: 0.00)
        feed(fourFingers(centerX: 0.70), at: 0.02)
        feed(threeFingers(centerX: 0.60), at: 0.04)  // pinky lifts, swipe carries on
        feed(threeFingers(centerX: 0.44), at: 0.06)  // over threshold — must not swipe
        feed(threeFingers(centerX: 0.28), at: 0.35)  // even beyond the quarantine window
        feed([], at: 0.40)
        XCTAssertEqual(actions, [])
    }

    /// Same for the staggered landing (3 land, 4th joins, back to 3): the flicker used
    /// to be tap-quarantined only, so the tail could still fire a phantom app-switch.
    func testThreeContactFlickerAfterFourFingersDoesNotSwipe() {
        feed(threeFingers(centerX: 0.50), at: 0.00)
        feed(fourFingers(centerX: 0.50), at: 0.03)   // 4th finger joins → quarantine + reset
        feed(threeFingers(centerX: 0.50), at: 0.05)  // tail flicker — re-arms quarantined
        feed(threeFingers(centerX: 0.34), at: 0.07)  // over threshold — must not swipe
        feed([], at: 0.10)
        XCTAssertEqual(actions, [])
    }

    /// The quarantine can't see a finger that hasn't landed: a four-finger swipe whose
    /// fingers land a frame or two apart arms tracking as a clean THREE-finger gesture,
    /// and a fast hand crosses the step threshold before the 4th contact registers.
    /// The entry hold must let the straggler show up and kill the gesture silently —
    /// nothing posted, nothing to cancel.
    func testStaggeredFourFingerLandingDoesNotAppSwitch() {
        feed(threeFingers(centerX: 0.70), at: 0.000)  // first three land, pinky not yet down
        feed(threeFingers(centerX: 0.66), at: 0.008)  // moving, under threshold
        feed(threeFingers(centerX: 0.55), at: 0.016)  // 15 mm — crosses threshold → entry held
        feed(fourFingers(centerX: 0.50), at: 0.024)   // pinky finally registers → silent reset
        feed([], at: 0.05)
        XCTAssertEqual(actions, [])
    }

    /// A contact dropout during the entry hold must not rush the emission: the count
    /// dipping is exactly what a mid-landing flicker looks like, so the hold debounces
    /// it — and the late 4th finger is still caught.
    func testFingerDipDuringEntryHoldStillCatchesLateFourth() {
        feed(threeFingers(centerX: 0.70), at: 0.000)
        feed(threeFingers(centerX: 0.55), at: 0.008)  // crosses threshold → entry held
        feed([contact(0.53, 0.5, path: 0), contact(0.57, 0.5, path: 2)], at: 0.016)  // 1-frame dip
        feed(fourFingers(centerX: 0.50), at: 0.024)   // 4th lands → silent reset
        feed([], at: 0.05)
        XCTAssertEqual(actions, [])
    }

    /// The quarantine is a window, not a latch: a deliberate three-finger swipe
    /// starting after it expires switches normally.
    func testSwipeAfterQuarantineExpiresSwitchesNormally() {
        feed(fourFingers(centerX: 0.50), at: 0.00)   // quarantine until 0.30
        feed([], at: 0.02)
        feed(threeFingers(centerX: 0.40), at: 0.40)  // born clean
        feed(threeFingers(centerX: 0.56), at: 0.42)
        feed([], at: 0.46)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
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
        feed([contact(0.48, 0.5, path: 0), contact(0.52, 0.5, path: 2)], at: 0.05)  // dip — keep waiting
        feed([contact(0.48, 0.5, path: 0), contact(0.52, 0.5, path: 2)], at: 0.10)  // still inside tap window
        feed([contact(0.48, 0.5, path: 0), contact(0.52, 0.5, path: 2)], at: 0.20)  // window passed → release
        feed([contact(0.48, 0.5, path: 0), contact(0.52, 0.5, path: 2)], at: 1.00)  // resting on — stays released
        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(actions, [])
    }

    /// After that release, a returning third finger arms a fresh gesture — nothing is
    /// lost by ending the dangling one.
    func testThirdFingerReturningAfterReleaseStartsFreshGesture() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed([contact(0.28, 0.5, path: 0), contact(0.32, 0.5, path: 2)], at: 0.20)  // dangling → released
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
        [contact(0.08, 0.5, path: 0), contact(0.5, 0.5, path: 1), contact(0.85, 0.5, path: 2)]
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
        feed([contact(0.40, 0.5, path: 0), contact(0.50, 0.5, path: 1), contact(0.60, 0.5, path: 2)], at: 0.00)  // clean start
        // Sweep right until the leading finger is inside the 0.95 edge band.
        feed([contact(0.78, 0.5, path: 0), contact(0.88, 0.5, path: 1), contact(0.98, 0.5, path: 2)], at: 0.02)
        feed([], at: 0.06)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    func testOversizedContactRejectedAsPalm() {
        var palm = contact(0.5, 0.5, path: 2)
        palm.zTotal = 3.0                         // bigger than any level's cap
        let frame = [contact(0.4, 0.5, path: 0), contact(0.6, 0.5, path: 1), palm]
        feed(frame, at: 0.00)                      // palm dropped → only 2 valid
        feed(frame, at: 0.05)
        feed([], at: 0.08)
        XCTAssertEqual(actions, [])
    }

    // MARK: - Four-finger quarantine (moving filtered contacts count)

    /// A palm-filtered fourth finger (oversized, mid-pad) doesn't stop a gesture
    /// from arming while it sits still — but the moment it MOVES it counts as
    /// fourth-finger evidence and the armed gesture is cancelled + quarantined.
    func testOversizedFourthFingerStillQuarantinesSwipe() {
        var big = contact(0.80, 0.5, path: 3)
        big.zTotal = 3.0                          // over the size cap → palm-filtered
        var bigMoved = contact(0.86, 0.5, path: 3)  // same path id, 6 mm of travel
        bigMoved.zTotal = 3.0
        feed(threeFingers(centerX: 0.40) + [big], at: 0.00)      // filtered, still → arms
        feed(threeFingers(centerX: 0.40) + [bigMoved], at: 0.02) // filtered + MOVING → quarantine
        feed(threeFingers(centerX: 0.40), at: 0.04)              // oversized lifts — tail barred
        feed(threeFingers(centerX: 0.56), at: 0.06)
        feed([], at: 0.10)
        XCTAssertEqual(actions, [])
    }

    /// A fourth finger landing inside the edge band is filtered to `valid == 3`,
    /// so a clean gesture arms — but the moment it MOVES it counts as fourth-finger
    /// evidence and the armed gesture is cancelled + quarantined. The old
    /// valid-count check never saw it at all and its tail swiped.
    func testEdgeFilteredFourthFingerStillQuarantines() {
        recognizer.setPalmRejection(edgeBandMM: 11, maxSize: 1.5)
        feed(threeFingers(centerX: 0.40) + [contact(0.04, 0.5, path: 3)], at: 0.00) // in band, still → arms
        feed(threeFingers(centerX: 0.40) + [contact(0.09, 0.5, path: 3)], at: 0.02) // 4th contact moving → cancel + quarantine
        feed(threeFingers(centerX: 0.40), at: 0.04)   // edge finger lifts — tail quarantined
        feed(threeFingers(centerX: 0.56), at: 0.06)   // over threshold — must not swipe
        feed([], at: 0.10)
        XCTAssertEqual(actions, [])
    }

    /// Mid-gesture the edge band no longer applies, and ANY fourth contact landing
    /// while tracking is a straggler candidate — it counts on the frame it lands
    /// (even an oversized one that never moves), so the armed gesture cancels and
    /// quarantines immediately rather than waiting for it to move.
    func testOversizedFourthFingerDuringTrackingResets() {
        var big = contact(0.80, 0.5, path: 3)
        big.zTotal = 3.0
        feed(threeFingers(centerX: 0.40), at: 0.00)              // tracking, 3 contacts
        feed(threeFingers(centerX: 0.40) + [big], at: 0.02)      // filtered landing mid-gesture → reset
        feed(threeFingers(centerX: 0.40), at: 0.06)              // tail — quarantined
        feed(threeFingers(centerX: 0.56), at: 0.08)              // must not swipe
        feed([], at: 0.12)
        XCTAssertEqual(actions, [])
    }

    /// The flip side of the movement gate: a palm-filtered contact that NEVER moves
    /// is a resting thumb, not a system gesture — three fingers resting next to it
    /// must still tap and swipe normally. Bars the regression where parking a thumb
    /// at the pad's rim disabled every gesture. The faithful posture: the thumb is
    /// down and settled BEFORE the fingers land — parking is earned by stillness,
    /// so a thumb landing simultaneously with the fingers stays unproven (that's a
    /// four-contact landing, which quarantines like any system gesture).
    func testRestingFilteredThumbDoesNotQuarantineGestures() {
        let thumb = contact(0.03, 0.5, path: 3)    // inside the default edge band
        for i in 0..<10 {                          // thumb down first, settles → parked
            feed([thumb], at: Double(i) * 0.02)
        }
        feed(threeFingers(centerX: 0.40) + [thumb], at: 0.30)
        feed(threeFingers(centerX: 0.40) + [thumb], at: 0.34)
        feed([], at: 0.38)
        XCTAssertEqual(actions, [.middleClick])
        actions.removeAll()
        // Same again for a swipe — the parked latch died with the full lift, so
        // the thumb settles again before the fingers come down.
        for i in 0..<10 {
            feed([thumb], at: 0.50 + Double(i) * 0.02)
        }
        feed(threeFingers(centerX: 0.30) + [thumb], at: 0.80)
        feed(threeFingers(centerX: 0.50) + [thumb], at: 0.82)   // crosses → held
        feed(threeFingers(centerX: 0.50) + [thumb], at: 0.88)   // confirm → begin + step
        feed(threeFingers(centerX: 0.70) + [thumb], at: 1.15)   // step past HUD delay
        feed([], at: 1.20)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// A fourth finger that lands WHILE a three-finger gesture sits in its
    /// swipe-entry hold is a system-gesture straggler — during .tracking the edge
    /// band no longer applies, so a normal-size band landing isn't filtered at
    /// all and counts as a plain fourth contact (the filtered variant that counts
    /// via the `moving` evidence is testFilteredStragglerLandingOnConfirmFrameStillCounts).
    /// Either way it must kill the pending swipe before it can post a phantom
    /// ⌘Tab into the OS's own four-finger gesture.
    func testBandStragglerDuringSwipeHoldQuarantines() {
        feed(threeFingers(centerX: 0.30), at: 0.00)                 // arm
        feed(threeFingers(centerX: 0.46), at: 0.02)                 // crosses → entry held
        // straggler lands IN the band mid-hold — phase is .tracking, so it can never park
        feed(threeFingers(centerX: 0.46) + [contact(0.03, 0.5, path: 3)], at: 0.04)
        feed(threeFingers(centerX: 0.46) + [contact(0.03, 0.5, path: 3)], at: 0.10) // past the confirm — must NOT fire
        feed([], at: 0.14)
        XCTAssertEqual(actions, [])
    }

    /// The posture people actually hold: the thumb slides onto the pad's rim and
    /// settles — it never "lands" inside the band, so landing-time parking never
    /// sees it. After a beat of stillness it must retro-park and stop counting, or
    /// a parked thumb that slid home keeps quarantining every gesture.
    func testThumbSlidIntoBandParksAfterSettling() {
        feed([contact(0.30, 0.5, path: 3)], at: 0.00)   // lands midpad — no park
        feed([contact(0.20, 0.5, path: 3)], at: 0.02)   // sliding toward the rim
        feed([contact(0.10, 0.5, path: 3)], at: 0.04)
        feed([contact(0.05, 0.5, path: 3)], at: 0.06)   // arrives inside the 7 mm band
        for i in 0..<10 {                               // settles — ≥ parkSettleFrames
            feed([contact(0.05, 0.5, path: 3)], at: 0.08 + Double(i) * 0.02)
        }
        // three fingers beside the now-parked thumb swipe normally. (A swipe is
        // shown here; a tap would work too — earning the latch re-bases the
        // travel anchor to the parked spot, so the slide-in's 25 mm no longer
        // counts against the tap's travel budget.)
        feed(threeFingers(centerX: 0.35) + [contact(0.05, 0.5, path: 3)], at: 0.30)
        feed(threeFingers(centerX: 0.51) + [contact(0.05, 0.5, path: 3)], at: 0.32)  // crosses → held
        feed(threeFingers(centerX: 0.51) + [contact(0.05, 0.5, path: 3)], at: 0.38)  // confirm → begin + step
        feed(threeFingers(centerX: 0.65) + [contact(0.05, 0.5, path: 3)], at: 0.70)  // step past the HUD delay
        feed([], at: 0.75)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// A parked thumb that lifts for more than one frame and re-lands — even back
    /// inside the band — has lost its latch: a >1-frame gap is a re-plant, not a
    /// flicker, and the contact must re-prove itself. It counts as a fourth finger.
    func testParkedThumbReLandingAfterGapCounts() {
        let thumb = contact(0.05, 0.5, path: 3)
        for i in 0..<10 { feed([thumb], at: Double(i) * 0.02) }   // settles → parked
        feed(threeFingers(centerX: 0.45) + [thumb], at: 0.30)     // arm
        feed(threeFingers(centerX: 0.45), at: 0.32)               // thumb lifts — stream stays live
        feed(threeFingers(centerX: 0.45), at: 0.34)
        feed(threeFingers(centerX: 0.45), at: 0.36)               // absent 3 frames → re-landing
        feed(threeFingers(centerX: 0.45) + [thumb], at: 0.38)     // same spot — latch dropped → counts
        feed([], at: 0.44)
        XCTAssertEqual(actions, [])
    }

    /// A parked thumb re-landing MIDPAD on the same path id is a fresh finger
    /// wearing a stale identity — it counts as a fourth contact immediately.
    func testParkedThumbReLandingMidpadCounts() {
        let thumb = contact(0.05, 0.5, path: 3)
        for i in 0..<10 { feed([thumb], at: Double(i) * 0.02) }   // settles → parked
        feed(threeFingers(centerX: 0.45) + [thumb], at: 0.30)     // arm
        feed(threeFingers(centerX: 0.45), at: 0.32)               // thumb lifts — stream stays live
        feed(threeFingers(centerX: 0.45), at: 0.34)               // absent 2 frames → gap = 3
        // re-lands MIDPAD on the same path id — delta un-parks it regardless of gap
        feed(threeFingers(centerX: 0.45) + [contact(0.52, 0.5, path: 3)], at: 0.36)
        feed(threeFingers(centerX: 0.45) + [contact(0.52, 0.5, path: 3)], at: 0.38)
        feed([], at: 0.44)
        XCTAssertEqual(actions, [])
    }

    /// The flip side of the re-landing rule: a parked thumb that drops out for ONE
    /// frame mid-gesture and comes back at the same spot is a sensor flicker, not
    /// a re-plant. Its latch must survive — otherwise a routine rim-contact
    /// dropout reads as a phantom fourth finger, cancels a live swipe, and
    /// quarantines the follow-up gesture.
    func testParkedThumbOneFrameDropoutKeepsLatch() {
        let thumb = contact(0.05, 0.5, path: 3)
        for i in 0..<10 { feed([thumb], at: Double(i) * 0.02) }   // settles → parked
        feed(threeFingers(centerX: 0.40) + [thumb], at: 0.30)     // arm
        feed(threeFingers(centerX: 0.56) + [thumb], at: 0.32)     // crosses → held
        feed(threeFingers(centerX: 0.56), at: 0.34)               // thumb drops ONE frame
        feed(threeFingers(centerX: 0.56) + [thumb], at: 0.36)     // back at the same spot
        feed(threeFingers(centerX: 0.56) + [thumb], at: 0.40)     // confirm → begin + step
        feed(threeFingers(centerX: 0.72) + [thumb], at: 0.70)     // step past the HUD delay
        feed([], at: 0.75)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// A parked thumb that scoots >4 mm along the rim un-parks (drift) — but once
    /// it settles again its stale travel must stop counting, or the pad stays
    /// quarantined every frame until it re-parks. After re-settling in-band it
    /// re-parks (the anchor re-bases), and gestures beside it work normally.
    func testReParkedThumbAfterRimScootStopsCounting() {
        for i in 0..<10 {                                        // settles → parks in-band
            feed([contact(0.02, 0.5, path: 3)], at: Double(i) * 0.02)
        }
        feed([contact(0.065, 0.5, path: 3)], at: 0.22)  // scoots within the band (>4 mm → un-parks)
        for i in 0..<10 {                              // re-settles → retro-parks again
            feed([contact(0.065, 0.5, path: 3)], at: 0.24 + Double(i) * 0.02)
        }
        feed(threeFingers(centerX: 0.45) + [contact(0.065, 0.5, path: 3)], at: 0.50)
        feed(threeFingers(centerX: 0.45) + [contact(0.065, 0.5, path: 3)], at: 0.54)
        feed([], at: 0.58)
        XCTAssertEqual(actions, [.middleClick])
    }

    /// The decay that makes the scoot test work: an oversized contact that drifts
    /// and then settles must stop counting once it has ACTUALLY stopped — streak
    /// displacement, not raw travel, is the evidence. Otherwise its stale >4 mm
    /// travel quarantines the pad every frame until it lifts.
    func testOversizedSettledAfterDriftStopsCounting() {
        var big = contact(0.80, 0.5, path: 3)
        big.zTotal = 3.0
        feed([big], at: 0.00)
        var bigDrifted = contact(0.86, 0.5, path: 3)   // drifts 6 mm
        bigDrifted.zTotal = 3.0
        feed([bigDrifted], at: 0.02)
        for i in 0..<10 {                              // then sits — streak displacement ≈ 0
            feed([bigDrifted], at: 0.04 + Double(i) * 0.02)
        }
        feed(threeFingers(centerX: 0.40) + [bigDrifted], at: 0.30)
        feed(threeFingers(centerX: 0.56) + [bigDrifted], at: 0.32)   // crosses → held
        feed(threeFingers(centerX: 0.56) + [bigDrifted], at: 0.38)   // confirm → begin + step
        feed([], at: 0.44)
        // (A swipe, not a tap: the drifted contact's 6 mm travel bars the tap —
        // movedTooFar — but path travel doesn't bar swipes.)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    /// A filtered contact creeping at sub-eps speed (≤0.5 mm/frame) must still
    /// count for quarantine — it racks up stillFrames while physically moving, so
    /// only displacement over the streak can expose it. Otherwise a system
    /// gesture's slow finger hides while the pending swipe posts a phantom ⌘Tab.
    func testSlowCreepFilteredContactStillCounts() {
        var big = contact(0.80, 0.5, path: 3)
        big.zTotal = 3.0
        feed(threeFingers(centerX: 0.40) + [big], at: 0.00)      // arm — filtered, still
        for i in 1...8 {                                        // creeps 0.4 mm/frame
            var creep = contact(0.80 + Float(i) * 0.004, 0.5, path: 3)
            creep.zTotal = 3.0
            feed(threeFingers(centerX: 0.40) + [creep], at: Double(i) * 0.02)
        }
        feed(threeFingers(centerX: 0.56), at: 0.30)             // the fingers try to swipe — long dead
        feed(threeFingers(centerX: 0.56), at: 0.36)
        feed([], at: 0.40)
        XCTAssertEqual(actions, [])
    }

    /// A filtered straggler landing exactly on the pending-confirm frame is a
    /// system-gesture candidate: it counts from creation (`moving = !canPark`),
    /// so the qc≥4 check above the confirm disposes of it before anything posts.
    func testFilteredStragglerLandingOnConfirmFrameStillCounts() {
        var big = contact(0.80, 0.5, path: 3)
        big.zTotal = 3.0
        feed(threeFingers(centerX: 0.30), at: 0.00)              // arm
        feed(threeFingers(centerX: 0.46), at: 0.02)              // crosses → entry held
        feed(threeFingers(centerX: 0.46) + [big], at: 0.06)      // lands ON the confirm frame
        feed(threeFingers(centerX: 0.46) + [big], at: 0.10)
        feed([], at: 0.14)
        XCTAssertEqual(actions, [])
    }

    /// `scrollBornPaths >= 1`: a single path already carrying scroll momentum is
    /// enough to bar the gesture. A two-finger scroll that sheds one finger and has
    /// two fresh ones land beside it reads as three contacts — but one of them was
    /// moving long before the gesture armed.
    func testSinglePreTravelledPathBarsGesture() {
        feed([contact(0.40, 0.5, path: 3)], at: 0.00)   // a scroll finger
        feed([contact(0.75, 0.5, path: 3)], at: 0.02)   // 35 mm of travel — still in frame
        // two fresh fingers join it: three contacts, one scroll-born
        feed([contact(0.42, 0.5, path: 0), contact(0.48, 0.5, path: 1), contact(0.75, 0.5, path: 3)], at: 0.04)
        feed([contact(0.62, 0.5, path: 0), contact(0.68, 0.5, path: 1), contact(0.75, 0.5, path: 3)], at: 0.06)
        feed([contact(0.62, 0.5, path: 0), contact(0.68, 0.5, path: 1), contact(0.75, 0.5, path: 3)], at: 0.12)
        feed([], at: 0.16)
        XCTAssertEqual(actions, [])
    }

    /// A two-finger scroll whose contacts carry >30 mm of momentum and then pick up
    /// a third finger must not arm a swipe — the scroll travel would carry straight
    /// over the step threshold and post a phantom ⌘Tab.
    func testTwoFingerScrollThenThirdFingerDoesNotSwipe() {
        feed([contact(0.30, 0.5, path: 0), contact(0.40, 0.5, path: 1)], at: 0.00)
        feed([contact(0.45, 0.5, path: 0), contact(0.55, 0.5, path: 1)], at: 0.02)   // 15 mm
        feed([contact(0.62, 0.5, path: 0), contact(0.72, 0.5, path: 1)], at: 0.04)   // 32 mm — scroll momentum
        // a third finger lands beside the still-moving pair — reads as 3 contacts
        feed([contact(0.62, 0.5, path: 0), contact(0.72, 0.5, path: 1), contact(0.80, 0.5, path: 2)], at: 0.06)
        feed([contact(0.80, 0.5, path: 0), contact(0.88, 0.5, path: 1), contact(0.92, 0.5, path: 2)], at: 0.08)
        feed([contact(0.80, 0.5, path: 0), contact(0.88, 0.5, path: 1), contact(0.92, 0.5, path: 2)], at: 0.14)
        feed([], at: 0.20)
        XCTAssertEqual(actions, [])
    }

    /// The swipe-entry hold re-validates at commit: toggling app-switching off while
    /// a swipe sits in the confirmation window must abandon it silently — nothing
    /// was posted yet, so nothing should be.
    func testPendingSwipeAbandonsWhenAppSwitchDisabledMidHold() {
        feed(threeFingers(centerX: 0.30), at: 0.00)     // arm
        feed(threeFingers(centerX: 0.46), at: 0.02)     // crosses → entry held
        recognizer.setAppSwitchEnabled(false)           // user toggles mid-hold
        feed(threeFingers(centerX: 0.46), at: 0.10)     // past the confirm — abandons
        feed([], at: 0.14)
        XCTAssertEqual(actions, [])
        recognizer.setAppSwitchEnabled(true)
    }

    // MARK: - Suppression latch release (resting fingers must not eat clicks)

    /// Three fingers left resting on the surface past the tap window can no longer
    /// synthesize a native click — the latch must release so real clicks (on a mouse
    /// too: the tap is system-wide) aren't eaten for as long as the fingers rest.
    func testRestingThreeFingersReleaseGestureLatch() {
        var changes: [Bool] = []
        recognizer.onGestureActiveChanged = { changes.append($0) }
        feed(threeFingers(centerX: 0.5), at: 0.00)               // latch on
        feed(threeFingers(centerX: 0.5), at: 0.05)
        feed(threeFingers(centerX: 0.5), at: 0.20)               // tap window passed → off
        feed(threeFingers(centerX: 0.5), at: 1.00)               // still resting — stays off
        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(actions, [])
    }

    /// The released latch doesn't end the gesture: a swipe starting after the dwell
    /// re-latches for the switch's lifetime, then releases at commit.
    func testSwipeAfterDwellReleaseRelatches() {
        var changes: [Bool] = []
        recognizer.onGestureActiveChanged = { changes.append($0) }
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.30), at: 0.20)              // dwell → latch released
        feed(threeFingers(centerX: 0.46), at: 0.30)              // crosses → entry held
        feed(threeFingers(centerX: 0.46), at: 0.40)              // confirm → re-latch + begin
        feed([], at: 0.45)
        XCTAssertEqual(changes, [true, false, true, false])
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeCommit])
    }

    // MARK: - Force-Touch state (a hard press is still a contact)

    /// A finger pressing hard mid-swipe reports state 5 (Force Touch / break-touch).
    /// Counted as a contact, the gesture count stays at three — otherwise three
    /// consecutive state-5 frames read as a finger lift and prematurely commit.
    func testForceTouchStateDoesNotDropSwipeCount() {
        var hard = contact(0.46, 0.5, path: 1)
        hard.state = TouchState.breakTouch
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)              // crosses → held
        feed(threeFingers(centerX: 0.46), at: 0.07)              // confirm → begin + step
        // three consecutive break-touch frames — the old state set dropped them,
        // so the count read as two and the debounce committed early
        feed([contact(0.42, 0.5, path: 0), hard, contact(0.50, 0.5, path: 2)], at: 0.09)
        feed([contact(0.42, 0.5, path: 0), hard, contact(0.50, 0.5, path: 2)], at: 0.11)
        feed([contact(0.42, 0.5, path: 0), hard, contact(0.50, 0.5, path: 2)], at: 0.13)
        // state back to normal and the scrub continues — a step still fires
        feed(threeFingers(centerX: 0.62), at: 0.35)
        feed([], at: 0.40)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    // MARK: - Curved swipes (vertical excursion is absorbed, not fatal)

    /// A scrub that arcs downward keeps stepping: the vertical excursion is
    /// absorbed into the anchor so horizontal progress still counts. With a stale
    /// Y anchor the last frame here reads dx=30 vs dy=30 — dominance fails and the
    /// step never fires.
    func testCurvedSwipeAbsorbsVerticalExcursion() {
        feed(threeFingers(centerX: 0.30), at: 0.00)
        feed(threeFingers(centerX: 0.46), at: 0.02)                    // crosses → held
        feed(threeFingers(centerX: 0.46), at: 0.07)                    // confirm → begin + step
        // the curve: 14 mm right but 18 mm down — dominance fails → absorb Y, keep X
        feed(threeFingers(centerX: 0.60, centerY: 0.68), at: 0.40)
        // still arcing: 16 mm right of the absorbed anchor, 12 mm down → steps
        feed(threeFingers(centerX: 0.76, centerY: 0.80), at: 0.45)
        feed([], at: 0.50)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.forward), .swipeStep(.forward), .swipeCommit])
    }

    /// The streak window must ROLL, not latch: a filtered contact that creeps past
    /// the streak bound and then stops has to stop counting — the window re-bases
    /// so a stopped creeper heals instead of quarantining the pad forever while it
    /// stays down (which is exactly how a resting thumb sits).
    func testStoppedCreepHealsStreakEvidence() {
        var big = contact(0.80, 0.5, path: 3)
        big.zTotal = 3.0
        feed([big], at: 0.00)
        for i in 1...6 {                                        // creeps 0.4 mm/frame = 2.4 mm
            var creep = contact(0.80 + Float(i) * 0.004, 0.5, path: 3)
            creep.zTotal = 3.0
            feed([creep], at: Double(i) * 0.02)                 // streak crosses 1.5 mm → moving
        }
        var stopped = contact(0.824, 0.5, path: 3)              // stops dead
        stopped.zTotal = 3.0
        for i in 0..<10 {                                       // window rolls → healed
            feed([stopped], at: 0.14 + Double(i) * 0.02)
        }
        feed(threeFingers(centerX: 0.40) + [stopped], at: 0.40)
        feed(threeFingers(centerX: 0.40) + [stopped], at: 0.44)
        feed([], at: 0.48)
        // its 2.4 mm total travel is also under the tap's 4 mm bar — clean click
        XCTAssertEqual(actions, [.middleClick])
    }

    /// The other half of "settled is measured in mm": a contact creeping inside the
    /// band must NEVER earn the parked latch, however many sub-eps frames it racks
    /// up — streak displacement, not frame count, is the settlement proof. When it
    /// is still creeping as three fingers land, it is a straggler and the gesture dies.
    func testCreepingBandContactNeverEarnsPark() {
        for i in 0..<12 {                                       // creeps 0.4 mm/frame inside the band
            feed([contact(0.02 + Float(i) * 0.004, 0.5, path: 3)], at: Double(i) * 0.02)
        }
        feed(threeFingers(centerX: 0.45) + [contact(0.064, 0.5, path: 3)], at: 0.30)
        feed(threeFingers(centerX: 0.45) + [contact(0.064, 0.5, path: 3)], at: 0.34)
        feed([], at: 0.38)
        // never parked → during .tracking it's an unfiltered fourth contact → no tap
        XCTAssertEqual(actions, [])
    }

    /// The evidence latch must hold through EVERY window, not just trip frames:
    /// a 0.1 mm/frame creep crosses the 0.75 mm window bound once per window —
    /// a per-frame `moving` reading would hand it multi-frame amnesty windows
    /// between trips. The fingers land mid-window (stillFrames≈5, streak≈0.5):
    /// per-frame semantics reads it still and lets the phantom fire; the latch
    /// keeps it quarantined.
    func testVerySlowCreepStaysQuarantined() {
        for i in 0..<37 {                                       // creeps 0.1 mm/frame
            var creep = contact(0.80 + Float(i) * 0.001, 0.5, path: 3)
            creep.zTotal = 3.0
            feed([creep], at: Double(i) * 0.02)
        }
        // lands mid-window: latch up, streak under the bound on this frame
        var held = contact(0.837, 0.5, path: 3)
        held.zTotal = 3.0
        feed(threeFingers(centerX: 0.40) + [held], at: 0.76)
        feed(threeFingers(centerX: 0.56) + [held], at: 0.78)     // crosses → entry held
        feed(threeFingers(centerX: 0.56) + [held], at: 0.82)     // confirm frame — streak still 0.7
        feed([], at: 0.86)
        XCTAssertEqual(actions, [])
    }

    /// Un-parking must burn the stillness credit too: a thumb that creeps past the
    /// 4 mm bound is a finger again and re-earns only through a fresh clean
    /// window — it can't spend stillness accumulated while drifting. The contact
    /// is oversized so it stays palm-filtered even in .tracking — only the
    /// evidence latch can expose it (a normal-size one would count regardless).
    func testUnparkedThumbMustReProveStillness() {
        var thumb = contact(0.02, 0.5, path: 3)
        thumb.zTotal = 3.0
        for i in 0..<10 { feed([thumb], at: Double(i) * 0.02) }   // settles → parked
        for i in 1...14 {                                        // creeps 0.3 mm/frame ≈ 4.2 mm
            var creep = contact(0.02 + Float(i) * 0.003, 0.5, path: 3)
            creep.zTotal = 3.0
            feed([creep], at: 0.20 + Double(i) * 0.02)           // travel >4 mm → un-parks mid-creep
        }
        var settled = contact(0.062, 0.5, path: 3)
        settled.zTotal = 3.0
        feed([settled], at: 0.50)                                // stops — only 2 still frames
        feed([settled], at: 0.52)
        feed(threeFingers(centerX: 0.45) + [settled], at: 0.54)
        feed(threeFingers(centerX: 0.61) + [settled], at: 0.56)  // crosses → entry held
        feed(threeFingers(centerX: 0.61) + [settled], at: 0.60)  // confirm frame — latch must block it
        feed([], at: 0.64)
        XCTAssertEqual(actions, [])
    }
}
