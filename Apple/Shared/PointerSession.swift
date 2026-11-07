import Foundation
import Combine

/// Glue between the motion sensor and the Bluetooth link, shared by both apps.
final class PointerSession: ObservableObject {
    let link = MacLink()
    private let motion = MotionAim()
    private var bag = Set<AnyCancellable>()

    /// When false the device only sends buttons and moves (phone trackpad mode).
    @Published var aimEnabled = true { didSet { update() } }
    @Published private(set) var pressing = false

    init() {
        motion.onSample = { [weak self] t, az, el in
            DispatchQueue.main.async { self?.link.sendAim(t: t, az: az, el: el) }
        }
        link.$state.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &bag)
        // re-publish link changes so views watching the session refresh too
        link.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    var motionAvailable: Bool { motion.isAvailable }

    /// Run the sensors only while they are useful, to save battery.
    func update() {
        if link.state == .ready && aimEnabled && !link.paused {
            motion.start()
        } else {
            motion.stop()
        }
    }

    func setPaused(_ on: Bool) {
        link.paused = on
        update()
    }

    func press() {
        guard !pressing else { return }
        pressing = true
        DeviceInfo.haptic()
        link.press()
    }

    func release() {
        guard pressing else { return }
        pressing = false
        link.release()
    }

    func rightClick() {
        DeviceInfo.haptic()
        link.rightClick()
    }

    func center() {
        DeviceInfo.haptic()
        link.center()
    }
}
