import ChessKit

/// The kinds of winning tactic the report can name. Anything we can't name safely is "other".
enum TacticType: Hashable {
    /// `sacrifice` is only used to pick puzzles; our own sacrifice detection was too unreliable to show.
    case checkmate, fork, pin, skewer, sacrifice, discovery, hanging, other

    /// Lichess puzzle themes that practise this kind of tactic.
    var themes: Set<String> {
        switch self {
        case .checkmate: ["mateIn1", "mateIn2", "mateIn3"]
        case .fork: ["fork"]
        case .pin: ["pin"]
        case .skewer: ["skewer"]
        case .sacrifice: ["sacrifice"]
        case .discovery: ["discoveredAttack"]
        case .hanging: ["hangingPiece", "trappedPiece"]
        case .other: ["fork", "pin", "skewer", "discoveredAttack", "doubleCheck"]
        }
    }

    /// For example "3 checkmates" or "1 fork".
    func phrase(count: Int) -> String {
        switch self {
        case .checkmate: count == 1 ? "1 checkmate" : "\(count) checkmates"
        case .fork: count == 1 ? "1 fork" : "\(count) forks"
        case .pin: count == 1 ? "1 pin" : "\(count) pins"
        case .skewer: count == 1 ? "1 skewer" : "\(count) skewers"
        case .sacrifice: count == 1 ? "1 sacrifice" : "\(count) sacrifices"
        case .discovery: count == 1 ? "1 discovered attack" : "\(count) discovered attacks"
        case .hanging: count == 1 ? "1 hanging piece" : "\(count) hanging pieces"
        case .other: count == 1 ? "1 other tactic" : "\(count) other tactics"
        }
    }

    /// A label for the card, like "missed forks (3)".
    func habitLabel(count: Int) -> String {
        let one = count == 1
        let name: String
        switch self {
        case .checkmate: name = one ? "missed checkmate" : "missed checkmates"
        case .fork: name = one ? "missed fork" : "missed forks"
        case .pin: name = one ? "missed pin" : "missed pins"
        case .skewer: name = one ? "missed skewer" : "missed skewers"
        case .sacrifice: name = one ? "missed sacrifice" : "missed sacrifices"
        case .discovery: name = one ? "missed discovered attack" : "missed discovered attacks"
        case .hanging: name = one ? "hanging piece" : "hanging pieces"
        case .other: name = one ? "other missed tactic" : "other missed tactics"
        }
        return "\(name) (\(count))"
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

    /// Names the tactic behind Stockfish's first move. Order: fork, skewer, pin, discovered attack
    /// (all judged on the board after the move), then sacrifice (judged from the whole line), else "other".
    /// Names the tactic behind Stockfish's first move, judged on the board after the move:
    /// fork, skewer, pin (absolute pins only), discovered attack, else "other".
    /// Sacrifices are not labelled: in tests against Lichess's own puzzle tags, our sacrifice rule agreed only about
    /// a third of the time, which is too unreliable to show. Better to say "other" than to guess.
    static func classify(firstMove uci: String, from position: Position) -> TacticType {
        var board = Board(position: position)
        guard UCIMove.play(uci, on: &board) != nil else { return .other }
        let end = Square(String(uci.dropFirst(2).prefix(2)))
        guard let moved = board.position.piece(at: end) else { return .other }
        if isFork(moved, in: board.position) { return .fork }
        if isSkewer(moved, in: board.position) { return .skewer }
        if isPin(moved, in: board.position) { return .pin }
        if isDiscovery(before: position, after: board.position, moved: moved) { return .discovery }
        return .other
    }

    /// A skewer: a bishop, rook or queen attacks an enemy piece that must move (the king, or something more
    /// valuable than what stands behind it), and a piece worth at least a knight is directly behind it.
    static func isSkewer(_ slider: Piece, in position: Position) -> Bool {
        let directions: [(Int, Int)]
        switch slider.kind {
        case .bishop: directions = diagonals
        case .rook: directions = straights
        case .queen: directions = diagonals + straights
        default: return false
        }
        let enemy = slider.color.opposite
        for (df, dr) in directions {
            var front: Piece?
            var file = slider.square.file.number + df
            var rank = slider.square.rank.value + dr
            while let target = square(file, rank) {
                if let piece = position.piece(at: target) {
                    guard piece.color == enemy else { break }
                    if let front {
                        if piece.kind != .king, piece.kind != .pawn,
                           front.kind == .king || pieceValue(front.kind) > pieceValue(piece.kind) {
                            return true
                        }
                        break
                    }
                    front = piece
                }
                file += df
                rank += dr
            }
        }
        return false
    }

    /// A discovered attack: moving a piece uncovers a bishop, rook or queen of the same side onto an enemy
    /// king, queen or rook that it wasn't attacking before.
    static func isDiscovery(before: Position, after: Position, moved: Piece) -> Bool {
        for slider in after.pieces where slider.color == moved.color && slider.square != moved.square {
            guard [.bishop, .rook, .queen].contains(slider.kind),
                  let earlier = before.piece(at: slider.square), earlier.kind == slider.kind, earlier.color == slider.color
            else { continue }
            let attackedBefore = Set(attackedSquares(by: earlier, in: before))
            for target in attackedSquares(by: slider, in: after) where !attackedBefore.contains(target) {
                if let victim = after.piece(at: target), victim.color != moved.color,
                   victim.kind == .king || victim.kind == .queen || victim.kind == .rook {
                    return true
                }
            }
        }
        return false
    }

    /// Pieces (not pawns or kings) of one colour that the opponent could simply win: attacked and either
    /// undefended or attacked by something worth less. Pins are ignored; this is pure geometry.
    static func enPrise(_ position: Position, color: Piece.Color) -> [Square] {
        var result: [Square] = []
        for piece in position.pieces where piece.color == color && piece.kind != .king && piece.kind != .pawn {
            let attackers = position.pieces.filter { $0.color != color && attackedSquares(by: $0, in: position).contains(piece.square) }
            guard !attackers.isEmpty else { continue }
            let defended = position.pieces.contains {
                $0.color == color && $0.square != piece.square && attackedSquares(by: $0, in: position).contains(piece.square)
            }
            if !defended || attackers.contains(where: { $0.kind != .king && pieceValue($0.kind) < pieceValue(piece.kind) }) {
                result.append(piece.square)
            }
        }
        return result
    }

    // MARK: - Fork and pin

    /// A fork: one piece attacks two or more enemy pieces worth more than a pawn (a king counts), it can't simply
    /// be captured for free or for gain, and at least one of the targets is worth winning (the king, something
    /// worth more than the forking piece, or something nobody defends).
    static func isFork(_ forker: Piece, in position: Position) -> Bool {
        guard forker.kind != .king else { return false }
        let enemy = forker.color.opposite
        let targets = attackedSquares(by: forker, in: position)
            .compactMap { position.piece(at: $0) }
            .filter { $0.color == enemy && $0.kind != .pawn }
        guard targets.count >= 2 else { return false }

        let myValue = pieceValue(forker.kind)
        let defended = position.pieces.contains {
            $0.color == forker.color && $0.square != forker.square && attackedSquares(by: $0, in: position).contains(forker.square)
        }
        for piece in position.pieces where piece.color == enemy && attackedSquares(by: piece, in: position).contains(forker.square) {
            // A king can only take an undefended piece; anything else captures if that is free or wins material.
            if piece.kind == .king ? !defended : (!defended || pieceValue(piece.kind) < myValue) { return false }
        }
        return targets.contains { target in
            target.kind == .king || pieceValue(target.kind) > myValue
                || !position.pieces.contains { $0.color == enemy && $0.square != target.square && attackedSquares(by: $0, in: position).contains(target.square) }
        }
    }

    /// A pin: a bishop, rook or queen attacks an enemy piece that has the enemy king directly behind it
    /// on the same line, so the piece can't move.
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
                        // Only absolute pins (the piece is pinned to the king). In tests, these agreed with Lichess's
                        // own pin tags 70% of the time, against about 50% when pins to other pieces were included.
                        if piece.color == enemy, front.kind != .king, piece.kind == .king {
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
