import ChessKit
import Foundation

/// One-line explanations built from templates and the data we already have (no AI).
/// Where we can't say why, we say what changed and nothing more.
enum DrillExplainer {
    static func pieceName(_ kind: Piece.Kind) -> String {
        switch kind {
        case .pawn: "pawn"
        case .knight: "knight"
        case .bishop: "bishop"
        case .rook: "rook"
        case .queen: "queen"
        case .king: "king"
        }
    }

    private static func pawns(_ hundredths: Int) -> String {
        String(format: "%.1f", Double(abs(hundredths)) / 100)
    }

    // MARK: - The player's own mistakes

    static func sentence(for spot: DrillSpot, leak: LeakKind) -> String {
        let positions = spot.game.positions
        let before = positions[spot.ply - 1]
        let after = positions[min(spot.ply, positions.count - 1)]
        let best = spot.betterMove
        let played = spot.playedMove
        let lost = pawns(spot.loss)
        let mine: Piece.Color = spot.playerIsWhite ? .white : .black

        switch leak {
        case .hangingPieces:
            if let reply = spot.playedLine.first, reply.count >= 4 {
                let square = Square(String(reply.dropFirst(2).prefix(2)))
                if let target = after.piece(at: square), target.color == mine {
                    let replyMove = UCIMove.san(for: reply, in: after) ?? reply
                    let name = pieceName(target.kind)
                    let defended = after.pieces.contains {
                        $0.color == mine && $0.square != target.square
                            && TacticFinder.attackedSquares(by: $0, in: after).contains(square)
                    }
                    return defended
                        ? "Your \(name) on \(square.notation) could be taken by \(replyMove), and you lose material."
                        : "Your \(name) on \(square.notation) was undefended. \(replyMove) wins it."
                }
            }
            return "Your \(played) lost about \(lost) pawns. \(best) was safer."

        case .missedTactics:
            switch spot.tactic {
            case .checkmate:
                if let n = spot.mateIn { return "\(best) forces mate in \(n)." }
                return "\(best) forces checkmate."
            case .fork:
                if let names = forkTargets(spot, before: before), names.count >= 2 {
                    return "\(best) attacks the opponent's \(names[0]) and \(names[1]) at once."
                }
                return "\(best) forks two of the opponent's pieces."
            case .pin:
                return "\(best) pins an enemy piece to something more valuable."
            default:
                return "Stockfish's best line wins material, starting with \(best). Your \(played) gave up about \(lost) pawns."
            }

        case .notConverting:
            let lead = "+" + pawns(spot.evalBefore)
            if spot.loss > 0 {
                return "You were about \(lead) here. Trades and safe moves keep a lead; your \(played) gave back \(lost) pawns."
            }
            return "You were about \(lead) at this point but didn't win. Look for safe trades and avoid counterplay."

        case .notPunishing:
            let theirMove = spot.game.moveNames[spot.ply - 1].split(separator: " ").last.map(String.init) ?? "move"
            if let uci = spot.betterUCI, uci.count >= 4 {
                let square = Square(String(uci.dropFirst(2).prefix(2)))
                if let target = before.piece(at: square), target.color != mine {
                    return "Their \(theirMove) left their \(pieceName(target.kind)) loose. You missed \(best)."
                }
            }
            return "Their \(theirMove) gave you an advantage. You missed \(best), and your \(played) gave back \(lost) pawns."

        case .rushedMoves:
            return "Stockfish prefers \(best). Your \(played) lost about \(lost) pawns, and you played it in seconds. Pause to check captures, checks and threats."

        case .timeTrouble:
            return "Stockfish prefers \(best). Your \(played) lost about \(lost) pawns when your clock was low."

        case .middlegameDrift:
            return "Stockfish prefers \(best). Your \(played) was one of several small slips that added up (about \(lost) pawns here)."
        }
    }

    /// Names of the valuable pieces that the better move attacks, biggest first.
    private static func forkTargets(_ spot: DrillSpot, before: Position) -> [String]? {
        guard let uci = spot.betterUCI ?? UCIMove.uci(forSAN: spot.betterMove, in: before) else { return nil }
        var board = Board(position: before)
        guard UCIMove.play(uci, on: &board) != nil else { return nil }
        let end = Square(String(uci.dropFirst(2).prefix(2)))
        guard let moved = board.position.piece(at: end) else { return nil }
        let targets = TacticFinder.attackedSquares(by: moved, in: board.position)
            .compactMap { board.position.piece(at: $0) }
            .filter { $0.color != moved.color && $0.kind != .pawn }
            .sorted { TacticFinder.pieceValue($0.kind) > TacticFinder.pieceValue($1.kind) || $0.kind == .king }
        return targets.map { pieceName($0.kind) }
    }

    // MARK: - Puzzles

    /// A sentence based on the Lichess theme tags, taking the most specific theme first.
    static func sentence(for puzzle: Puzzle) -> String {
        let table: [(String, String)] = [
            ("mateIn1", "Checkmate in one move."),
            ("mateIn2", "Checkmate in two moves."),
            ("mateIn3", "Checkmate in three moves."),
            ("fork", "A fork: one piece attacks two targets at once."),
            ("pin", "A pin: a piece can't move without exposing something more valuable."),
            ("skewer", "A skewer: attack a big piece so it has to move and leaves something behind it."),
            ("discoveredAttack", "A discovered attack: moving one piece uncovers an attack by another."),
            ("doubleCheck", "A double check: the king is attacked twice, so it has to move."),
            ("hangingPiece", "A piece was left undefended, so it can be taken for free."),
            ("trappedPiece", "A piece has no safe squares left, so it can be won."),
            ("quietMove", "A quiet move, with no capture or check, that sets up the win."),
            ("defensiveMove", "The best move here is a defensive one that keeps you safe."),
            ("crushing", "You are winning big; the best move keeps the pressure on."),
            ("advantage", "You have an advantage; the best move keeps it."),
            ("endgame", "An endgame: every move counts, so look for the most accurate one."),
        ]
        for (theme, text) in table where puzzle.themes.contains(theme) { return text }
        return "Look for checks, captures and threats."
    }
}
