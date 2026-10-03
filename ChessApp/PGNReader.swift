import ChessKit
import Foundation

/// A game read from PGN text: the player names plus every board position in order.
struct LoadedGame {
    var tags: [String: String]
    /// Index 0 is the starting position, index 1 is after the first move, and so on.
    var positions: [Position]
    /// Readable move text (like "1. e4" or "1... e5") for each position. Empty for the start.
    var moveNames: [String]
    /// False if a move couldn't be read, so the game stops early.
    var isComplete: Bool

    var white: String { tags["White"] ?? "White" }
    var black: String { tags["Black"] ?? "Black" }
}

/// Reads PGN text (the standard chess game format) into a `LoadedGame`.
///
/// ChessKit's own PGN parser forgets en passant captures, so it fails on games
/// that contain one. Here we only use ChessKit to understand each move and to
/// play it on a `Board`, which does track en passant.
enum PGNReader {
    static func read(_ pgn: String) -> LoadedGame? {
        let tags = readTags(pgn)
        let startPosition = tags["FEN"].flatMap { Position(fen: $0) } ?? .standard
        var board = Board(position: startPosition)

        var positions = [startPosition]
        var moveNames = [""]
        var moveNumber = startPosition.clock.fullmoves
        var isComplete = true

        for san in moveTokens(pgn) {
            let color = board.position.sideToMove
            guard let (start, end, promotion) = resolve(san, on: board),
                  var move = board.move(pieceAt: start, to: end)
            else {
                isComplete = false
                break
            }
            if let promotion {
                move = board.completePromotion(of: move, to: promotion)
            }
            positions.append(board.position)
            moveNames.append(color == .white ? "\(moveNumber). \(san)" : "\(moveNumber)... \(san)")
            if color == .black { moveNumber += 1 }
        }

        // Nothing usable: no tags and no moves.
        if tags.isEmpty && positions.count == 1 { return nil }
        return LoadedGame(tags: tags, positions: positions, moveNames: moveNames, isComplete: isComplete)
    }

    /// Works out which piece moves where for a move like "Nbd7", "exd5", "O-O" or "e8=Q".
    ///
    /// ChessKit's own SAN reader ignores hints like the "e" in "Rexe3" on captures,
    /// so we find the piece ourselves using the board's list of legal moves.
    static func resolve(_ san: String, on board: Board) -> (start: Square, end: Square, promotion: Piece.Kind?)? {
        let position = board.position
        let color = position.sideToMove
        let homeRank = color == .white ? "1" : "8"

        if san.hasPrefix("O-O") {
            guard let king = position.pieces.first(where: { $0.kind == .king && $0.color == color }) else { return nil }
            let end = Square((san.hasPrefix("O-O-O") ? "c" : "g") + homeRank)
            return board.canMove(pieceAt: king.square, to: end) ? (king.square, end, nil) : nil
        }

        let pattern = /^([KQRBN])?([a-h])?([1-8])?x?([a-h][1-8])(?:=?([QRBN]))?[+#]?$/
        guard let match = san.wholeMatch(of: pattern) else { return nil }

        let kind = match.1.flatMap { Piece.Kind(rawValue: String($0)) } ?? .pawn
        let fromFile = match.2.map(String.init)
        let fromRank = match.3.map(String.init)
        let end = Square(String(match.4))
        let promotion = match.5.flatMap { Piece.Kind(rawValue: String($0)) }

        let candidates = position.pieces.filter { piece in
            piece.kind == kind && piece.color == color
                && (fromFile == nil || piece.square.file.rawValue == fromFile)
                && (fromRank == nil || String(piece.square.rank.value) == fromRank)
                && board.legalMoves(forPieceAt: piece.square).contains(end)
        }
        guard candidates.count == 1, let piece = candidates.first else { return nil }
        return (piece.square, end, promotion)
    }

    /// Reads header lines like `[White "Paul Morphy"]`.
    static func readTags(_ pgn: String) -> [String: String] {
        var tags: [String: String] = [:]
        let regex = /\[(\w+)\s+"((?:[^"\\]|\\.)*)"\]/
        for match in pgn.matches(of: regex) {
            tags[String(match.1)] = String(match.2)
        }
        return tags
    }

    /// Pulls out just the moves (like "e4", "Nf3", "O-O"), skipping move numbers,
    /// comments in {braces}, side lines in (brackets), and the result.
    static func moveTokens(_ pgn: String) -> [String] {
        var text = pgn.replacing(/\[[^\]]*\]/, with: " ")   // header tags
        text = text.replacing(/\{[^}]*\}/, with: " ")        // {comments}
        text = text.replacing(/;[^\n]*/, with: " ")          // ; comments
        text = text.replacing(/\$\d+/, with: " ")            // $1 style annotations

        // Remove (side lines), which can be nested inside each other.
        var mainLine = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            else if character == ")" { depth = max(0, depth - 1) }
            else if depth == 0 { mainLine.append(character) }
        }

        let results: Set<String> = ["1-0", "0-1", "1/2-1/2", "*"]
        return mainLine
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                String(token)
                    .replacing(/^\d+\.+/, with: "")        // move numbers like "12." or "12..."
                    .replacing(/[!?]+$/, with: "")          // move quality marks like "!?"
                    .replacing("0-0-0", with: "O-O-O")
                    .replacing("0-0", with: "O-O")
            }
            .filter { !$0.isEmpty && !results.contains($0) }
    }
}
