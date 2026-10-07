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

    /// A score with its real sign, like "+2.6" or "-0.8".
    private static func signed(_ hundredths: Int) -> String {
        (hundredths < 0 ? "-" : "+") + pawns(hundredths)
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
            case .skewer:
                return "\(best) attacks a big piece that has to move, and you win what stands behind it."
            case .discovery:
                return "\(best) uncovers an attack from another of your pieces, so your opponent faces two threats at once."
            case .sacrifice:
                return "\(best) gives up material first, but the line wins more back."
            default:
                return "Stockfish's best line wins material, starting with \(best). Your \(played) gave up about \(lost) pawns."
            }

        case .notConverting:
            // What actually happens after the move that was played, from Stockfish's best reply.
            let afterEval = spot.evalBefore - spot.loss
            var sentence = "You were \(signed(spot.evalBefore)) here."
            if let reply = spot.playedLine.first, reply.count >= 4, let replySAN = UCIMove.san(for: reply, in: after) {
                let target = Square(String(reply.dropFirst(2).prefix(2)))
                if let taken = after.piece(at: target), taken.color == mine {
                    sentence += " After \(played), \(replySAN) wins your \(pieceName(taken.kind))."
                } else if replySAN.contains("+") {
                    sentence += " After \(played), \(replySAN) gives check and takes the initiative."
                } else {
                    sentence += " After \(played), Stockfish answers \(replySAN)."
                }
            }
            sentence += " The evaluation swung by \(lost) pawns, to \(signed(afterEval))."
            let gain = TacticFinder.materialGain(from: before, line: spot.bestLine, forWhite: spot.playerIsWhite)
            sentence += gain >= 1 ? " \(best) wins material and keeps the lead." : " \(best) keeps the lead."
            return sentence

        case .notPunishing:
            let theirMove = spot.game.moveNames[spot.ply - 1].split(separator: " ").last.map(String.init) ?? "move"
            if let uci = spot.betterUCI, uci.count >= 4 {
                let square = Square(String(uci.dropFirst(2).prefix(2)))
                if let target = before.piece(at: square), target.color != mine {
                    return "After their \(theirMove), \(best) could take their \(pieceName(target.kind)). You played \(played) instead, and the evaluation swung by \(lost) pawns."
                }
            }
            return "Their \(theirMove) was a mistake. You missed \(best), and your \(played) swung the evaluation by \(lost) pawns."

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

    /// What one step of a puzzle's solution does, worked out from the board (not from the puzzle's tags).
    private struct Step {
        let san: String
        let mine: Bool
        let captured: Piece?
        let forkTargets: [String]
        let pins: Bool
    }

    private static func targetNames(of piece: Piece, in position: Position) -> [String] {
        TacticFinder.attackedSquares(by: piece, in: position)
            .compactMap { position.piece(at: $0) }
            .filter { $0.color != piece.color && $0.kind != .pawn }
            .sorted { TacticFinder.pieceValue($0.kind) > TacticFinder.pieceValue($1.kind) || $0.kind == .king }
            .map { pieceName($0.kind) }
    }

    /// A concrete sentence about the puzzle's solution, or nil when we can't say anything safe.
    /// It describes what the moves really do. `wanted` are the themes that put this puzzle in the drill;
    /// when the puzzle shows more than one idea, the idea that matches those themes is mentioned first.
    static func sentence(for puzzle: Puzzle, wanted: Set<String>) -> String? {
        var board = Board(position: Position(fen: puzzle.fen) ?? .standard)
        guard let setup = puzzle.moves.first, UCIMove.play(setup, on: &board) != nil else { return nil }
        let moverIsWhite = board.position.sideToMove == .white
        let startMaterial = TacticFinder.material(board.position, forWhite: moverIsWhite)

        var steps: [Step] = []
        for (index, uci) in puzzle.moves.dropFirst().enumerated() {
            let dest = Square(String(uci.dropFirst(2).prefix(2)))
            let captured = board.position.piece(at: dest)
            guard let move = UCIMove.play(uci, on: &board) else { break }
            let mine = index % 2 == 0
            var forks: [String] = []
            var pins = false
            if mine, let moved = board.position.piece(at: dest) {
                if TacticFinder.isFork(moved, in: board.position) {
                    forks = targetNames(of: moved, in: board.position)
                } else if TacticFinder.isPin(moved, in: board.position) {
                    pins = true
                }
            }
            steps.append(Step(san: UCIMove.display(move.san), mine: mine, captured: captured, forkTargets: forks, pins: pins))
        }
        guard let first = steps.first else { return nil }
        let yourSteps = steps.enumerated().filter { $0.element.mine }

        /// "Rxg8, then Rg1+ ..." when the idea happens on a later move, or just "Rxg8 ..." on the first.
        func lead(_ at: Int, _ action: String) -> String {
            at == 0 ? "\(steps[at].san) \(action)" : "\(first.san), then \(steps[at].san) \(action)"
        }

        let mateTheme = ["mateIn1": 1, "mateIn2": 2, "mateIn3": 3].first { puzzle.themes.contains($0.key) }
        var ideas: [(theme: String, text: String)] = []
        if let mate = mateTheme {
            ideas.append(("mate", mate.value == 1 ? "\(first.san) is checkmate." : "\(first.san) starts a forced checkmate in \(mate.value)."))
        }
        if puzzle.themes.contains("fork"), let fork = yourSteps.first(where: { $0.element.forkTargets.count >= 2 }) {
            let names = fork.element.forkTargets
            ideas.append(("fork", lead(fork.offset, "forks the opponent's \(names[0]) and \(names[1]).")))
        }
        if !puzzle.themes.isDisjoint(with: ["pin", "skewer"]), let pin = yourSteps.first(where: { $0.element.pins }) {
            ideas.append(("pin", lead(pin.offset, "pins an enemy piece to something more valuable.")))
        }
        let finalMaterial = {
            var scratch = Board(position: Position(fen: puzzle.fen) ?? .standard)
            _ = UCIMove.play(setup, on: &scratch)
            for uci in puzzle.moves.dropFirst().prefix(steps.count) { _ = UCIMove.play(uci, on: &scratch) }
            return TacticFinder.material(scratch.position, forWhite: moverIsWhite)
        }()
        let netGain = finalMaterial - startMaterial
        if netGain >= 2, let grab = yourSteps.filter({ $0.element.captured != nil })
            .max(by: { TacticFinder.pieceValue($0.element.captured!.kind) < TacticFinder.pieceValue($1.element.captured!.kind) }) {
            let name = pieceName(grab.element.captured!.kind)
            ideas.append(("capture", lead(grab.offset, "takes the \(name).") + " The line nets about \(netGain) pawns' worth of material."))
        }

        // Prefer the idea that matches the themes this drill asked for.
        let preference: [String: Set<String>] = [
            "mate": ["mateIn1", "mateIn2", "mateIn3", "mate"],
            "fork": ["fork"], "pin": ["pin"],
            "capture": ["hangingPiece", "trappedPiece", "advantage", "crushing"],
        ]
        if let match = ideas.first(where: { !(preference[$0.theme] ?? []).isDisjoint(with: wanted) }) { return match.text }
        return ideas.first?.text
    }
}
