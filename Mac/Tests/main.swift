import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}

func packet(_ kind: PacketKind, _ fields: (inout PacketWriter) -> Void = { _ in }) -> Data {
    var w = PacketWriter(kind)
    fields(&w)
    return w.data
}

let valid: [(Data, InputEvent)] = [
    (packet(.aim) { $0.f64(123); $0.f32(-45); $0.f32(20) }, .aim(t: 123, az: -45, el: 20)),
    (packet(.press) { $0.f64(123) }, .press(t: 123)),
    (packet(.release) { $0.f64(124) }, .release(t: 124)),
    (packet(.right) { $0.f64(125) }, .right(t: 125)),
    (packet(.scroll) { $0.f32(-10.5); $0.f32(20.5) }, .scroll(dx: -10.5, dy: 20.5)),
    (packet(.move) { $0.f32(3); $0.f32(-4) }, .move(dx: 3, dy: -4)),
    (packet(.center), .center),
    (packet(.pause) { $0.u8(0) }, .pause(false)),
    (packet(.pause) { $0.u8(1) }, .pause(true)),
]
for (data, expected) in valid {
    check(InputEvent.decode(data) == expected, "Valid packet changed: \(expected)")
    for length in 0..<data.count {
        check(InputEvent.decode(Data(data.prefix(length))) == nil, "Accepted truncated packet")
    }
    check(InputEvent.decode(data + Data([0])) == nil, "Accepted trailing bytes")
}

for value: Double in [.nan, .infinity, -.infinity] {
    for kind: PacketKind in [.aim, .press, .release, .right] {
        let data = packet(kind) { w in
            w.f64(value)
            if kind == .aim { w.f32(0); w.f32(0) }
        }
        check(InputEvent.decode(data) == nil, "Accepted non-finite timestamp")
    }
}
for value: Float in [.nan, .infinity, -.infinity] {
    for axis in 0...1 {
        let x: Float = axis == 0 ? value : 0
        let y: Float = axis == 1 ? value : 0
        check(InputEvent.decode(packet(.aim) { $0.f64(1); $0.f32(x); $0.f32(y) }) == nil,
              "Accepted non-finite aim")
        for kind: PacketKind in [.scroll, .move] {
            check(InputEvent.decode(packet(kind) { $0.f32(x); $0.f32(y) }) == nil,
                  "Accepted non-finite delta")
        }
    }
}
for value: Float in [Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, Float(Int32.max)] {
    for axis in 0...1 {
        check(InputEvent.decode(packet(.scroll) { $0.f32(axis == 0 ? value : 0); $0.f32(axis == 1 ? value : 0) }) == nil,
              "Accepted overflowing scroll")
    }
}
// Float(Int32.max) rounds up to 2^31; the preceding Float is representable.
check(InputEvent.decode(packet(.scroll) { $0.f32(Float(Int32.max).nextDown); $0.f32(Float(Int32.min)) }) != nil,
      "Rejected representable scroll boundary")
check(InputEvent.decode(packet(.scroll) { $0.f32(0); $0.f32(Float(Int32.min).nextDown) }) == nil,
      "Accepted negative scroll overflow")
for flag in UInt8(2)...UInt8.max {
    check(InputEvent.decode(packet(.pause) { $0.u8(flag) }) == nil, "Accepted invalid pause flag")
}
for kind in [PacketKind.hello, .info] {
    check(InputEvent.decode(packet(kind)) == nil, "Metadata became cursor input")
}
check(InputEvent.decode(Data([0xff])) == nil, "Accepted unknown kind")
// Exercise the final conversion guard too; these calls must return before
// creating or posting any system input event.
let engine = PointerEngine()
for value in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude,
              Double(Int32.max) + 1, Double(Int32.min) - 1] {
    engine.scroll(dx: value, dy: 0)
    engine.scroll(dx: 0, dy: value)
    checks += 2
}
print("Passed \(checks) input validation checks")
