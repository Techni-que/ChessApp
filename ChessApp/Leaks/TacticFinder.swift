import ChessKit

/// The kinds of winning tactic the report can name. Anything we can't name safely is "other".
enum TacticType: Hashable {
    case checkmate, fork, pin, other

    /// Lichess puzzle themes that practise this kind of tactic.
    var themes: Set<String> {
        switch self {
        case .checkmate: ["mateIn1", "mateIn2", "mateIn3"]
        case .fork: ["fork"]
        case .pin: ["pin"]
        case .other: ["fork", "pin", "skewer", "discoveredAttack", "doubleCheck"]
        }
    }

    /// For example "3 checkmates" or "1 fork".
    func phrase(count: Int) -> String {
        switch self {
        case .checkmate: count == 1 ? "1 checkmate" : "\(count) checkmates"
        case .fork: count == 1 ? "1 fork" : "\(count) forks"
        case .pin: count == 1 ? "1 pin" : "\(count) pins"
        case .other: count == 1 ? "1 other tactic" : "\(count) other tactics"
        }
    }
}

/// Simple, deliberately cautious checks that look at a position and say what a tactic is.
/// If a check isn't sure, the answer is "other": a vague label is better than a wrong one.
enum TacticFinder {
    /// Material points: pawn 1, knight and bishop 3, rook 5, queen 9 (kings don't count).
    static func pieceValue(_ kind: Piece.Kind) -> Int {
        switch kind {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 0
        }
    }

    /// Material for one side minus the other side.
    static func material(_ position: Position, forWhite: Bool) -> Int {
        var total = 0
        for piece in position.pieces {
            total += (piece.color == .white) == forWhite ? pieceValue(piece.kind) : -pieceValue(piece.kind)
        }
        return total
    }

    /// How much material the side to move wins if both sides follow `line` (Stockfish's best line).
    /// We look at the position after the opponent's reply (2 or 4 moves in), so a capture that is
    /// simply recaptured doesn't count as a win.
    static func materialGain(from position: Position, line: [String], forWhite: Bool) -> Int {
        var board = Board(position: position)
        let start = material(position, forWhite: forWhite)
        var afterFirst: Int?
        var afterLastReply: Int?
        for (index, uci) in line.prefix(4).enumerated() {
            guard UCIMove.play(uci, on: &board) != nil else { break }
            let now = material(board.position, forWhite: forWhite)
            if index == 0 { afterFirst = now }
            if (index + 1) % 2 == 0 { afterLastReply = now }
        }
        // A one-move line has no reply, so judge it after that single move.
        guard let end = afterLastReply ?? afterFirst else { return 0 }
        return end - start
    }

    /// Names the tactic behind Stockfish's first move: a fork, a pin, or "other".
    static func classify(firstMove uci: String, from position: Position) -> TacticType {
        var board = Board(position: position)
        guard UCIMove.play(uci, on: &board) != nil else { return .other }
        let end = Square(String(uci.dropFirst(2).prefix(2)))
        guard let moved = board.position.piece(at: end) else { return .other }
        if isFork(moved, in: board.position) { return .fork }
        if isPin(moved, in: board.position) { return .pin }
        return .other
    }

    // MARK: - Fork and pin

    /// A fork: one piece attacks two or more enemy pieces worth more than a pawn (a king counts),
    /// and no enemy piece of equal or lower value can simply capture it.
    static func isFork(_ forker: Piece, in position: Position) -> Bool {
        guard forker.kind != .king else { return false }
        let enemy = forker.color.opposite
        let targets = attackedSquares(by: forker, in: position)
            .compactMap { position.piece(at: $0) }
            .filter { $0.color == enemy && $0.kind != .pawn }
        guard targets.count >= 2 else { return false }

        let myValue = pieceValue(forker.kind)
        for piece in position.pieces where piece.color == enemy && piece.kind != .king {
            if pieceValue(piece.kind) <= myValue, attackedSquares(by: piece, in: position).contains(forker.square) {
                return false
            }
        }
        return true
    }

    /// A pin: a bishop, rook or queen attacks an enemy piece that has a more valuable
    /// enemy piece (or the king) directly behind it on the same line.
    static func isPin(_ pinner: Piece, in position: Position) -> Bool {
        let directions: [(Int, Int)]
        switch pinner.kind {
        case .bishop: directions = diagonals
        case .rook: directions = straights
        case .queen: directions = diagonals + straights
        default: return false
        }
        let enemy = pinner.color.opposite
        let start = pinner.square
        for (df, dr) in directions {
            var front: Piece?
            var file = start.file.number + df
            var rank = start.rank.value + dr
            while let square = square(file, rank) {
                if let piece = position.piece(at: square) {
                    if let front {
                        if piece.color == enemy, front.kind != .king,
                           piece.kind == .king || pieceValue(piece.kind) > pieceValue(front.kind) {
                            return true
                        }
                        break
                    }
                    guard piece.color == enemy else { break }
                    front = piece
                }
                file += df
                rank += dr
            }
        }
        return false
    }

    // MARK: - Board geometry

    private static let straights = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let diagonals = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    private static let knightJumps = [(1, 2), (2, 1), (-1, 2), (-2, 1), (1, -2), (2, -1), (-1, -2), (-2, -1)]

    private static func square(_ file: Int, _ rank: Int) -> Square? {
        guard (1...8).contains(file), (1...8).contains(rank) else { return nil }
        return Square("\(Square.File(file).rawValue)\(rank)")
    }

    /// Every square a piece attacks (pins and checks are ignored; this is pure geometry).
    static func attackedSquares(by piece: Piece, in position: Position) -> [Square] {
        let file = piece.square.file.number
        let rank = piece.square.rank.value
        var result: [Square] = []

        func slide(_ directions: [(Int, Int)]) {
            for (df, dr) in directions {
                var f = file + df
                var r = rank + dr
                while let target = square(f, r) {
                    result.append(target)
                    if position.piece(at: target) != nil { break }
                    f += df
                    r += dr
                }
            }
        }
        func jump(_ offsets: [(Int, Int)]) {
            for (df, dr) in offsets {
                if let target = square(file + df, rank + dr) { result.append(target) }
            }
        }

        switch piece.kind {
        case .rook: slide(straights)
        case .bishop: slide(diagonals)
        case .queen: slide(straights + diagonals)
        case .knight: jump(knightJumps)
        case .king: jump(straights + diagonals)
        case .pawn:
            let forward = piece.color == .white ? 1 : -1
            jump([(-1, forward), (1, forward)])
        }
        return result
    }
}
