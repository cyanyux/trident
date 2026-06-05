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

    func testSwipeLeftEmitsBackward() {
        feed(threeFingers(centerX: 0.60), at: 0.00)
        feed(threeFingers(centerX: 0.44), at: 0.02)  // crosses threshold leftward
        feed([], at: 0.06)
        XCTAssertEqual(actions, [.swipeBegin, .swipeStep(.backward), .swipeCommit])
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
