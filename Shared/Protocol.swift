// Shared by the Mac receiver and the iPhone / Apple Watch apps.
//
// Bluetooth LE layout
//   The Mac advertises one service. Clients connect, subscribe to `status`
//   and write packets to `input` (write without response).
//
// Packets (little endian, first byte = kind)
//   hello   01  uuid[16] kind:u8 name:utf8          who I am (kind 0 = watch, 1 = phone)
//   aim     02  t:f64 az:f32 el:f32                  degrees; az grows turning left, el grows tilting up
//   press   03  t:f64                                thumb went down
//   release 04  t:f64                                thumb went up
//   right   05  t:f64                                right click
//   scroll  06  dx:f32 dy:f32                        pixels, natural direction
//   center  07                                       "I'm pointing at the middle of the screen now"
//   pause   08  on:u8
//   info    09  battery:u8 (255 = unknown) model:utf8
//   move    0A  dx:f32 dy:f32                        relative move in pixels (trackpad mode)
//
// Status (Mac -> client, read + notify)
//   state:u8 (0 waiting for approval, 1 approved, 2 denied)  paused:u8  macName:utf8
//
// `t` is the client's own clock (seconds since boot, same as CMDeviceMotion.timestamp).
// The Mac only compares client times with other times from the same client.

import Foundation
import CoreBluetooth

enum TM {
    static let service = CBUUID(string: "7E1A0001-3C2B-4F7D-9B61-2A9E5D0C4F10")
    static let input   = CBUUID(string: "7E1A0002-3C2B-4F7D-9B61-2A9E5D0C4F10")
    static let status  = CBUUID(string: "7E1A0003-3C2B-4F7D-9B61-2A9E5D0C4F10")
}

enum PacketKind: UInt8 {
    case hello = 0x01, aim, press, release, right, scroll, center, pause, info, move
}

enum DeviceKind: UInt8 {
    case watch = 0, phone = 1
}

enum LinkState: UInt8 {
    case waiting = 0, approved = 1, denied = 2
}

struct PacketWriter {
    private(set) var data = Data()

    init(_ kind: PacketKind) { data.append(kind.rawValue) }

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func f32(_ v: Float) {
        var le = v.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func f64(_ v: Double) {
        var le = v.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func uuid(_ u: UUID) {
        let t = u.uuid
        data.append(contentsOf: [t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
                                 t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15])
    }

    /// Rest-of-packet string, cut to keep packets small.
    mutating func string(_ s: String, max: Int = 60) {
        data.append(contentsOf: Array(s.utf8.prefix(max)))
    }
}

struct PacketReader {
    private let bytes: [UInt8]
    private var i = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var kind: PacketKind? {
        guard let b = bytes.first else { return nil }
        return PacketKind(rawValue: b)
    }

    /// Call once before reading fields to skip the kind byte.
    mutating func skipKind() { i = 1 }

    mutating func u8() -> UInt8? {
        guard i < bytes.count else { return nil }
        defer { i += 1 }
        return bytes[i]
    }

    private mutating func raw(_ n: Int) -> UInt64? {
        guard i + n <= bytes.count else { return nil }
        var v: UInt64 = 0
        for k in 0..<n { v |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
        i += n
        return v
    }

    mutating func f32() -> Float? {
        guard let r = raw(4) else { return nil }
        return Float(bitPattern: UInt32(truncatingIfNeeded: r))
    }

    mutating func f64() -> Double? {
        guard let r = raw(8) else { return nil }
        return Double(bitPattern: r)
    }

    mutating func uuid() -> UUID? {
        guard i + 16 <= bytes.count else { return nil }
        let b = Array(bytes[i..<(i + 16)])
        i += 16
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    mutating func rest() -> String {
        guard i < bytes.count else { return "" }
        let s = String(decoding: bytes[i...], as: UTF8.self)
        i = bytes.count
        return s
    }
}
