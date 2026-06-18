import CoreGraphics
import XCTest
@testable import TridentCore

/// Drives `ActionSynthesizer` with abstract `GestureAction`s and asserts the exact stream of
/// keyboard/mouse events it posts — via an injected `MockEventSink`, with no Accessibility
/// permission or real CGEvent posting. The watchdog timer is disabled (`watchdogEnabled: false`);
/// tests that exercise recovery call `fireWatchdogForTesting()` to run one tick deterministically.
final class ActionSynthesizerTests: XCTestCase {

    // ANSI virtual key codes (mirror the private `Key` enum, which the test module can't see).
    private let kCommand: CGKeyCode = 0x37
    private let kTab: CGKeyCode = 0x30
    private let kEscape: CGKeyCode = 0x35

    private var sink: MockEventSink!
    private var synth: ActionSynthesizer!

    override func setUp() {
        super.setUp()
        sink = MockEventSink()
        synth = ActionSynthesizer(sink: sink, watchdogEnabled: false)
    }

    override func tearDown() {
        // Release any held ⌘ and stop work before the next test (synchronous).
        synth.releaseAllAndWait()
        synth = nil
        sink = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Send an action and block until it has been processed.
    private func send(_ action: GestureAction) {
        synth.handle(action)
        synth.drainForTesting()
    }

    private func keys() -> [MockEventSink.Key] { sink.keys }
    private func keyCount(_ code: CGKeyCode, down: Bool) -> Int {
        sink.keys.filter { $0.code == code && $0.down == down }.count
    }
    private func firstIndex(of code: CGKeyCode) -> Int? {
        sink.keys.firstIndex { $0.code == code }
    }

    // MARK: - Happy path

    func testSwitchSequencePressStepCommit() {
        send(.swipeBegin)
        send(.swipeStep(.forward))
        send(.swipeCommit)

        // ⌘ pressed once (down, maskCommand).
        XCTAssertEqual(keyCount(kCommand, down: true), 1)
        let cmdDown = keys().first { $0.code == kCommand && $0.down }
        XCTAssertEqual(cmdDown?.flags, .maskCommand)

        // One ⌘Tab chord: Tab down+up carrying maskCommand.
        XCTAssertEqual(keyCount(kTab, down: true), 1)
        XCTAssertEqual(keyCount(kTab, down: false), 1)
        let tabDown = keys().first { $0.code == kTab && $0.down }
        XCTAssertEqual(tabDown?.flags, .maskCommand)

        // ⌘ released; no Escape (a commit must not dismiss).
        XCTAssertGreaterThanOrEqual(keyCount(kCommand, down: false), 1)
        XCTAssertEqual(keyCount(kEscape, down: true), 0)
        XCTAssertFalse(synth.commandHeldForTesting)
    }

    func testBackwardStepCarriesShift() {
        send(.swipeBegin)
        send(.swipeStep(.backward))
        let tabDown = keys().first { $0.code == kTab && $0.down }
        XCTAssertEqual(tabDown?.flags, [.maskCommand, .maskShift])
    }

    /// The ⌘-up is over-posted N times as delivery insurance (repost `untilSuccess: false`).
    func testCommitOverPostsCommandUp() {
        send(.swipeBegin)
        send(.swipeCommit)
        // repostCount is 3; the up posts all N even though each succeeds.
        XCTAssertEqual(keyCount(kCommand, down: false), 3)
    }

    func testMiddleClickPostsDownThenUp() {
        send(.middleClick)
        XCTAssertEqual(sink.mouse, [.otherMouseDown, .otherMouseUp])
    }

    // MARK: - Cancel ordering

    func testCancelDismissesBeforeRelease() {
        send(.swipeBegin)
        sink.reset()                 // ignore the press; focus on the cancel sequence
        send(.cancel)

        // Escape (with ⌘) is posted, and BEFORE the ⌘-up.
        XCTAssertEqual(keyCount(kEscape, down: true), 1)   // stop-at-first: exactly one Escape chord
        let escapeIdx = firstIndex(of: kEscape)
        let cmdUpIdx = keys().firstIndex { $0.code == kCommand && !$0.down }
        XCTAssertNotNil(escapeIdx)
        XCTAssertNotNil(cmdUpIdx)
        XCTAssertLessThan(escapeIdx!, cmdUpIdx!, "Escape must be posted before the ⌘-up")
        let escDown = keys().first { $0.code == kEscape && $0.down }
        XCTAssertEqual(escDown?.flags, .maskCommand)
        XCTAssertFalse(synth.commandHeldForTesting)
    }

    /// P0 regression: a `.cancel` arriving with no ⌘ held (e.g. the watchdog already released)
    /// must NOT fire a spurious ⌘-Escape at the front app.
    func testStrayCancelWithoutHeldPostsNothing() {
        send(.cancel)
        XCTAssertEqual(sink.keys.count, 0)
        XCTAssertFalse(synth.commandHeldForTesting)
    }

    // MARK: - Teardown resolves by phase (F1)

    /// A `.swipeCommit` whose ⌘-up failed to create leaves ⌘ held in `.committing`; teardown must
    /// COMPLETE it as a commit (⌘-up only), never invert it into an Escape-cancel.
    func testTeardownAfterFailedCommitCompletesAsCommit() {
        send(.swipeBegin)
        sink.failKeys([kCommand])    // ⌘-up creation fails → commit can't complete
        send(.swipeCommit)
        XCTAssertTrue(synth.commandHeldForTesting, "commit release failed, so ⌘ stays held")

        sink.failKeys([])            // creation recovers
        sink.reset()
        synth.releaseAllAndWait()    // teardown

        XCTAssertGreaterThanOrEqual(keyCount(kCommand, down: false), 1, "teardown completes the ⌘-up")
        XCTAssertEqual(keyCount(kEscape, down: true), 0, "a committing teardown must NOT Escape")
        XCTAssertFalse(synth.commandHeldForTesting)
    }

    /// An in-progress gesture (no terminal action) torn down must DISMISS first (Escape) so it
    /// can't commit a stale highlight.
    func testTeardownWhileInProgressDismisses() {
        send(.swipeBegin)
        sink.reset()
        synth.releaseAllAndWait()
        XCTAssertEqual(keyCount(kEscape, down: true), 1, "in-progress teardown dismisses the HUD")
        let escapeIdx = firstIndex(of: kEscape)
        let cmdUpIdx = keys().firstIndex { $0.code == kCommand && !$0.down }
        XCTAssertNotNil(escapeIdx); XCTAssertNotNil(cmdUpIdx)
        XCTAssertLessThan(escapeIdx!, cmdUpIdx!)
    }

    /// Teardown with no ⌘ held must post nothing — never clobber a ⌘ the user physically holds.
    func testTeardownWithoutHeldPostsNothing() {
        synth.releaseAllAndWait()
        XCTAssertEqual(sink.keys.count, 0)
    }

    // MARK: - Watchdog phase recovery

    /// A failed commit is retried by the watchdog as a COMMIT (⌘-up only), frame-independent.
    func testWatchdogRetriesFailedCommitAsCommit() {
        send(.swipeBegin)
        sink.failKeys([kCommand])
        send(.swipeCommit)
        XCTAssertTrue(synth.commandHeldForTesting)

        sink.failKeys([])
        sink.reset()
        synth.fireWatchdogForTesting()   // .committing tick

        XCTAssertGreaterThanOrEqual(keyCount(kCommand, down: false), 1)
        XCTAssertEqual(keyCount(kEscape, down: true), 0, "commit retry must not Escape")
        XCTAssertFalse(synth.commandHeldForTesting)
    }

    /// In-progress with a DEAD frame stream → watchdog cancels (dismiss + release). The watchdog is
    /// disabled here so `lastFrameTime` is never seeded, which reads as a long-stale stream.
    func testWatchdogCancelsInProgressOnStall() {
        send(.swipeBegin)
        sink.reset()
        synth.fireWatchdogForTesting()
        XCTAssertEqual(keyCount(kEscape, down: true), 1, "stalled in-progress gesture is cancelled")
        XCTAssertFalse(synth.commandHeldForTesting)
    }

    /// In-progress with a LIVE frame stream (fresh `noteFrame`) → watchdog does nothing.
    func testWatchdogLeavesLiveInProgressAlone() {
        send(.swipeBegin)
        sink.reset()
        synth.noteFrame()                // fresh frame: stream is alive
        synth.fireWatchdogForTesting()
        XCTAssertEqual(sink.keys.count, 0, "a live gesture must not be cancelled")
        XCTAssertTrue(synth.commandHeldForTesting)
    }

    // MARK: - Dismiss holds ⌘ until the Escape lands

    /// When the dismiss Escape's creation fails, the ⌘-up's would fail too — so don't release onto
    /// a possibly-live HUD. Hold ⌘; once Escape can post, the watchdog completes the cancel.
    func testDismissHoldsCommandWhenEscapeFails() {
        send(.swipeBegin)
        sink.failKeys([kEscape])
        sink.reset()
        send(.cancel)
        XCTAssertEqual(keyCount(kCommand, down: false), 0, "no ⌘-up while the HUD may still be up")
        XCTAssertTrue(synth.commandHeldForTesting, "⌘ stays held until the HUD is dismissed")

        sink.failKeys([])                // Escape creation recovers
        sink.reset()
        synth.fireWatchdogForTesting()   // .cancelling tick
        XCTAssertEqual(keyCount(kEscape, down: true), 1)
        XCTAssertGreaterThanOrEqual(keyCount(kCommand, down: false), 1)
        XCTAssertFalse(synth.commandHeldForTesting)
    }

    // MARK: - postChord guards the down

    /// If the Tab down's creation fails, no orphan Tab-up is posted.
    func testFailedChordDownPostsNoOrphanUp() {
        send(.swipeBegin)
        sink.failKeys([kTab])
        sink.reset()
        send(.swipeStep(.forward))
        XCTAssertEqual(keyCount(kTab, down: false), 0, "a failed Tab down must not leak a Tab up")
        XCTAssertEqual(keyCount(kTab, down: true), 0)
    }

    // MARK: - prepare() recovery

    /// A stuck `.committing` ⌘ left by a failed teardown is completed as a commit by `prepare()` on
    /// the next start (⌘-up only, no Escape), and the flag is cleared for a clean run.
    func testPrepareRecoversStuckCommit() {
        send(.swipeBegin)
        sink.failKeys([kCommand])
        send(.swipeCommit)
        synth.releaseAllAndWait()        // teardown can't post the ⌘-up either; ⌘ stays held
        XCTAssertTrue(synth.commandHeldForTesting)

        sink.failKeys([])
        sink.reset()
        synth.prepare()
        synth.drainForTesting()

        XCTAssertGreaterThanOrEqual(keyCount(kCommand, down: false), 1)
        XCTAssertEqual(keyCount(kEscape, down: true), 0, "completing a commit must not Escape")
        XCTAssertFalse(synth.commandHeldForTesting)
    }
}

// MARK: - Test double

/// Records posted events and can simulate CGEvent *creation* failure (the only way posting fails in
/// production). Calls arrive on the synthesizer's serial queue; a lock keeps reads race-free.
final class MockEventSink: EventSink, @unchecked Sendable {

    struct Key: Equatable {
        let code: CGKeyCode
        let flags: CGEventFlags
        let down: Bool
    }

    private let lock = NSLock()
    private var _keys: [Key] = []
    private var _mouse: [CGEventType] = []
    private var _failKeyCodes: Set<CGKeyCode> = []
    private var _cursor: CGPoint? = .zero

    var keys: [Key] { lock.withLock { _keys } }
    var mouse: [CGEventType] { lock.withLock { _mouse } }

    /// Make creation fail for these key codes (empty = all succeed).
    func failKeys(_ codes: Set<CGKeyCode>) { lock.withLock { _failKeyCodes = codes } }
    func setCursor(_ p: CGPoint?) { lock.withLock { _cursor = p } }
    func reset() { lock.withLock { _keys = []; _mouse = [] } }

    func postKey(_ key: CGKeyCode, flags: CGEventFlags, down: Bool) -> Bool {
        lock.withLock {
            if _failKeyCodes.contains(key) { return false }   // simulate creation failure: nothing posted
            _keys.append(Key(code: key, flags: flags, down: down))
            return true
        }
    }

    func postMouse(_ type: CGEventType, at location: CGPoint) {
        lock.withLock { _mouse.append(type) }
    }

    func cursorLocation() -> CGPoint? { lock.withLock { _cursor } }
}
