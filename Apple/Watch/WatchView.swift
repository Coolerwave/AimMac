import SwiftUI
import WatchKit

private let mint = Color(red: 0.36, green: 0.95, blue: 0.72)

struct WatchRoot: View {
    @EnvironmentObject var session: PointerSession

    var body: some View {
        switch session.link.state {
        case .bluetoothOff:
            Message(icon: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth is off",
                    text: "Turn it on in Settings.")
        case .searching where !session.link.hasPairedMac:
            MacPicker()
        case .searching, .connecting:
            Message(icon: "laptopcomputer", title: "Connecting…",
                    text: "Open AimMac on your Mac.", unpair: true)
        case .waitingApproval:
            Message(icon: "checkmark.shield", title: "Allow on your Mac",
                    text: "Click Allow in the window on \(session.link.macName.isEmpty ? "your Mac" : session.link.macName).")
        case .denied:
            Message(icon: "xmark.shield", title: "Not allowed",
                    text: "The Mac declined this watch.", unpair: true)
        case .ready:
            WatchPad()
        }
    }
}

struct MacPicker: View {
    @EnvironmentObject var session: PointerSession

    var body: some View {
        List {
            Section {
                if session.link.found.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for Macs…").foregroundStyle(.secondary)
                    }
                }
                ForEach(session.link.found) { mac in
                    Button {
                        session.link.pair(mac)
                    } label: {
                        HStack {
                            Image(systemName: "laptopcomputer")
                            Text(mac.name)
                            Spacer()
                            Text("Pair").foregroundStyle(mint)
                        }
                    }
                }
            } header: {
                Text("Pair with a Mac")
            } footer: {
                Text("AimMac must be running on the Mac.")
            }
        }
    }
}

struct Message: View {
    @EnvironmentObject var session: PointerSession
    let icon: String
    let title: String
    let text: String
    var unpair = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(mint)
                Text(title).font(.headline)
                Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if unpair {
                    Button("Choose another Mac") { session.link.unpair() }
                        .padding(.top, 6)
                }
            }
            .padding()
        }
    }
}

/// The remote: a big pad (tap = click, hold = drag), right click, center,
/// pause, and the Digital Crown to scroll.
struct WatchPad: View {
    @EnvironmentObject var session: PointerSession
    @State private var crown = 0.0
    @State private var lastCrown = 0.0
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 6) {
            pad
            HStack(spacing: 6) {
                small("cursorarrow.click.2", "Right") { session.rightClick() }
                small("scope", "Center") { session.center() }
                small(session.link.paused ? "play.fill" : "pause.fill", session.link.paused ? "Go" : "Pause") {
                    session.setPaused(!session.link.paused)
                }
                small("gearshape", "More") { showSettings = true }
            }
        }
        .padding(.horizontal, 4)
        .focusable(true)
        .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: nil,
                              sensitivity: .high, isContinuous: true, isHapticFeedbackEnabled: false)
        .onChange(of: crown) { _, new in
            let d = new - lastCrown
            lastCrown = new
            session.link.scroll(dx: 0, dy: -d * 6)
        }
        .sheet(isPresented: $showSettings) { WatchSettings() }
        .onDisappear { session.release() }
    }

    private var pad: some View {
        let active = session.pressing
        let paused = session.link.paused || session.link.macPaused
        return RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(active ? mint.opacity(0.45) : Color.white.opacity(0.10))
            .overlay(
                VStack(spacing: 2) {
                    Image(systemName: paused ? "pause.circle" : (active ? "hand.point.up.left.fill" : "dot.circle.and.hand.point.up.left.fill"))
                        .font(.title3)
                    Text(paused ? "Paused" : (active ? "Click!" : "Tap to click"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(active ? mint : Color.white.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
            // A tap is a complete click (down and up sent together), so the
            // cursor can never stay frozen waiting for a "release" that got lost.
            .onTapGesture { session.tap() }
    }

    private func small(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WatchSettings: View {
    @EnvironmentObject var session: PointerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Mac") {
                Text(session.link.macName.isEmpty ? "Connected" : session.link.macName)
                Button("Unpair", role: .destructive) {
                    session.link.unpair()
                    dismiss()
                }
            }
            Section("How to hold it") {
                Text("Point the 12 o'clock edge at the screen. Aim at the middle and tap Center.")
                    .font(.footnote)
            }
        }
    }
}
