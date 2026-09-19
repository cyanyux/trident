// MARK: - Touch Data Structures
//
// These structs mirror the binary layout `MultitouchSupport` writes into the
// callback buffer. Field order and types must match exactly — we reinterpret the
// framework's memory as `MTTouch`, so a mismatch corrupts every read.

/// A 2D point in the trackpad's normalized (0–1) or absolute coordinate space.
struct MTPoint {
    var x: Float
    var y: Float
}

/// Position paired with its instantaneous velocity.
struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// One contact within a touch frame, laid out to match the framework's struct.
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32            // see `TouchState`
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector   // position/velocity in 0–1 coordinates
    var zTotal: Float            // contact size / pressure (used for palm rejection)
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector     // position/velocity in device coordinates
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

/// Touch lifecycle states reported by the framework (`MTTouchState`). Three
/// states mean a finger is physically on the surface: make-touch (3, contact
/// begins), touching (4, active contact), and break-touch (5, beginning to lift —
/// and also what a hard-landing/Force-Touch contact reports while still down).
/// States 1–2 are approach/hover, 6–7 lift-off/out-of-range — not contact. The
/// 3–5 range matches what other MultitouchSupport consumers verified on-device
/// on macOS 26.3+: a contact counted through break-touch keeps a finger that
/// presses hard mid-gesture from phantom-lifting (which would drop the count to
/// two and prematurely commit a swipe).
enum TouchState {
    // Names match the canonical `MTTouchState` enum in the framework's headers:
    // MTTouchStateMakeTouch (3), MTTouchStateTouching (4), MTTouchStateBreakTouch (5).
    static let makeTouch: UInt32 = 3
    static let touching: UInt32 = 4
    static let breakTouch: UInt32 = 5

    /// Whether a raw `state` value counts as a finger on the surface.
    static func isContact(_ state: UInt32) -> Bool {
        (makeTouch...breakTouch).contains(state)
    }
}
