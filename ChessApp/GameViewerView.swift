import SwiftUI

/// Shows one game: player names, the board, the current move, and step buttons.
struct GameViewerView: View {
    @State private var model: GameViewerModel

    init(game: LoadedGame) {
        _model = State(initialValue: GameViewerModel(game: game))
    }

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

            Text("Move \(model.currentIndex) of \(model.moveCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.game.isComplete {
                Text("Some moves in this game couldn't be read, so it stops early.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

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
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        GameViewerView(game: PGNReader.read(SampleGames.operaGame)!)
    }
}
