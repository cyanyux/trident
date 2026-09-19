import CoreFoundation

// MARK: - MultitouchSupport Private API Bindings
//
// Trident reads the trackpad through Apple's private `MultitouchSupport`
// framework. The symbols below are resolved at link time — the app target links
// `-framework MultitouchSupport` from `/System/Library/PrivateFrameworks`. There
// is no dlopen and no module map; `@_silgen_name` gives Swift the declarations
// and the linker supplies the implementations.

/// Opaque reference to a multitouch device.
typealias MTDeviceRef = UnsafeMutableRawPointer

/// C callback invoked once per touch frame on a framework-owned thread.
/// Matches the framework's `MTFrameCallbackFunction` (size_t counts, void return):
/// `void (*)(MTDeviceRef, MTTouch *, size_t numTouches, double timestamp, size_t frame)`.
/// - Parameters:
///   - device: device that produced the frame
///   - touches: pointer to a contiguous array of `MTTouch` (valid only for the
///     duration of the call)
///   - numTouches: number of touches in the array
///   - timestamp: frame timestamp in seconds
///   - frame: monotonically increasing frame number
/// The return is void — Trident never consumes frames (it generates events, it
/// never suppresses gestures); the framework ignores any suppression intent anyway.
typealias MTContactCallbackFunction = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int,
    Double,
    Int
) -> Void

/// Reference to the default multitouch device (the built-in trackpad).
@_silgen_name("MTDeviceCreateDefault")
func MTDeviceCreateDefault() -> MTDeviceRef?

/// List of every attached multitouch device.
@_silgen_name("MTDeviceCreateList")
func MTDeviceCreateList() -> CFArray?

/// Start delivering frames for `device`. Pass `0` for normal operation.
/// Returns an OSStatus — 0 (`noErr`) on success.
@_silgen_name("MTDeviceStart")
func MTDeviceStart(_ device: MTDeviceRef, _ mode: Int32) -> OSStatus

/// Stop delivering frames for `device`. Returns an OSStatus — 0 on success.
@_silgen_name("MTDeviceStop")
func MTDeviceStop(_ device: MTDeviceRef) -> OSStatus

/// Whether `device` is currently delivering frames.
@_silgen_name("MTDeviceIsRunning")
func MTDeviceIsRunning(_ device: MTDeviceRef) -> Bool

/// Fill `width`/`height` with the trackpad's physical surface size, in hundredths
/// of a millimetre (e.g. `16000` = 160.00 mm). Lets Trident express gesture
/// thresholds in real distance so the feel is identical across differently-sized
/// trackpads instead of scaling with each one's width. Returns an OSStatus.
@_silgen_name("MTDeviceGetSensorSurfaceDimensions")
func MTDeviceGetSensorSurfaceDimensions(
    _ device: MTDeviceRef,
    _ width: UnsafeMutablePointer<Int32>,
    _ height: UnsafeMutablePointer<Int32>
) -> OSStatus

/// Stable hardware identity for `device` (the registry-entry ID), written to
/// `deviceID`. Unlike the `MTDeviceRef` wrapper pointer — which enumeration may
/// hand out afresh for the same hardware — this survives disconnect/reconnect,
/// so it is the right key for "did the attached set actually change". Returns an
/// OSStatus; non-zero means no ID was written.
@_silgen_name("MTDeviceGetDeviceID")
func MTDeviceGetDeviceID(_ device: MTDeviceRef, _ deviceID: UnsafeMutablePointer<UInt64>) -> OSStatus

/// Register `callback` to receive contact frames for `device`.
@_silgen_name("MTRegisterContactFrameCallback")
func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactCallbackFunction)

/// Unregister a previously registered contact-frame callback.
@_silgen_name("MTUnregisterContactFrameCallback")
func MTUnregisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactCallbackFunction?)
