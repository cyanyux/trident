import CoreFoundation
import Foundation
import os

// MARK: - Global callback plumbing
//
// A `@convention(c)` callback cannot capture Swift context, so the live monitor
// and its enabled flag live in globals guarded by an `os_unfair_lock`. The lock
// is held only long enough to read the flag and the handler reference — never
// across touch processing — so it adds nothing measurable to the hot path.

private nonisolated(unsafe) var gMonitor: DeviceMonitor?
private nonisolated(unsafe) var gEnabled = false
private nonisolated(unsafe) var gLock = os_unfair_lock()

/// The C entry point the framework calls once per frame, on its own thread.
private let contactCallback: MTContactCallbackFunction = { device, touches, numTouches, timestamp, _ in
    os_unfair_lock_lock(&gLock)
    // Check the flag FIRST: during teardown it is cleared under this same lock,
    // so a callback that arrives mid-stop bails out before touching any state.
    guard gEnabled, let monitor = gMonitor, let touches else {
        os_unfair_lock_unlock(&gLock)
        return 0
    }
    let handler = monitor.onTouches
    // Read the producing trackpad's physical size while still holding the lock. This is
    // the only reader of `deviceSizes`, and start() only ever publishes a fresh table
    // under this same lock, so no rebuild can race an in-flight read.
    let size = monitor.surfaceSize(for: device)
    os_unfair_lock_unlock(&gLock)

    if let handler {
        let ptr = touches.assumingMemoryBound(to: MTTouch.self)
        handler(ptr, Int(numTouches), timestamp, size.widthMM, size.heightMM)
    }
    // Never consume — Trident only generates events; it lets the system see the
    // raw gesture so other trackpad behaviors keep working.
    return 0
}

// MARK: - DeviceMonitor

/// Owns the multitouch device lifecycle and hands each frame to `onTouches`.
///
/// Lifetime note: a `DeviceMonitor` is meant to outlive every callback (it is held
/// by the long-lived `TridentEngine`). Stopping clears `gEnabled` under the lock
/// before unregistering, which is what makes teardown safe without an arbitrary
/// sleep.
final class DeviceMonitor: @unchecked Sendable {

    /// Physical surface size of a trackpad, in millimetres.
    struct SurfaceSize: Sendable {
        var widthMM: Float
        var heightMM: Float
    }

    /// Fallback when a device doesn't report its dimensions — roughly a built-in
    /// Apple trackpad, so thresholds stay sane rather than collapsing to zero.
    static let fallbackSize = SurfaceSize(widthMM: 160, heightMM: 115)

    /// Invoked on the framework's callback thread with a pointer that is valid
    /// only for the duration of the call, plus the producing trackpad's physical
    /// size in millimetres. Set once before `start()`.
    var onTouches: ((UnsafePointer<MTTouch>, Int, Double, Float, Float) -> Void)?

    private let log = Logger(subsystem: "com.trident.Trident", category: "DeviceMonitor")
    private let stateLock = NSLock()
    private var isRunning = false
    private var registeredDevices: Set<UnsafeMutableRawPointer> = []
    /// Per-device physical size, keyed by device pointer. Published as a whole under
    /// `gLock` in `start()` and read under the same lock on the callback thread, so a
    /// restart's rebuild can never race an in-flight read. A few entries at most — a
    /// linear scan is free.
    private var deviceSizes: [(device: UnsafeMutableRawPointer, size: SurfaceSize)] = []

    /// Physical size of `device` (or the fallback). Must be called with `gLock` held
    /// (the callback does): `deviceSizes` is only published under that lock in
    /// `start()`, so the scan never races a rebuild. Reads on the callback thread.
    func surfaceSize(for device: UnsafeMutableRawPointer?) -> SurfaceSize {
        guard let device else { return Self.fallbackSize }
        for entry in deviceSizes where entry.device == device { return entry.size }
        return Self.fallbackSize
    }

    /// Query a device's physical surface size via the private framework. The API
    /// reports hundredths of a millimetre; fall back if it returns nothing useful.
    private func physicalSize(of device: UnsafeMutableRawPointer) -> SurfaceSize {
        var w: Int32 = 0
        var h: Int32 = 0
        MTDeviceGetSensorSurfaceDimensions(device, &w, &h)
        guard w > 0, h > 0 else { return Self.fallbackSize }
        return SurfaceSize(widthMM: Float(w) / 100, heightMM: Float(h) / 100)
    }

    init() {
        os_unfair_lock_lock(&gLock)
        if gMonitor == nil { gMonitor = self }
        os_unfair_lock_unlock(&gLock)
    }

    deinit { stop() }

    /// Register and start every multitouch device. Returns `false` if none exist.
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return true }

        registeredDevices.removeAll()
        // Build the size table locally, then publish it in one shot under `gLock`
        // below — so the callback never sees a half-built table.
        var sizes: [(device: UnsafeMutableRawPointer, size: SurfaceSize)] = []

        func register(_ device: UnsafeMutableRawPointer) {
            let size = physicalSize(of: device)
            sizes.append((device, size))
            let summary = String(format: "trackpad surface %.1f × %.1f mm", Double(size.widthMM), Double(size.heightMM))
            log.notice("\(summary, privacy: .public)")
            MTRegisterContactFrameCallback(device, contactCallback)
            MTDeviceStart(device, 0)
            registeredDevices.insert(device)
        }

        // `MTDeviceCreateList` follows the Create rule; Swift ARC releases the returned
        // CFArray when it leaves scope. The device handles inside belong to the
        // framework and are intentionally never CFReleased — releasing a handle the
        // framework has already torn down (across sleep or a disconnect) crashes inside
        // CFRelease — so we only ever hold raw pointers to them.
        if let list = MTDeviceCreateList() {
            for i in 0..<CFArrayGetCount(list) {
                guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
                register(UnsafeMutableRawPointer(mutating: raw))
            }
        }

        // Fall back to the default device if the list was empty.
        if registeredDevices.isEmpty, let device = MTDeviceCreateDefault() {
            register(device)
        }

        guard !registeredDevices.isEmpty else { return false }

        isRunning = true
        // Publish the size table and enable callbacks together, under the callback's own
        // lock: the first frame either sees the complete table or bails on `gEnabled`.
        // (Frames can begin arriving from MTDeviceStart above before this point, but
        // those bail because `gEnabled` is still false.)
        os_unfair_lock_lock(&gLock)
        gMonitor = self
        deviceSizes = sizes
        gEnabled = true
        os_unfair_lock_unlock(&gLock)
        return true
    }

    /// Stop and unregister all devices. Safe to call repeatedly. `deviceSizes` is
    /// intentionally left intact (rebuilt on the next `start()`) so an in-flight
    /// callback can keep reading it without a lock.
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        isRunning = false

        let devices = registeredDevices
        registeredDevices.removeAll()

        // Disable callbacks under the lock BEFORE unregistering. Any in-flight
        // callback either already finished or will observe `gEnabled == false`
        // and return immediately.
        os_unfair_lock_lock(&gLock)
        gEnabled = false
        if gMonitor === self { gMonitor = nil }
        os_unfair_lock_unlock(&gLock)

        for device in devices {
            MTUnregisterContactFrameCallback(device, contactCallback)
            // Guard against a double-release if the framework already tore the
            // handle down (e.g. across a sleep/wake or a disconnect).
            if MTDeviceIsRunning(device) {
                MTDeviceStop(device)
            }
        }
    }
}
