import SwiftUI

/// The app's starting point. It opens one window showing the game viewer.
@main
struct ChessAppApp: App {
    var body: some Scene {
        WindowGroup {
            GameViewerView()
        }
    }
}
