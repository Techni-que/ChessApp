import ChessKit
import Observation

/// Loads a game from PGN and keeps track of which move the user is looking at.
@Observable
final class GameViewerModel {
    let white: String
    let black: String
    /// Board positions in order: index 0 is the starting position, index 1 is after the first move, etc.
    private(set) var positions: [Position] = []
    /// The move text (like "Nf3") that led to each position. Empty for the starting position.
    private(set) var moveNames: [String] = []
    /// Which position is currently shown.
    var currentIndex = 0

    init(pgn: String) {
        let game = (try? Game(pgn: pgn)) ?? Game()
        white = game.tags.white
        black = game.tags.black

        // Walk the main line of the game from start to finish.
        var index = game.startingIndex
        positions.append(game.positions[index] ?? .standard)
        moveNames.append("")
        while game.moves.hasIndex(after: index) {
            index = game.moves.index(after: index)
            guard let position = game.positions[index] else { break }
            positions.append(position)
            moveNames.append(Self.label(for: index, san: game.moves[index]?.san ?? ""))
        }
    }

    var currentPosition: Position { positions[currentIndex] }
    var currentMoveName: String { moveNames[currentIndex] }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < positions.count - 1 }

    func goToStart() { currentIndex = 0 }
    func goBack() { if canGoBack { currentIndex -= 1 } }
    func goForward() { if canGoForward { currentIndex += 1 } }
    func goToEnd() { currentIndex = positions.count - 1 }

    /// Turns a move into readable text like "1. e4" or "1... e5".
    private static func label(for index: MoveTree.Index, san: String) -> String {
        index.color == .white ? "\(index.number). \(san)" : "\(index.number)... \(san)"
    }
}
