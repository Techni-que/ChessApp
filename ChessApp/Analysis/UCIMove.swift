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
        return play(uci, on: &board).map { display($0.san) }
    }

    /// Writes castling with letters ("O-O-O"), because ChessKit writes it with zeros.
    static func display(_ san: String) -> String {
        san.replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "0-0-0", with: "O-O-O")
            .replacingOccurrences(of: "0-0", with: "O-O")
    }

    /// Finds the engine move (like "g1f3") for a move written in normal notation (like "Nf3").
    static func uci(forSAN san: String, in position: Position) -> String? {
        let target = san.filter { $0 != "+" && $0 != "#" }
        let start = Board(position: position)
        for piece in position.pieces where piece.color == position.sideToMove {
            for destination in start.legalMoves(forPieceAt: piece.square) {
                var board = start
                guard var move = board.move(pieceAt: piece.square, to: destination) else { continue }
                var uci = piece.square.notation + destination.notation
                if case .promotion(let pending) = board.state {
                    move = board.completePromotion(of: pending, to: .queen)
                    uci += "q"
                }
                if move.san.filter({ $0 != "+" && $0 != "#" }) == target { return uci }
            }
        }
        return nil
    }
}
