import SwiftUI

@main
struct AimWatchApp: App {
    @StateObject private var session = PointerSession()

    var body: some Scene {
        WindowGroup {
            WatchRoot()
                .environmentObject(session)
        }
    }
}
