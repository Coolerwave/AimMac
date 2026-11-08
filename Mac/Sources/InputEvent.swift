import Foundation

enum InputEvent: Equatable {
    case aim(t: Double, az: Double, el: Double)
    case press(t: Double)
    case release(t: Double)
    case right(t: Double)
    case scroll(dx: Double, dy: Double)
    case move(dx: Double, dy: Double)
    case center
    case pause(Bool)

    /// Decode fixed-size control packets before allowing them to affect the cursor.
    static func decode(_ data: Data) -> InputEvent? {
        var r = PacketReader(data)
        guard let kind = r.kind else { return nil }
        r.skipKind()
        let event: InputEvent
        switch kind {
        case .aim:
            guard let t = r.f64(), t.isFinite,
                  let az = r.f32(), az.isFinite,
                  let el = r.f32(), el.isFinite else { return nil }
            event = .aim(t: t, az: Double(az), el: Double(el))
        case .press, .release, .right:
            guard let t = r.f64(), t.isFinite else { return nil }
            switch kind {
            case .press: event = .press(t: t)
            case .release: event = .release(t: t)
            default: event = .right(t: t)
            }
        case .scroll, .move:
            guard let x = r.f32(), x.isFinite,
                  let y = r.f32(), y.isFinite else { return nil }
            if kind == .scroll {
                guard Int32(exactly: Double(x).rounded()) != nil,
                      Int32(exactly: Double(y).rounded()) != nil else { return nil }
                event = .scroll(dx: Double(x), dy: Double(y))
            } else {
                event = .move(dx: Double(x), dy: Double(y))
            }
        case .center:
            event = .center
        case .pause:
            guard let on = r.u8(), on <= 1 else { return nil }
            event = .pause(on == 1)
        case .hello, .info:
            return nil
        }
        guard r.remaining == 0 else { return nil }
        return event
    }
}
