import SwiftUI

/// The app's starting point. It opens on the home screen.
@main
struct ChessAppApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
