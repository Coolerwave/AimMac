import SwiftUI

@main
struct AimPhoneApp: App {
    @StateObject private var session = PointerSession()

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}
