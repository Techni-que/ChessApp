import ChessKit
import Observation

/// Holds a loaded game and keeps track of which move the user is looking at.
@Observable
final class GameViewerModel {
    let game: LoadedGame
    /// Which position is currently shown (0 is the starting position).
    var currentIndex = 0

    init(game: LoadedGame) {
        self.game = game
    }

    var white: String { game.white }
    var black: String { game.black }
    var moveCount: Int { game.positions.count - 1 }
    var currentPosition: Position { game.positions[currentIndex] }
    var currentMoveName: String { game.moveNames[currentIndex] }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < moveCount }

    func goToStart() { currentIndex = 0 }
    func goBack() { if canGoBack { currentIndex -= 1 } }
    func goForward() { if canGoForward { currentIndex += 1 } }
    func goToEnd() { currentIndex = moveCount }
}
