import SwiftUI
import UIKit

private let mint = Color(red: 0.36, green: 0.95, blue: 0.72)
private let panel = Color.white.opacity(0.07)

struct PhoneRoot: View {
    @EnvironmentObject var session: PointerSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .onChange(of: session.link.state) { _, s in
            // keep the screen on while it's in use as a remote
            UIApplication.shared.isIdleTimerDisabled = (s == .ready)
        }
    }

    @ViewBuilder private var content: some View {
        switch session.link.state {
        case .bluetoothOff:
            Notice(icon: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth is off",
                   text: "Turn on Bluetooth and allow AimMac to use it in Settings.")
        case .searching where !session.link.hasPairedMac:
            PhoneMacPicker()
        case .searching, .connecting:
            Notice(icon: "laptopcomputer", title: "Connecting…",
                   text: "Make sure AimMac is running on your Mac.", unpair: true)
        case .waitingApproval:
            Notice(icon: "checkmark.shield", title: "Allow on your Mac",
                   text: "Click Allow in the window that appeared on \(session.link.macName.isEmpty ? "your Mac" : session.link.macName).")
        case .denied:
            Notice(icon: "xmark.shield", title: "Not allowed",
                   text: "The Mac declined this iPhone.", unpair: true)
        case .ready:
            Remote()
        }
    }
}

struct PhoneMacPicker: View {
    @EnvironmentObject var session: PointerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AimMac").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Your iPhone becomes a pointer for your Mac. Pick the Mac to pair with.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                if session.link.found.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for Macs running AimMac…").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding()
                    .background(panel, in: RoundedRectangle(cornerRadius: 16))
                }
                ForEach(session.link.found) { mac in
                    Button { session.link.pair(mac) } label: {
                        HStack {
                            Image(systemName: "laptopcomputer").font(.title3)
                            Text(mac.name).font(.headline)
                            Spacer()
                            Text("Pair").bold().foregroundStyle(.black)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(mint, in: Capsule())
                        }
                        .padding()
                        .background(panel, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

struct Notice: View {
    @EnvironmentObject var session: PointerSession
    let icon: String
    let title: String
    let text: String
    var unpair = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(mint)
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if unpair {
                Button("Choose another Mac") { session.link.unpair() }.padding(.top, 8)
            }
        }
        .padding(32)
    }
}

/// Two modes:
///  Pointer  – aim the top edge at the screen, the big pad clicks / drags.
///  Trackpad – phone lies on the table, slide a finger to move.
struct Remote: View {
    @EnvironmentObject var session: PointerSession
    @State private var trackpad = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 12) {
            header
            Picker("", selection: $trackpad) {
                Text("Pointer").tag(false)
                Text("Trackpad").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: trackpad) { _, on in session.aimEnabled = !on }

            HStack(spacing: 12) {
                if trackpad { TrackSurface() } else { ClickPad() }
                ScrollStrip().frame(width: 64)
            }

            HStack(spacing: 12) {
                bigButton("cursorarrow.click.2", "Right click") { session.rightClick() }
                if !trackpad {
                    bigButton("scope", "Center") { session.center() }
                }
                bigButton(session.link.paused ? "play.fill" : "pause.fill", session.link.paused ? "Resume" : "Pause") {
                    session.setPaused(!session.link.paused)
                }
            }
            .frame(height: 64)
        }
        .padding(16)
        .sheet(isPresented: $showSettings) { PhoneSettings() }
    }

    private var header: some View {
        HStack {
            Circle().fill(session.link.macPaused || session.link.paused ? Color.orange : mint).frame(width: 8, height: 8)
            Text(session.link.macName.isEmpty ? "Connected" : session.link.macName).font(.subheadline.weight(.semibold))
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3)
            }
            .tint(.white)
        }
    }

    private func bigButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panel, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// Tap to click, hold to drag. The Mac clicks where you were aiming when the
/// finger touched down.
struct ClickPad: View {
    @EnvironmentObject var session: PointerSession

    var body: some View {
        let on = session.pressing
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(on ? mint.opacity(0.35) : panel)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(on ? mint : Color.white.opacity(0.12), lineWidth: 1.5)
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: on ? "hand.point.up.left.fill" : "hand.tap").font(.system(size: 36))
                    Text(on ? "Holding" : "Tap to click · hold to drag").foregroundStyle(.secondary)
                    Text("Point the top edge at the screen").font(.caption).foregroundStyle(.tertiary)
                }
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in session.press() }
                    .onEnded { _ in session.release() }
            )
    }
}

/// Phone flat on the table: slide to move, tap to click, the lock button holds
/// the left button down for dragging.
struct TrackSurface: View {
    @EnvironmentObject var session: PointerSession
    @State private var last: CGPoint?
    @State private var startTime = Date()
    @State private var travelled: CGFloat = 0
    @State private var dragLock = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(panel)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.and.hand.point.up.left").font(.system(size: 36))
                        Text("Slide to move · tap to click").foregroundStyle(.secondary)
                    }
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if let l = last {
                                let dx = v.location.x - l.x, dy = v.location.y - l.y
                                travelled += abs(dx) + abs(dy)
                                // a little acceleration: slow = precise, fast = far
                                let speed = hypot(dx, dy)
                                let gain = 1.4 + min(speed / 12, 2.2)
                                session.link.move(dx: Double(dx * gain), dy: Double(dy * gain))
                            } else {
                                startTime = Date()
                                travelled = 0
                            }
                            last = v.location
                        }
                        .onEnded { _ in
                            last = nil
                            if travelled < 6 && Date().timeIntervalSince(startTime) < 0.25 {
                                session.press()
                                session.release()
                            }
                        }
                )

            Button {
                dragLock.toggle()
                if dragLock { session.press() } else { session.release() }
            } label: {
                Label(dragLock ? "Release" : "Hold", systemImage: dragLock ? "lock.fill" : "lock.open")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(dragLock ? mint : Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(dragLock ? Color.black : Color.white)
            }
            .padding(12)
        }
    }
}

/// Slide up and down to scroll, like two fingers on a trackpad.
struct ScrollStrip: View {
    @EnvironmentObject var session: PointerSession
    @State private var last: CGFloat?

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(panel)
            .overlay(
                VStack {
                    Image(systemName: "chevron.up")
                    Spacer()
                    Image(systemName: "arrow.up.and.down").font(.title3)
                    Text("Scroll").font(.caption2)
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 18)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if let l = last { session.link.scroll(dx: 0, dy: Double(v.location.y - l) * 2.2) }
                        last = v.location.y
                    }
                    .onEnded { _ in last = nil }
            )
    }
}

struct PhoneSettings: View {
    @EnvironmentObject var session: PointerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    LabeledContent("Paired with", value: session.link.macName.isEmpty ? "—" : session.link.macName)
                    Button("Unpair", role: .destructive) {
                        session.link.unpair()
                        dismiss()
                    }
                }
                Section("Tips") {
                    Text("Pointer: hold the phone like a remote with the top edge toward the screen. Aim at the middle and tap Center.")
                    Text("Speed, smoothing and inverting are set on the Mac, in the AimMac menu.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}
