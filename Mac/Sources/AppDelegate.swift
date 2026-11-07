import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ReceiverDelegate {
    let engine = PointerEngine()
    let receiver = Receiver()
    let notch = NotchPanel()
    let defaults = UserDefaults.standard

    var statusItem: NSStatusItem!
    let menu = NSMenu()

    /// Calibration and filters are kept per connected device.
    final class Calib {
        var az0: Double?
        var el0: Double?
        var lastAz = 0.0
        var lastEl = 0.0
        let fx = OneEuro(minCutoff: 1.2, beta: 0.02)
        let fy = OneEuro(minCutoff: 1.2, beta: 0.02)
    }
    var calib: [String: Calib] = [:]

    // settings
    let ranges: [Double] = [18, 28, 40]
    let rangeNames = ["Fast (small turns)", "Normal", "Precise (big turns)"]
    let smooth: [(Double, Double)] = [(2.5, 0.03), (1.2, 0.02), (0.6, 0.01)]
    let smoothNames = ["Low", "Medium", "High"]

    var rangeIdx: Int { get { defaults.integer(forKey: "rangeIdx") } set { defaults.set(newValue, forKey: "rangeIdx") } }
    var smoothIdx: Int { get { defaults.integer(forKey: "smoothIdx") } set { defaults.set(newValue, forKey: "smoothIdx") } }
    var invX: Bool { get { defaults.bool(forKey: "invX") } set { defaults.set(newValue, forKey: "invX") } }
    var invY: Bool { get { defaults.bool(forKey: "invY") } set { defaults.set(newValue, forKey: "invY") } }
    var paused = false

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["rangeIdx": 1, "smoothIdx": 1, "invX": false, "invY": false])
        if !(0..<ranges.count).contains(rangeIdx) { rangeIdx = 1 }
        if !(0..<smooth.count).contains(smoothIdx) { smoothIdx = 1 }
        engine.rangeDeg = ranges[rangeIdx]

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        engine.start()
        receiver.delegate = self
        receiver.start()

        notch.model = { [weak self] in self?.notchModel() ?? NotchModel() }
        notch.onCenter = { [weak self] in self?.centerAll() }
        notch.onPause = { [weak self] in self?.togglePause() }
        notch.onGame = { [weak self] in self?.openGame() }
        notch.show()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ sel: Selector?, on: Bool = false, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.isEnabled = enabled
            menu.addItem(i)
        }

        if let p = receiver.activePeer {
            let battery = p.battery.map { String(format: " · %d%%", $0) } ?? ""
            item(p.name + battery, nil, enabled: false)
        } else {
            item(receiver.bluetoothOn ? "No device connected" : "Bluetooth is off", nil, enabled: false)
        }
        if !AXIsProcessTrusted() {
            item("Accessibility: not granted (click to open)", #selector(openAX))
        }
        menu.addItem(.separator())
        item(paused ? "Resume" : "Pause", #selector(togglePause))
        item("Center (aim at the middle, then click)", #selector(centerAll))
        menu.addItem(.separator())

        let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for (i, name) in rangeNames.enumerated() {
            let it = NSMenuItem(title: name, action: #selector(setRange(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = i == rangeIdx ? .on : .off
            speedMenu.addItem(it)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)

        let sm = NSMenuItem(title: "Smoothing", action: nil, keyEquivalent: "")
        let smMenu = NSMenu()
        for (i, name) in smoothNames.enumerated() {
            let it = NSMenuItem(title: name, action: #selector(setSmooth(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = i == smoothIdx ? .on : .off
            smMenu.addItem(it)
        }
        sm.submenu = smMenu
        menu.addItem(sm)

        item("Invert left/right", #selector(toggleInvX), on: invX)
        item("Invert up/down", #selector(toggleInvY), on: invY)
        menu.addItem(.separator())
        item("Play the target game", #selector(openGame))
        item("Forget paired devices (\(receiver.trustedCount))", #selector(forget), enabled: receiver.trustedCount > 0)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AimMac", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func setIcon() {
        let name: String
        if paused { name = "pause.circle" }
        else if let p = receiver.activePeer { name = p.kind == .phone ? "iphone.radiowaves.left.and.right" : "applewatch.radiowaves.left.and.right" }
        else { name = "cursorarrow.rays" }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "AimMac")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    @objc func openAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func togglePause() {
        paused.toggle()
        receiver.paused = paused
        engine.setEnabled(!paused)
        setIcon()
    }

    /// Whatever you're pointing at right now becomes the middle of the main display.
    @objc func centerAll() {
        for k in calib.keys {
            calib[k]?.az0 = calib[k]?.lastAz
            calib[k]?.el0 = calib[k]?.lastEl
            calib[k]?.fx.reset()
            calib[k]?.fy.reset()
        }
    }

    @objc func setRange(_ s: NSMenuItem) { rangeIdx = s.tag; engine.rangeDeg = ranges[s.tag] }
    @objc func setSmooth(_ s: NSMenuItem) {
        smoothIdx = s.tag
        for c in calib.values {
            c.fx.minCutoff = smooth[s.tag].0; c.fx.beta = smooth[s.tag].1
            c.fy.minCutoff = smooth[s.tag].0; c.fy.beta = smooth[s.tag].1
        }
    }
    @objc func toggleInvX() { invX.toggle() }
    @objc func toggleInvY() { invY.toggle() }
    @objc func forget() { receiver.forgetAll() }
    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func openGame() {
        guard let url = Bundle.main.url(forResource: "game", withExtension: "html") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: ReceiverDelegate

    func receiver(_ r: Receiver, shouldTrust peer: Peer, decide: @escaping (Bool) -> Void) {
        // Shown outside the Bluetooth callback so the link keeps running meanwhile.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            let what = peer.kind == .phone ? "iPhone" : "Apple Watch"
            alert.messageText = "Allow “\(peer.name)” to control the pointer?"
            alert.informativeText = "This \(what) asked to pair with AimMac. Only allow devices you own. You can remove it later from the menu bar."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don’t Allow")
            decide(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func receiver(_ r: Receiver, peer: Peer, event: InputEvent) {
        let key = peer.key
        if calib[key] == nil {
            let c = Calib()
            c.fx.minCutoff = smooth[smoothIdx].0; c.fx.beta = smooth[smoothIdx].1
            c.fy.minCutoff = smooth[smoothIdx].0; c.fy.beta = smooth[smoothIdx].1
            calib[key] = c
        }
        guard !paused else { return }

        switch event {
        case let .aim(t, az, el):
            guard !peer.paused else { return }
            calib[key]?.lastAz = az
            calib[key]?.lastEl = el
            if calib[key]?.az0 == nil {
                calib[key]?.az0 = az
                calib[key]?.el0 = el
            }
            guard let c = calib[key], let az0 = c.az0, let el0 = c.el0 else { return }
            // az grows when turning left, el grows when tilting up; screen x grows right, y grows down
            var dx = -wrap(az - az0)
            var dy = -(el - el0)
            if invX { dx = -dx }
            if invY { dy = -dy }
            let fx = c.fx.filter(dx, t: t)
            let fy = c.fy.filter(dy, t: t)
            engine.feed(source: key, t: t, point: engine.project(xDeg: fx, yDeg: fy))
        case let .press(t): engine.press(t: t)
        case let .release(t): engine.release(t: t)
        case let .right(t): engine.rightClick(t: t)
        case let .scroll(dx, dy): engine.scroll(dx: dx, dy: dy)
        case let .move(dx, dy): engine.nudge(dx: dx, dy: dy)
        case .center:
            calib[key]?.az0 = calib[key]?.lastAz
            calib[key]?.el0 = calib[key]?.lastEl
            calib[key]?.fx.reset()
            calib[key]?.fy.reset()
        case .pause:
            setIcon()
        }
    }

    func receiverDidChange(_ r: Receiver) {
        let live = Set(r.peers.keys)
        calib = calib.filter { live.contains($0.key) }
        setIcon()
    }

    private func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    // MARK: notch

    func notchModel() -> NotchModel {
        var m = NotchModel()
        let snap = engine.snapshot()
        m.aim = snap.point
        m.displays = snap.displays.isEmpty ? engine.displays() : snap.displays
        m.macPaused = paused
        if !receiver.bluetoothOn {
            m.status = .noBluetooth
            return m
        }
        let peer = receiver.activePeer ?? receiver.peers.values.first
        guard let p = peer else {
            m.status = .searching
            return m
        }
        m.deviceName = p.name
        m.deviceKind = p.kind
        m.model = p.model
        m.battery = p.battery
        switch p.state {
        case .waiting: m.status = .waiting
        case .denied: m.status = .searching
        case .approved: m.status = (paused || p.paused) ? .paused : .live
        }
        return m
    }
}
