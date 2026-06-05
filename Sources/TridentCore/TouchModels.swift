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

/// Touch lifecycle states reported by the framework. Only `.touching` and
/// `.active` represent a finger physically resting on the trackpad, so those are
/// the only states Trident counts as real contacts.
enum TouchState {
    static let touching: UInt32 = 3
    static let active: UInt32 = 4

    /// Whether a raw `state` value counts as a finger on the surface.
    static func isContact(_ state: UInt32) -> Bool {
        state == touching || state == active
    }
}
