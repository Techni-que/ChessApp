import Foundation

/// An engine score, always from White's point of view.
enum Evaluation: Hashable {
    /// Hundredths of a pawn: +150 means White is 1.5 pawns better.
    case centipawns(Int)
    /// Forced checkmate in this many moves. Positive: White mates. Negative: Black mates.
    case mate(Int)

    /// Score capped at ±5 pawns, used to judge how much a move lost.
    /// Once someone is 5 pawns up the game is decided, so "winning by 8 vs winning by 6"
    /// shouldn't count as a mistake.
    var cappedCentipawns: Int {
        switch self {
        case .centipawns(let cp): max(-500, min(500, cp))
        case .mate(let moves): moves > 0 ? 500 : -500
        }
    }

    /// How full the eval bar is for White, from 0 (Black winning) to 1 (White winning).
    var whiteShare: Double {
        switch self {
        case .centipawns(let cp): 1 / (1 + exp(-0.004 * Double(cp)))
        case .mate(let moves): moves > 0 ? 1 : 0
        }
    }

    /// Short text like "+1.3", "-0.4" or "M3".
    var text: String {
        switch self {
        case .centipawns(let cp):
            let pawns = Double(cp) / 100
            return pawns > 0 ? String(format: "+%.1f", pawns) : String(format: "%.1f", pawns)
        case .mate(let moves):
            return moves > 0 ? "M\(moves)" : "-M\(-moves)"
        }
    }
}

/// How bad a move was, judged by how much evaluation the player who moved gave away.
enum MoveJudgement: String {
    case mistake = "Mistake"
    case blunder = "Blunder"

    /// Lost at least 1 pawn = mistake, at least 2 pawns = blunder.
    static func judge(lossInCentipawns loss: Int) -> MoveJudgement? {
        if loss >= 200 { return .blunder }
        if loss >= 100 { return .mistake }
        return nil
    }

    var symbol: String { self == .blunder ? "??" : "?" }
}

/// The finished analysis of one game. Arrays line up with `LoadedGame.positions`.
struct GameAnalysis {
    /// Score of each position (index 0 = starting position).
    var evals: [Evaluation]
    /// Judgement of the move that led to each position (index 0 is always nil).
    var judgements: [MoveJudgement?]
    /// The move Stockfish preferred instead, shown when a move was a mistake or blunder.
    var betterMoves: [String?]
    /// True if White made the first move (false for games set up with Black to move).
    var startsWithWhite: Bool

    struct Counts: Hashable {
        var mistakes = 0
        var blunders = 0
    }

    /// Number of mistakes and blunders made by one side.
    func counts(forWhite white: Bool) -> Counts {
        var counts = Counts()
        for index in judgements.indices where index > 0 {
            // Move `index` was played by White if it's an odd-numbered move counting from a White start.
            let movedByWhite = (index % 2 == 1) == startsWithWhite
            guard movedByWhite == white, let judgement = judgements[index] else { continue }
            if judgement == .blunder { counts.blunders += 1 } else { counts.mistakes += 1 }
        }
        return counts
    }
}
