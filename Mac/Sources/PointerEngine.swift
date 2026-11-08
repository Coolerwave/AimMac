import AppKit
import CoreGraphics

/// Owns the system cursor. Sources feed target points; a dedicated thread
/// eases the cursor toward the target 240 times a second, so 100 Hz input
/// still looks smooth on a 120 Hz display.
final class PointerEngine {
    struct Snapshot {
        var point: CGPoint?
        var displays: [CGRect]
        var dragging: Bool
    }

    private let lock = NSLock()
    private var target: CGPoint?
    private var current: CGPoint?
    private var source: String?
    private var history: [(t: Double, p: CGPoint)] = []
    private var frozen = false
    private var pressed = false
    private var dragging = false
    private var pressPoint: CGPoint?
    private var pressID = 0
    private var enabled = true

    private var displayCache: [CGRect] = []
    private var displayCacheTime = 0.0

    private var lastClickTime = 0.0
    private var lastClickPoint = CGPoint.zero
    private var clickCount = 0

    /// Half-angle (degrees) you need to turn to reach the left/right edge of the main display.
    var rangeDeg = 28.0

    // MARK: lifecycle

    func start() {
        let th = Thread { [weak self] in
            while true {
                guard let self = self else { return }
                self.tick()
                usleep(4_166)
            }
        }
        th.name = "AimMac.cursor"
        th.qualityOfService = .userInteractive
        th.start()
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        target = nil
        current = nil
        history.removeAll()
        lock.unlock()
        if !on { cancelPress() }
    }

    private func tick() {
        lock.lock()
        guard enabled, !frozen, let t = target else { lock.unlock(); return }
        var c = current ?? t
        let dx = t.x - c.x, dy = t.y - c.y
        if abs(dx) < 0.05 && abs(dy) < 0.05 && current != nil { lock.unlock(); return }
        c.x += dx * 0.42
        c.y += dy * 0.42
        current = c
        let drag = dragging
        lock.unlock()
        post(c, dragging: drag)
    }

    // MARK: geometry

    func displays() -> [CGRect] {
        let now = CFAbsoluteTimeGetCurrent()
        if now - displayCacheTime > 2 || displayCache.isEmpty {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var n: UInt32 = 0
            if CGGetActiveDisplayList(16, &ids, &n) == .success, n > 0 {
                displayCache = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
            } else {
                displayCache = [CGDisplayBounds(CGMainDisplayID())]
            }
            displayCacheTime = now
        }
        return displayCache
    }

    /// Laser-pointer projection: the main display is a wall at distance `d`,
    /// chosen so that turning `rangeDeg` reaches its edge. Points that land on
    /// other displays stay there, which is how you reach a second monitor.
    /// xDeg > 0 = right, yDeg > 0 = down.
    func project(xDeg: Double, yDeg: Double) -> CGPoint {
        let main = CGDisplayBounds(CGMainDisplayID())
        let r = max(5, min(80, rangeDeg)) * .pi / 180
        let d = Double(main.width) / 2 / tan(r)
        let ax = max(-80, min(80, xDeg)) * .pi / 180
        let ay = max(-80, min(80, yDeg)) * .pi / 180
        let p = CGPoint(x: main.midX + CGFloat(d * tan(ax)), y: main.midY + CGFloat(d * tan(ay)))
        return clamp(p)
    }

    func clamp(_ p: CGPoint) -> CGPoint {
        let rects = displays()
        if rects.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDist = CGFloat.greatestFiniteMagnitude
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let dist = hypot(q.x - p.x, q.y - p.y)
            if dist < bestDist { bestDist = dist; best = q }
        }
        return best
    }

    // MARK: input

    /// A new aim sample. `t` is on the source's own clock.
    func feed(source id: String, t: Double, point: CGPoint) {
        lock.lock()
        if source != id {
            source = id
            history.removeAll()
        }
        target = point
        history.append((t, point))
        if history.count > 400 || (history.first.map { t - $0.t > 1.0 } ?? false) {
            history.removeAll { t - $0.t > 1.0 }
        }
        lock.unlock()
    }

    /// Where the pointer was aimed at client time `t` (called with the lock held).
    private func pointAt(_ t: Double?) -> CGPoint? {
        if let t = t, let hit = history.last(where: { $0.t <= t }) { return hit.p }
        return current ?? target ?? currentCursor()
    }

    private func currentCursor() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Thumb down. The cursor freezes on the point you were aiming at when the
    /// touch started, so the jolt of the tap doesn't move the click.
    func press(t: Double?) {
        lock.lock()
        pressed = true
        frozen = true
        pressPoint = pointAt(t)
        pressID += 1
        let id = pressID
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { [weak self] in
            self?.beginDragIfHeld(id)
        }
    }

    private func beginDragIfHeld(_ id: Int) {
        lock.lock()
        guard pressed, pressID == id, let p = pressPoint else { lock.unlock(); return }
        dragging = true
        frozen = false
        current = p
        lock.unlock()
        mouse(.leftMouseDown, at: p, button: .left, clicks: 1)
    }

    func release(t: Double?) {
        lock.lock()
        guard pressed else { lock.unlock(); return }
        pressed = false
        pressID += 1
        let wasDragging = dragging
        dragging = false
        let p = (wasDragging ? current : pressPoint) ?? pressPoint ?? currentCursor() ?? .zero
        lock.unlock()

        if wasDragging {
            mouse(.leftMouseUp, at: p, button: .left, clicks: 1)
            return
        }
        let n = nextClickCount(at: p)
        mouse(.leftMouseDown, at: p, button: .left, clicks: n)
        mouse(.leftMouseUp, at: p, button: .left, clicks: n)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if !self.pressed {
                self.frozen = false
                self.current = p
            }
            self.lock.unlock()
        }
    }

    private func cancelPress() {
        lock.lock()
        let wasDragging = dragging
        let p = current ?? pressPoint
        pressed = false
        dragging = false
        frozen = false
        pressID += 1
        lock.unlock()
        if wasDragging, let p = p { mouse(.leftMouseUp, at: p, button: .left, clicks: 1) }
    }

    func rightClick(t: Double?) {
        lock.lock()
        let p = pointAt(t) ?? .zero
        lock.unlock()
        mouse(.rightMouseDown, at: p, button: .right, clicks: 1)
        mouse(.rightMouseUp, at: p, button: .right, clicks: 1)
    }

    func scroll(dx: Double, dy: Double) {
        // Reject non-finite and out-of-range values before converting network input.
        guard let x = Int32(exactly: dx.rounded()), let y = Int32(exactly: dy.rounded()) else { return }
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: y, wheel2: x, wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    /// Relative move, used by the phone's trackpad mode.
    func nudge(dx: Double, dy: Double) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let base = current ?? currentCursor() ?? .zero
        lock.unlock()
        let p = clamp(CGPoint(x: base.x + CGFloat(dx), y: base.y + CGFloat(dy)))
        lock.lock()
        source = "pad"
        history.removeAll()
        target = p
        current = p
        let drag = dragging
        let skip = frozen
        lock.unlock()
        if !skip { post(p, dragging: drag) }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(point: current ?? target, displays: displayCache, dragging: dragging)
        lock.unlock()
        return s
    }

    // MARK: events

    private func nextClickCount(at p: CGPoint) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastClickTime < NSEvent.doubleClickInterval && hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 8 {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPoint = p
        return clickCount
    }

    private func post(_ p: CGPoint, dragging: Bool) {
        if dragging {
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        } else {
            CGWarpMouseCursorPosition(p)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, clicks: Int) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        ev.post(tap: .cghidEventTap)
    }
}
