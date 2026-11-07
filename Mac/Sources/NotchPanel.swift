import AppKit

/// Everything the panel shows. Filled in by AppDelegate.
struct NotchModel {
    enum Status { case noBluetooth, searching, waiting, live, paused }
    var status: Status = .searching
    var deviceName = ""
    var deviceKind: DeviceKind?
    var model = ""
    var battery: Int?
    var aim: CGPoint?
    var displays: [CGRect] = []
    var macPaused = false
}

/// A black panel that hugs the notch (or the middle of the menu bar on Macs
/// without one). It grows when the pointer hovers over it.
final class NotchPanel {
    var onCenter: (() -> Void)?
    var onPause: (() -> Void)?
    var onGame: (() -> Void)?
    var model: () -> NotchModel = { NotchModel() }

    private var panel: NSPanel!
    private var view: NotchView!
    private var timer: Timer?
    private var expanded = false
    private var pinned = false
    private var collapseWork: DispatchWorkItem?

    func show() {
        let v = NotchView(frame: .zero)
        v.owner = self
        view = v
        let p = NSPanel(contentRect: collapsedFrame(), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = v
        p.orderFrontRegardless()
        panel = p

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.relayout(animated: false)
        }
    }

    private var tick = 0
    private func refresh() {
        tick += 1
        // full speed while open, a couple of frames per second while closed
        if expanded || tick % 10 == 0 {
            view.model = model()
            view.needsDisplay = true
        }
    }

    // MARK: geometry

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    /// Height of the menu bar strip (the notch is the same height).
    var barHeight: CGFloat {
        let inset = screen.safeAreaInsets.top
        return inset > 0 ? inset : NSStatusBar.system.thickness
    }

    /// Width of the camera notch, 0 if there is none.
    var notchWidth: CGFloat {
        guard screen.safeAreaInsets.top > 0,
              let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, r.minX - l.maxX)
    }

    private func collapsedFrame() -> NSRect {
        let f = screen.frame
        let w = max(notchWidth, 150) + 96
        return NSRect(x: f.midX - w / 2, y: f.maxY - barHeight, width: w, height: barHeight)
    }

    private func expandedFrame() -> NSRect {
        let f = screen.frame
        let w: CGFloat = max(440, notchWidth + 200)
        let h: CGFloat = barHeight + 150
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private func relayout(animated: Bool) {
        let target = expanded ? expandedFrame() : collapsedFrame()
        view.expanded = expanded
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        view.model = model()
        view.needsDisplay = true
    }

    // MARK: hover / buttons

    func hoverChanged(inside: Bool) {
        collapseWork?.cancel()
        if inside {
            if !expanded { expanded = true; relayout(animated: true) }
        } else if !pinned {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.expanded, !self.pinned else { return }
                self.expanded = false
                self.relayout(animated: true)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    func button(_ name: String) {
        switch name {
        case "center": onCenter?()
        case "pause": onPause?()
        case "game": onGame?()
        case "pin":
            pinned.toggle()
            view.pinned = pinned
            view.needsDisplay = true
        default: break
        }
    }
}

final class NotchView: NSView {
    weak var owner: NotchPanel?
    var model = NotchModel()
    var expanded = false
    var pinned = false
    private var hoverButton: String?
    private var buttons: [(String, NSRect)] = []

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { owner?.hoverChanged(inside: true) }
    override func mouseExited(with event: NSEvent) {
        hoverButton = nil
        owner?.hoverChanged(inside: false)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = buttons.first { $0.1.contains(p) }?.0
        if hit != hoverButton { hoverButton = hit; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = buttons.first(where: { $0.1.contains(p) })?.0 { owner?.button(hit) }
    }

    // MARK: drawing

    private let accent = NSColor(calibratedRed: 0.36, green: 0.95, blue: 0.72, alpha: 1)
    private let amber = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.28, alpha: 1)
    private let dim = NSColor(white: 1, alpha: 0.5)

    private var statusColor: NSColor {
        switch model.status {
        case .live: return accent
        case .paused, .waiting: return amber
        case .searching: return NSColor(white: 1, alpha: 0.35)
        case .noBluetooth: return .systemRed
        }
    }

    private var statusText: String {
        switch model.status {
        case .live: return "LIVE"
        case .paused: return "PAUSED"
        case .waiting: return "CONFIRM"
        case .searching: return "WAITING"
        case .noBluetooth: return "BT OFF"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius: CGFloat = expanded ? 22 : 12
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: r.minX, y: r.minY))
        shape.line(to: NSPoint(x: r.maxX, y: r.minY))
        shape.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        shape.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        shape.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
        shape.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        shape.close()
        NSColor.black.setFill()
        shape.fill()

        let barH = owner?.barHeight ?? 32
        drawCollapsedStrip(barH: barH)
        buttons = []
        if expanded { drawExpanded(top: barH) }
    }

    /// Status dot on the left of the notch, battery on the right.
    private func drawCollapsedStrip(barH: CGFloat) {
        let notchW = owner?.notchWidth ?? 0
        let gap = max(notchW, 150)
        let leftX = (bounds.width - gap) / 2 - 36
        let rightX = (bounds.width + gap) / 2 + 8

        let d: CGFloat = 8
        let dot = NSBezierPath(ovalIn: NSRect(x: leftX + 14, y: barH / 2 - d / 2, width: d, height: d))
        statusColor.setFill()
        dot.fill()
        if model.status == .live {
            statusColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: leftX + 10, y: barH / 2 - 8, width: 16, height: 16)).fill()
        }

        let txt: String
        if let b = model.battery { txt = "\(b)%" } else { txt = model.deviceKind == nil ? "" : "—" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: dim,
        ]
        let s = NSAttributedString(string: txt, attributes: attrs)
        s.draw(at: NSPoint(x: rightX, y: barH / 2 - s.size().height / 2))
    }

    private func drawExpanded(top: CGFloat) {
        let pad: CGFloat = 20
        let y0 = top + 14

        // device line
        let symbol = model.deviceKind == .phone ? "iphone" : (model.deviceKind == .watch ? "applewatch" : "dot.radiowaves.left.and.right")
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) {
            let tinted = img.copy() as! NSImage
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: pad, y: y0 + 2, width: tinted.size.width, height: tinted.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let title = model.deviceKind == nil ? "No device connected" : model.deviceName
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: pad + 32, y: y0))

        var sub: [String] = []
        if !model.model.isEmpty { sub.append(model.model) }
        if let b = model.battery { sub.append("\(b)% battery") }
        if model.deviceKind == nil { sub.append("Open AimMac on your iPhone or Apple Watch") }
        NSAttributedString(string: sub.joined(separator: "  ·  "), attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim,
        ]).draw(at: NSPoint(x: pad + 32, y: y0 + 19))

        // status pill
        let pillText = NSAttributedString(string: statusText, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: statusColor,
        ])
        let pw = pillText.size().width + 20
        let pill = NSRect(x: bounds.width - pad - pw, y: y0 + 4, width: pw, height: 20)
        statusColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        pillText.draw(at: NSPoint(x: pill.minX + 10, y: pill.midY - pillText.size().height / 2))

        // live aim map
        let map = NSRect(x: pad, y: y0 + 46, width: 170, height: 78)
        drawMap(in: map)

        // buttons 2 x 2
        let bw: CGFloat = 104, bh: CGFloat = 34, gap: CGFloat = 8
        let bx = bounds.width - pad - bw * 2 - gap
        let by = y0 + 46
        let items: [(String, String, String)] = [
            ("center", "scope", "Center"),
            ("pause", model.macPaused ? "play.fill" : "pause.fill", model.macPaused ? "Resume" : "Pause"),
            ("pin", pinned ? "pin.fill" : "pin", pinned ? "Pinned" : "Pin"),
            ("game", "gamecontroller", "Game"),
        ]
        for (i, it) in items.enumerated() {
            let rect = NSRect(x: bx + CGFloat(i % 2) * (bw + gap), y: by + CGFloat(i / 2) * (bh + gap), width: bw, height: bh)
            buttons.append((it.0, rect))
            let on = (it.0 == "pin" && pinned) || (it.0 == "pause" && model.macPaused)
            let hover = hoverButton == it.0
            NSColor(white: 1, alpha: hover ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            let color = on ? accent : NSColor.white
            let label = NSAttributedString(string: it.2, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color,
            ])
            var x = rect.midX - (label.size().width + 20) / 2
            if let img = NSImage(systemSymbolName: it.1, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
                let t = img.copy() as! NSImage
                t.lockFocus(); color.set(); NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop); t.unlockFocus()
                t.draw(in: NSRect(x: x, y: rect.midY - t.size.height / 2, width: t.size.width, height: t.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += 20
            }
            label.draw(at: NSPoint(x: x, y: rect.midY - label.size().height / 2))
        }
    }

    /// Displays drawn to scale with the live aim point on top.
    private func drawMap(in box: NSRect) {
        NSColor(white: 1, alpha: 0.05).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        let ds = model.displays
        guard !ds.isEmpty else { return }
        let u = ds.dropFirst().reduce(ds[0]) { $0.union($1) }
        let inner = box.insetBy(dx: 10, dy: 10)
        let s = min(inner.width / u.width, inner.height / u.height)
        let ox = inner.midX - u.width * s / 2
        let oy = inner.midY - u.height * s / 2
        func map(_ p: CGPoint) -> NSPoint { NSPoint(x: ox + (p.x - u.minX) * s, y: oy + (p.y - u.minY) * s) }

        for d in ds {
            let o = map(d.origin)
            let rr = NSRect(x: o.x, y: o.y, width: d.width * s, height: d.height * s).insetBy(dx: 1, dy: 1)
            NSColor(white: 1, alpha: 0.10).setFill()
            NSBezierPath(roundedRect: rr, xRadius: 3, yRadius: 3).fill()
            NSColor(white: 1, alpha: 0.22).setStroke()
            let b = NSBezierPath(roundedRect: rr, xRadius: 3, yRadius: 3)
            b.lineWidth = 1
            b.stroke()
        }
        guard let a = model.aim, model.status == .live || model.status == .paused else { return }
        let p = map(a)
        statusColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill()
        statusColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
    }
}
