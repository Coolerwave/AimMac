import Foundation
import CoreBluetooth
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// The iPhone / Watch side of the Bluetooth link. Finds Macs running
/// AimMac, remembers the one you pair with and streams input to it.
final class MacLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum State: Equatable {
        case bluetoothOff, searching, connecting, waitingApproval, ready, denied
    }

    struct FoundMac: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var found: [FoundMac] = []
    @Published private(set) var macName = ""
    @Published private(set) var macPaused = false
    @Published var paused = false {
        didSet {
            guard paused != oldValue else { return }
            var w = PacketWriter(.pause)
            w.u8(paused ? 1 : 0)
            sendEvent(w.data)
        }
    }

    var hasPairedMac: Bool { pairedID != nil }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var events: [Data] = []
    private var latestAim: Data?
    private var infoTimer: Timer?

    private let defaults = UserDefaults.standard
    private var pairedID: UUID? {
        get { defaults.string(forKey: "pairedMac").flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: "pairedMac") }
    }
    private var pairedName: String {
        get { defaults.string(forKey: "pairedMacName") ?? "" }
        set { defaults.set(newValue, forKey: "pairedMacName") }
    }

    /// Stable id for this device, so the Mac remembers it after you allow it once.
    private let deviceID: UUID = {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "deviceID"), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        d.set(u.uuidString, forKey: "deviceID")
        return u
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        DeviceInfo.enableBattery()
    }

    // MARK: public

    func pair(_ mac: FoundMac) {
        pairedID = mac.id
        pairedName = mac.name
        central.stopScan()
        found = []
        connectPaired()
    }

    func unpair() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        input = nil
        pairedID = nil
        pairedName = ""
        macName = ""
        state = .searching
        scan()
    }

    func sendAim(t: Double, az: Double, el: Double) {
        guard state == .ready, !paused else { return }
        var w = PacketWriter(.aim)
        w.f64(t)
        w.f32(Float(az))
        w.f32(Float(el))
        latestAim = w.data
        flush()
    }

    func press() { timed(.press) }
    func release() { timed(.release) }
    func rightClick() { timed(.right) }

    func center() { sendEvent(PacketWriter(.center).data) }

    func scroll(dx: Double, dy: Double) {
        guard abs(dx) >= 0.5 || abs(dy) >= 0.5 else { return }
        var w = PacketWriter(.scroll)
        w.f32(Float(dx))
        w.f32(Float(dy))
        sendEvent(w.data)
    }

    func move(dx: Double, dy: Double) {
        var w = PacketWriter(.move)
        w.f32(Float(dx))
        w.f32(Float(dy))
        sendEvent(w.data)
    }

    // MARK: sending

    private func timed(_ kind: PacketKind) {
        var w = PacketWriter(kind)
        w.f64(ProcessInfo.processInfo.systemUptime)  // same clock as motion timestamps
        sendEvent(w.data)
    }

    private func sendEvent(_ d: Data) {
        guard state == .ready || d.first == PacketKind.hello.rawValue || d.first == PacketKind.info.rawValue else { return }
        events.append(d)
        if events.count > 64 { events.removeFirst(events.count - 64) }
        flush()
    }

    /// Clicks and scrolls go first and are never dropped; for aim only the
    /// newest sample matters, so an old one is simply replaced.
    private func flush() {
        guard let p = peripheral, let c = input, p.state == .connected else { return }
        while !events.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(events.removeFirst(), for: c, type: .withoutResponse)
        }
        if events.isEmpty, let a = latestAim, p.canSendWriteWithoutResponse {
            p.writeValue(a, for: c, type: .withoutResponse)
            latestAim = nil
        }
    }

    private func sendHello() {
        var w = PacketWriter(.hello)
        w.uuid(deviceID)
        w.u8(DeviceInfo.kind.rawValue)
        w.string(DeviceInfo.name)
        events.insert(w.data, at: 0)
        sendInfo()
    }

    private func sendInfo() {
        var w = PacketWriter(.info)
        w.u8(DeviceInfo.batteryPercent.map { UInt8(clamping: $0) } ?? 255)
        w.string(DeviceInfo.model)
        sendEvent(w.data)
    }

    // MARK: connection

    private func scan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [TM.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connectPaired() {
        guard central.state == .poweredOn, let id = pairedID else { return }
        state = .connecting
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(known)
        }
        scan()  // also look for it by name, in case its address changed
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        // A pending connect never times out: it completes whenever the Mac is back in range.
        central.connect(p, options: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            state = .bluetoothOff
            return
        }
        if pairedID != nil { connectPaired() } else { state = .searching; scan() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "Mac"
        if let id = pairedID {
            // Macs rotate their Bluetooth address, so the identifier can change;
            // the advertised name is the fallback.
            let same = p.identifier == id || (!pairedName.isEmpty && name == pairedName)
            let busy = peripheral?.state == .connected || peripheral?.identifier == p.identifier
            if same && !busy {
                if let old = peripheral { c.cancelPeripheralConnection(old) }
                pairedID = p.identifier
                attach(p)
            }
            return
        }
        if let i = found.firstIndex(where: { $0.id == p.identifier }) {
            found[i].rssi = rssi.intValue
        } else {
            found.append(FoundMac(id: p.identifier, name: name, rssi: rssi.intValue))
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan()
        p.discoverServices([TM.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if p.identifier == pairedID { c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }  // an old, replaced connection
        input = nil
        infoTimer?.invalidate()
        guard p.identifier == pairedID else { return }
        state = .connecting
        c.connect(p, options: nil)
        scan()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == TM.service }) else { return }
        p.discoverCharacteristics([TM.input, TM.status], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == TM.input { input = ch }
            if ch.uuid == TM.status {
                p.setNotifyValue(true, for: ch)
                p.readValue(for: ch)
            }
        }
        state = .waitingApproval
        events.removeAll()
        sendHello()
        flush()
        infoTimer?.invalidate()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendInfo()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == TM.status, let v = ch.value, v.count >= 2 else { return }
        let bytes = [UInt8](v)
        macPaused = bytes[1] != 0
        if v.count > 2 { macName = String(decoding: bytes[2...], as: UTF8.self) }
        switch LinkState(rawValue: bytes[0]) ?? .waiting {
        case .waiting: state = .waitingApproval
        case .approved: state = .ready
        case .denied: state = .denied
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        flush()
    }
}

/// Small platform differences in one place.
enum DeviceInfo {
    #if os(watchOS)
    static let kind = DeviceKind.watch
    static var name: String { WKInterfaceDevice.current().name }
    static func enableBattery() { WKInterfaceDevice.current().isBatteryMonitoringEnabled = true }
    static var batteryPercent: Int? {
        let l = WKInterfaceDevice.current().batteryLevel
        return l < 0 ? nil : Int((l * 100).rounded())
    }
    static func haptic() { WKInterfaceDevice.current().play(.click) }
    #else
    static let kind = DeviceKind.phone
    static var name: String { UIDevice.current.name }
    static func enableBattery() { UIDevice.current.isBatteryMonitoringEnabled = true }
    static var batteryPercent: Int? {
        let l = UIDevice.current.batteryLevel
        return l < 0 ? nil : Int((l * 100).rounded())
    }
    static func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    #endif

    /// Hardware identifier such as "Watch7,1" or "iPhone16,2".
    static var model: String {
        var u = utsname()
        uname(&u)
        let id = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return id
    }
}
