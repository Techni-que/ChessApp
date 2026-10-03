import SwiftUI

/// The main screen: player names, the board, the current move, and step buttons.
struct GameViewerView: View {
    @State private var model = GameViewerModel(pgn: SampleGames.operaGame)

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(model.black).font(.headline)
                Text("vs").font(.caption).foregroundStyle(.secondary)
                Text(model.white).font(.headline)
            }

            ChessBoardView(position: model.currentPosition)
                .padding(.horizontal)

            Text(model.currentMoveName.isEmpty ? "Starting position" : model.currentMoveName)
                .font(.title2.monospaced())

            Text("Move \(model.currentIndex) of \(model.positions.count - 1)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 32) {
                Button(action: model.goToStart) { Image(systemName: "backward.end.fill") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("First move")
                Button(action: model.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("Previous move")
                Button(action: model.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel("Next move")
                Button(action: model.goToEnd) { Image(systemName: "forward.end.fill") }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel("Last move")
            }
            .font(.title)
        }
        .padding()
    }
}

#Preview {
    GameViewerView()
}
