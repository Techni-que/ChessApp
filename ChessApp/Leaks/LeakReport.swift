import ChessKit
import Foundation

/// One analysed game, ready for leak hunting.
struct AnalysedGame {
    let summary: GameSummary
    let game: LoadedGame
    let analysis: GameAnalysis
}

/// The kinds of recurring mistake the report looks for.
enum LeakKind: String, CaseIterable {
    case hangingPieces, missedTactics, notConverting, middlegameDrift, timeTrouble

    var title: String {
        switch self {
        case .hangingPieces: "Leaving pieces hanging"
        case .missedTactics: "Missing winning tactics"
        case .notConverting: "Not finishing off winning positions"
        case .middlegameDrift: "Slowly drifting in the middlegame"
        case .timeTrouble: "Mistakes when low on time"
        }
    }

    var symbol: String {
        switch self {
        case .hangingPieces: "exclamationmark.triangle.fill"
        case .missedTactics: "eye.slash.fill"
        case .notConverting: "flag.slash.fill"
        case .middlegameDrift: "arrow.down.right"
        case .timeTrouble: "clock.badge.exclamationmark.fill"
        }
    }

    /// What it means and why it costs points, in one friendly line.
    var explanation: String {
        switch self {
        case .hangingPieces:
            "Your move let your opponent win a piece or pawn for free. These are the quickest way to lose a game, so check what each piece protects before you move."
        case .missedTactics:
            "A capture or check that won material was available, but you played something else. Before each move, look at every capture and check for both sides."
        case .notConverting:
            "You were clearly winning (about 2 pawns ahead or more) but didn't win the game. When ahead, trade pieces, keep things simple and avoid giving counterplay."
        case .middlegameDrift:
            "No single blunder, but small slips between moves 15 and 30 slowly gave away your advantage. Have a plan for each move rather than just reacting."
        case .timeTrouble:
            "Many of your errors came when your clock was nearly out. Spend less time on the early moves so you have time to think when the game gets sharp."
        }
    }
}

/// A position from one of the user's games that shows a leak.
struct LeakExample: Identifiable {
    let id = UUID()
    let game: LoadedGame
    /// Which position to open on (the one after the move being discussed).
    let ply: Int
    let gameLabel: String
    let moveText: String
    /// For example "Best was Qb4+" or "You were +3.2 here".
    let detail: String
    /// How much it cost, in hundredths of a pawn (used to pick the best examples).
    let cost: Int
}

/// One card in the report.
struct Leak: Identifiable {
    var id: LeakKind { kind }
    let kind: LeakKind
    /// Title, adjusted when one game phase dominates (e.g. "...in the middlegame").
    let title: String
    let gamesAffected: Int
    let gamesChecked: Int
    /// Total evaluation given away by this leak, in hundredths of a pawn.
    let totalCost: Int
    let examples: [LeakExample]

    /// Average cost in pawns per game where it happened, e.g. "3.4".
    var pawnsPerGame: String {
        String(format: "%.1f", Double(totalCost) / 100 / Double(max(gamesAffected, 1)))
    }
}

/// The finished report.
struct LeakReport: Identifiable {
    let id = UUID()
    let leaks: [Leak]
    let gamesAnalysed: Int
}

/// Looks through analysed games for the mistakes this player repeats.
/// Only the player's own moves count, never the opponent's.
enum LeakDetector {
    /// Games needed before the report appears.
    static let minimumGames = 10

    private enum Phase: String {
        case opening = "the opening", middlegame = "the middlegame", endgame = "the endgame"
    }

    /// A move by the player that lost evaluation.
    private struct Slip {
        let gameIndex: Int
        let ply: Int
        let loss: Int
        let phase: Phase
        let hung: Bool
        let judgement: MoveJudgement
    }

    static func report(for games: [AnalysedGame]) -> LeakReport {
        var hangs: [Slip] = [], tactics: [Slip] = [], timeErrors: [Slip] = []
        var convertExamples: [(game: Int, ply: Int, cost: Int, peak: Int)] = []
        var driftExamples: [(game: Int, ply: Int, cost: Int)] = []
        var gamesWithClocks = 0

        for (gameIndex, item) in games.enumerated() {
            let isWhite = item.summary.playedWhite
            let analysis = item.analysis
            let positions = item.game.positions
            let count = min(positions.count, analysis.evals.count)
            guard count > 2 else { continue }

            /// Evaluation from the player's point of view (positive = good for them).
            func mine(_ ply: Int) -> Int {
                let value = analysis.evals[ply].cappedCentipawns
                return isWhite ? value : -value
            }
            func playerMoved(_ ply: Int) -> Bool {
                let whiteMoved = (ply % 2 == 1) == analysis.startsWithWhite
                return whiteMoved == isWhite
            }
            func loss(_ ply: Int) -> Int { max(0, mine(ply - 1) - mine(ply)) }

            let clocks = clockSeconds(in: item.game.pgn)
            let baseSeconds = baseTime(of: item.game)
            let hasClocks = clocks.count >= 10 && baseSeconds != nil
            if hasClocks { gamesWithClocks += 1 }

            // Mistakes and blunders by the player.
            for ply in 1..<count where playerMoved(ply) {
                guard let judgement = analysis.judgements[ply] else { continue }
                let lost = loss(ply)
                // Did the player end up down material? Check after the opponent's reply too.
                let before = material(positions[ply - 1], forWhite: isWhite)
                var after = material(positions[ply], forWhite: isWhite)
                if ply + 1 < count { after = min(after, material(positions[ply + 1], forWhite: isWhite)) }
                let hung = judgement == .blunder && before - after >= 2
                let error = Slip(gameIndex: gameIndex, ply: ply, loss: lost, phase: phase(of: ply, in: positions), hung: hung, judgement: judgement)

                if hung {
                    hangs.append(error)
                } else if lost >= 150, let better = analysis.betterMoves[ply],
                          better.contains("x") || better.contains("+") || better.contains("#") {
                    tactics.append(error)
                }
                if hasClocks, let base = baseSeconds, ply - 1 < clocks.count,
                   clocks[ply - 1] < max(8, base * 0.12) {
                    timeErrors.append(error)
                }
            }

            // Failing to convert: clearly winning at some point, but didn't win.
            if item.summary.outcome != .win {
                var peakPly = 0
                for ply in 1..<count where mine(ply) > mine(peakPly) { peakPly = ply }
                let peak = mine(peakPly)
                if peak >= 200 {
                    // Show the player's biggest slip after the peak, else the peak itself.
                    var shown = peakPly
                    var biggest = 0
                    for ply in peakPly + 1..<count where playerMoved(ply) && loss(ply) > biggest {
                        biggest = loss(ply)
                        shown = ply
                    }
                    convertExamples.append((gameIndex, shown, min(peak, 500), peak))
                }
            }

            // Middlegame drift: moves 15 to 30, many small losses, no single mistake.
            let startPly = 2 * 15 - (analysis.startsWithWhite ? 1 : 0)
            let endPly = min(2 * 30, count - 1)
            if endPly - startPly >= 16, mine(startPly - 1) > -300 {
                let myMoves = (startPly...endPly).filter { playerMoved($0) }
                let hasMistake = myMoves.contains { analysis.judgements[$0] != nil }
                let sum = myMoves.reduce(0) { $0 + loss($1) }
                let net = mine(startPly - 1) - mine(endPly)
                if !hasMistake, sum >= 100, net >= 150, let worst = myMoves.max(by: { loss($0) < loss($1) }) {
                    driftExamples.append((gameIndex, worst, net))
                }
            }
        }

        var leaks: [Leak] = []

        func example(_ error: Slip) -> LeakExample {
            let item = games[error.gameIndex]
            let better = item.analysis.betterMoves[error.ply]
            return LeakExample(
                game: item.game,
                ply: error.ply,
                gameLabel: label(item.summary),
                moveText: item.game.moveNames[error.ply],
                detail: better.map { "Better was \($0)" } ?? "This move lost ground",
                cost: error.loss
            )
        }
        func make(_ kind: LeakKind, title: String? = nil, errors: [Slip], checked: Int) {
            guard !errors.isEmpty else { return }
            let gameSet = Set(errors.map(\.gameIndex))
            // Best examples: the costliest, one per game.
            var seen = Set<Int>()
            let top = errors.sorted { $0.loss > $1.loss }.filter { seen.insert($0.gameIndex).inserted }.prefix(3)
            leaks.append(Leak(kind: kind, title: title ?? kind.title, gamesAffected: gameSet.count, gamesChecked: checked,
                              totalCost: errors.reduce(0) { $0 + $1.loss }, examples: top.map(example)))
        }

        // Hanging pieces: name the game phase where most of the damage happens.
        if !hangs.isEmpty {
            var byPhase: [Phase: Int] = [:]
            for error in hangs { byPhase[error.phase, default: 0] += error.loss }
            let worst = byPhase.max { $0.value < $1.value }?.key
            make(.hangingPieces, title: worst.map { "Leaving pieces hanging, mostly in \($0.rawValue)" }, errors: hangs, checked: games.count)
        }
        make(.missedTactics, errors: tactics, checked: games.count)

        if !convertExamples.isEmpty {
            let examples = convertExamples.sorted { $0.cost > $1.cost }.prefix(3).map { entry -> LeakExample in
                let item = games[entry.game]
                return LeakExample(game: item.game, ply: entry.ply, gameLabel: label(item.summary),
                                   moveText: item.game.moveNames[entry.ply],
                                   detail: String(format: "You were up about %.1f pawns in this game", Double(entry.peak) / 100),
                                   cost: entry.cost)
            }
            leaks.append(Leak(kind: .notConverting, title: LeakKind.notConverting.title, gamesAffected: convertExamples.count,
                              gamesChecked: games.count, totalCost: convertExamples.reduce(0) { $0 + $1.cost }, examples: Array(examples)))
        }

        if !driftExamples.isEmpty {
            let examples = driftExamples.sorted { $0.cost > $1.cost }.prefix(3).map { entry -> LeakExample in
                let item = games[entry.game]
                return LeakExample(game: item.game, ply: entry.ply, gameLabel: label(item.summary),
                                   moveText: item.game.moveNames[entry.ply],
                                   detail: String(format: "Your position slipped by about %.1f pawns over moves 15 to 30", Double(entry.cost) / 100),
                                   cost: entry.cost)
            }
            leaks.append(Leak(kind: .middlegameDrift, title: LeakKind.middlegameDrift.title, gamesAffected: driftExamples.count,
                              gamesChecked: games.count, totalCost: driftExamples.reduce(0) { $0 + $1.cost }, examples: Array(examples)))
        }

        // Skipped silently if no game came with clock times.
        if gamesWithClocks > 0 {
            make(.timeTrouble, errors: timeErrors, checked: gamesWithClocks)
        }

        // Only keep leaks that repeat, then rank by how much they cost in total.
        let recurring = leaks.filter { $0.gamesAffected >= 2 }
        let ranked = recurring.sorted { $0.totalCost > $1.totalCost }
        return LeakReport(leaks: Array(ranked.prefix(3)), gamesAnalysed: games.count)
    }

    // MARK: - Helpers

    private static func label(_ summary: GameSummary) -> String {
        "\(summary.outcome.rawValue) vs \(summary.opponent), \(summary.date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Material (pawn = 1, knight/bishop = 3, rook = 5, queen = 9) for the player minus the opponent.
    private static func material(_ position: Position, forWhite: Bool) -> Int {
        var total = 0
        for piece in position.pieces {
            let value: Int
            switch piece.kind {
            case .pawn: value = 1
            case .knight, .bishop: value = 3
            case .rook: value = 5
            case .queen: value = 9
            case .king: value = 0
            }
            total += (piece.color == .white) == forWhite ? value : -value
        }
        return total
    }

    private static func phase(of ply: Int, in positions: [Position]) -> Phase {
        if (ply + 1) / 2 <= 10 { return .opening }
        var heavy = 0
        for piece in positions[ply].pieces {
            switch piece.kind {
            case .knight, .bishop: heavy += 3
            case .rook: heavy += 5
            case .queen: heavy += 9
            default: break
            }
        }
        return heavy <= 14 ? .endgame : .middlegame
    }

    /// Clock readings in seconds, one per half-move, from comments like "{[%clk 0:02:59.9]}".
    static func clockSeconds(in pgn: String) -> [Double] {
        var result: [Double] = []
        let scanner = pgn as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\[%clk (\d+):(\d+):(\d+(?:\.\d+)?)\]"#) else { return [] }
        for match in regex.matches(in: pgn, range: NSRange(location: 0, length: scanner.length)) {
            let hours = Double(scanner.substring(with: match.range(at: 1))) ?? 0
            let minutes = Double(scanner.substring(with: match.range(at: 2))) ?? 0
            let seconds = Double(scanner.substring(with: match.range(at: 3))) ?? 0
            result.append(hours * 3600 + minutes * 60 + seconds)
        }
        return result
    }

    /// Starting time on each clock, from the "TimeControl" tag like "180+2" or "600".
    private static func baseTime(of game: LoadedGame) -> Double? {
        guard let text = game.tags["TimeControl"],
              let first = text.split(separator: "+").first,
              let seconds = Double(first), seconds > 0 else { return nil }
        return seconds
    }
}
