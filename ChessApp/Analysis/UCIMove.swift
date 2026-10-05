import ChessKit

/// Helpers for Stockfish's move format, like "e2e4" or "e7e8q".
enum UCIMove {
    /// Plays an engine move on a board. Returns the move if it was legal.
    @discardableResult
    static func play(_ uci: String, on board: inout Board) -> Move? {
        guard uci.count >= 4 else { return nil }
        let start = Square(String(uci.prefix(2)))
        let end = Square(String(uci.dropFirst(2).prefix(2)))
        guard var move = board.move(pieceAt: start, to: end) else { return nil }
        if case .promotion(let pending) = board.state {
            let letter = uci.count == 5 ? uci.suffix(1).uppercased() : "Q"
            move = board.completePromotion(of: pending, to: Piece.Kind(rawValue: letter) ?? .queen)
        }
        return move
    }

    /// Turns an engine move like "g1f3" into normal chess notation like "Nf3".
    static func san(for uci: String, in position: Position) -> String? {
        var board = Board(position: position)
        return play(uci, on: &board)?.san
    }
}
