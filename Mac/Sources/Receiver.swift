import AppKit
import CoreBluetooth

enum InputEvent {
    case aim(t: Double, az: Double, el: Double)
    case press(t: Double)
    case release(t: Double)
    case right(t: Double)
    case scroll(dx: Double, dy: Double)
    case move(dx: Double, dy: Double)
    case center
    case pause(Bool)
}

struct Peer {
    let central: CBCentral
    var deviceID: UUID?
    var kind: DeviceKind = .watch
    var name = "Unknown device"
    var model = ""
    var battery: Int?
    var state: LinkState = .waiting
    var paused = false
    var lastSeen = CFAbsoluteTimeGetCurrent()

    var key: String { central.identifier.uuidString }
}

protocol ReceiverDelegate: AnyObject {
    /// Ask the user whether a new device may control the cursor.
    func receiver(_ r: Receiver, shouldTrust peer: Peer, decide: @escaping (Bool) -> Void)
    func receiver(_ r: Receiver, peer: Peer, event: InputEvent)
    func receiverDidChange(_ r: Receiver)
}

/// The Mac side of the Bluetooth link: advertises a service that the
/// iPhone and Apple Watch apps connect to. Nothing goes over Wi-Fi or a server.
final class Receiver: NSObject, CBPeripheralManagerDelegate {
    weak var delegate: ReceiverDelegate?

    private var pm: CBPeripheralManager!
    private var inputChar: CBMutableCharacteristic?
    private var statusChar: CBMutableCharacteristic?
    private var serviceAdded = false
    private var asking = Set<String>()

    private(set) var peers: [String: Peer] = [:]
    private(set) var bluetoothOn = false
    var paused = false { didSet { broadcastStatus() } }

    private let defaults = UserDefaults.standard
    private var trusted: Set<String> {
        get { Set(defaults.stringArray(forKey: "trustedDevices") ?? []) }
        set { defaults.set(Array(newValue), forKey: "trustedDevices") }
    }

    let macName: String = {
        let n = Host.current().localizedName ?? "Mac"
        return String(n.prefix(24))
    }()

    func start() {
        pm = CBPeripheralManager(delegate: self, queue: .main)
    }

    /// The approved device that sent something most recently.
    var activePeer: Peer? {
        peers.values
            .filter { $0.state == .approved && CFAbsoluteTimeGetCurrent() - $0.lastSeen < 6 }
            .max { $0.lastSeen < $1.lastSeen }
    }

    var trustedCount: Int { trusted.count }

    func forgetAll() {
        trusted = []
        for k in peers.keys { peers[k]?.state = .denied }
        broadcastStatus()
        delegate?.receiverDidChange(self)
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        bluetoothOn = (p.state == .poweredOn)
        if bluetoothOn && !serviceAdded {
            let input = CBMutableCharacteristic(type: TM.input, properties: [.writeWithoutResponse],
                                                value: nil, permissions: [.writeable])
            let status = CBMutableCharacteristic(type: TM.status, properties: [.read, .notify],
                                                 value: nil, permissions: [.readable])
            let service = CBMutableService(type: TM.service, primary: true)
            service.characteristics = [input, status]
            inputChar = input
            statusChar = status
            serviceAdded = true
            pm.add(service)
        }
        if !bluetoothOn { peers.removeAll() }
        delegate?.receiverDidChange(self)
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            NSLog("AimMac: could not add service: \(error)")
            return
        }
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [TM.service],
            CBAdvertisementDataLocalNameKey: String(macName.prefix(12)),
        ])
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        let key = central.identifier.uuidString
        if peers[key] == nil { peers[key] = Peer(central: central) }
        sendStatus(to: key)
        delegate?.receiverDidChange(self)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        peers.removeValue(forKey: central.identifier.uuidString)
        delegate?.receiverDidChange(self)
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) {
        broadcastStatus()
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == TM.status else {
            pm.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let data = statusData(for: request.central.identifier.uuidString)
        guard request.offset <= data.count else {
            pm.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        pm.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == TM.input {
            guard let v = r.value else { continue }
            handle(central: r.central, data: v)
        }
    }

    // MARK: packets

    private func handle(central: CBCentral, data: Data) {
        let key = central.identifier.uuidString
        if peers[key] == nil { peers[key] = Peer(central: central) }
        peers[key]?.lastSeen = CFAbsoluteTimeGetCurrent()

        var r = PacketReader(data)
        guard let kind = r.kind else { return }
        r.skipKind()

        switch kind {
        case .hello:
            guard let id = r.uuid() else { return }
            let k = DeviceKind(rawValue: r.u8() ?? 0) ?? .watch
            let name = r.rest()
            peers[key]?.deviceID = id
            peers[key]?.kind = k
            if !name.isEmpty { peers[key]?.name = name }
            if trusted.contains(id.uuidString) {
                peers[key]?.state = .approved
                sendStatus(to: key)
            } else {
                askTrust(key)
            }
            delegate?.receiverDidChange(self)
            return
        case .info:
            let b = r.u8() ?? 255
            peers[key]?.battery = b == 255 ? nil : Int(b)
            let model = r.rest()
            if !model.isEmpty { peers[key]?.model = model }
            delegate?.receiverDidChange(self)
            return
        default:
            break
        }

        // Everything below needs an approved device.
        guard let peer = peers[key], peer.state == .approved else { return }

        let event: InputEvent?
        switch kind {
        case .aim:
            if let t = r.f64(), let az = r.f32(), let el = r.f32() {
                event = .aim(t: t, az: Double(az), el: Double(el))
            } else { event = nil }
        case .press:
            event = r.f64().map { InputEvent.press(t: $0) }
        case .release:
            event = r.f64().map { InputEvent.release(t: $0) }
        case .right:
            event = r.f64().map { InputEvent.right(t: $0) }
        case .scroll:
            if let dx = r.f32(), let dy = r.f32() { event = .scroll(dx: Double(dx), dy: Double(dy)) } else { event = nil }
        case .move:
            if let dx = r.f32(), let dy = r.f32() { event = .move(dx: Double(dx), dy: Double(dy)) } else { event = nil }
        case .center:
            event = .center
        case .pause:
            let on = (r.u8() ?? 0) != 0
            peers[key]?.paused = on
            event = .pause(on)
            delegate?.receiverDidChange(self)
        case .hello, .info:
            event = nil
        }
        if let e = event, let p = peers[key] { delegate?.receiver(self, peer: p, event: e) }
    }

    private func askTrust(_ key: String) {
        guard let peer = peers[key], !asking.contains(key) else { return }
        asking.insert(key)
        peers[key]?.state = .waiting
        sendStatus(to: key)
        delegate?.receiver(self, shouldTrust: peer) { [weak self] ok in
            guard let self = self else { return }
            self.asking.remove(key)
            if ok, let id = self.peers[key]?.deviceID {
                var t = self.trusted
                t.insert(id.uuidString)
                self.trusted = t
            }
            self.peers[key]?.state = ok ? .approved : .denied
            self.sendStatus(to: key)
            self.delegate?.receiverDidChange(self)
        }
    }

    // MARK: status

    private func statusData(for key: String) -> Data {
        var d = Data([peers[key]?.state.rawValue ?? LinkState.waiting.rawValue, paused ? 1 : 0])
        d.append(contentsOf: Array(macName.utf8))
        return d
    }

    private func sendStatus(to key: String) {
        guard let c = statusChar, let peer = peers[key] else { return }
        _ = pm.updateValue(statusData(for: key), for: c, onSubscribedCentrals: [peer.central])
    }

    private func broadcastStatus() {
        for k in peers.keys { sendStatus(to: k) }
    }
}
