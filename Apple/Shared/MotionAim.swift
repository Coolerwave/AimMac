import Foundation
import CoreMotion

/// Turns the device's motion into a pointing direction.
///
/// The pointing edge is the top of the device: 12 o'clock on the watch, the
/// top edge on the iPhone (device +Y).
///   el (elevation) comes straight from gravity, so up/down never drifts.
///   az (azimuth) adds up turns around the true vertical from the gyroscope,
///   so it works however the device is rolled in the hand.
final class MotionAim {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "AimMac.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private var az = 0.0
    private var lastT: Double?

    /// (timestamp, azimuth, elevation) in seconds-since-boot and degrees, ~100 Hz, on a background queue.
    var onSample: ((Double, Double, Double) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isRunning: Bool { manager.isDeviceMotionActive }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        lastT = nil
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self = self, let m = motion else { return }
            self.process(m)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func process(_ m: CMDeviceMotion) {
        let g = m.gravity
        let gn = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard gn > 0.1 else { return }
        let gx = g.x / gn, gy = g.y / gn, gz = g.z / gn

        // up/down: how far +Y points above the horizon
        let el = asin(max(-1, min(1, -gy))) * 180 / .pi

        // left/right: spin around "up" (= -gravity); positive = turning left
        let w = m.rotationRate
        let wUp = -(w.x * gx + w.y * gy + w.z * gz)
        if let lt = lastT {
            let dt = min(max(m.timestamp - lt, 0), 0.05)
            az += wUp * dt * 180 / .pi
            if az > 360 || az < -360 { az = az.truncatingRemainder(dividingBy: 360) }
        }
        lastT = m.timestamp
        onSample?(m.timestamp, az, el)
    }
}
