import ChessKit
import Foundation

/// One analysed game, ready for leak hunting.
struct AnalysedGame {
    let summary: GameSummary
    let game: LoadedGame
    let analysis: GameAnalysis
}

/// The four groups the report is organised into. Opening and endgame will join later.
enum LeakGroup: String, CaseIterable, Hashable {
    case tactics, advantage, timeManagement, strategy

    var title: String {
        switch self {
        case .tactics: "Tactics"
        case .advantage: "Advantage capitalisation"
        case .timeManagement: "Time management"
        case .strategy: "Strategy"
        }
    }

    /// A short name that fits in the navigation bar.
    var shortTitle: String {
        switch self {
        case .tactics: "Tactics"
        case .advantage: "Advantage"
        case .timeManagement: "Time management"
        case .strategy: "Strategy"
        }
    }

    var symbol: String {
        switch self {
        case .tactics: "bolt.fill"
        case .advantage: "flag.fill"
        case .timeManagement: "clock.fill"
        case .strategy: "map.fill"
        }
    }

    /// What this group means and why it costs points.
    var explanation: String {
        switch self {
        case .tactics:
            "A winning shot was on the board, or you left something to be taken: hanging pieces, forks, pins, checkmates and more. Before each move, check every capture, check and threat for both sides."
        case .advantage:
            "You were clearly winning (about 2 pawns ahead or more) but didn't win the game. When ahead, trade pieces, keep things simple and avoid giving counterplay."
        case .timeManagement:
            "Your clock is costing you moves: either you were short of time when it got sharp, or you moved too fast with plenty of time left. Spend your time where the position is tense."
        case .strategy:
            "No single blunder, but small slips in quiet middlegame positions slowly gave away your advantage. Have a plan for each move rather than just reacting."
        }
    }

    /// Lichess puzzle themes used as extra practice for the groups that aren't about tactics.
    var puzzleThemes: Set<String> {
        switch self {
        case .tactics: TacticType.other.themes
        case .advantage: ["advantage", "crushing", "endgame"]
        case .timeManagement: ["short", "oneMove"]
        case .strategy: ["quietMove", "defensiveMove"]
        }
    }
}

/// The specific habits inside the groups.
enum LeakKind: String, CaseIterable {
    case hangingPieces, missedTactics, notConverting, middlegameDrift, timeTrouble, notPunishing, rushedMoves

    var group: LeakGroup {
        switch self {
        case .hangingPieces, .missedTactics, .notPunishing: .tactics
        case .notConverting: .advantage
        case .timeTrouble, .rushedMoves: .timeManagement
        case .middlegameDrift: .strategy
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

/// One of the player's own mistakes, ready to be turned into a drill question.
struct DrillSpot {
    let game: LoadedGame
    /// The move that was the mistake (the position before it is what the drill shows).
    let ply: Int
    let gameLabel: String
    let playedMove: String
    /// The move Stockfish preferred, in normal notation.
    let betterMove: String
    /// Evaluation just before the move, from the player's side (hundredths of a pawn, capped at 5 pawns).
    let evalBefore: Int
    let playerIsWhite: Bool
    /// True when the right answer is a forced checkmate, so only a mating move counts.
    var requiresMate = false
    /// Stockfish's better move as an engine move like "g1f3" (nil if we don't have it).
    var betterUCI: String?
    /// Stockfish's best line from the position before the mistake (engine moves, up to 4).
    var bestLine: [String] = []
    /// Stockfish's best reply after the move that was played in the game (engine moves, up to 3).
    var playedLine: [String] = []
    var tactic: TacticType?
    /// Moves to mate, for missed-checkmate spots.
    var mateIn: Int?
    /// How much the move played lost, in hundredths of a pawn.
    var loss = 0
    /// Seconds on the player's clock before the move (only for games that have clock times).
    var clockBefore: Double?
    /// Which specific habit this question comes from.
    var habit: LeakKind = .missedTactics
    /// True when the opponent's move just before this one was a big mistake.
    var afterOpponentMistake = false
    /// True for a position where the opponent's last move gave nothing away (the answer is "nothing to punish").
    var isDecoy = false
}

/// One card in the report: a group, with the specific habits inside it.
struct Leak: Identifiable, Hashable {
    static func == (lhs: Leak, rhs: Leak) -> Bool { lhs.group == rhs.group }
    func hash(into hasher: inout Hasher) { hasher.combine(group) }

    var id: LeakGroup { group }
    let group: LeakGroup
    var title: String { group.title }
    let gamesAffected: Int
    let gamesChecked: Int
    /// Total evaluation given away by this group, in hundredths of a pawn.
    let totalCost: Int
    let examples: [LeakExample]
    /// The player's own mistakes in this group (all habits mixed), used by the drills.
    var spots: [DrillSpot] = []
    /// Positions where the opponent's last move gave nothing away (Tactics only).
    var decoys: [DrillSpot] = []
    /// The habits and how often each happened, e.g. "hanging pieces (5), missed forks (3)".
    var habits = ""
    /// How many of the Tactics events came right after an opponent mistake.
    var afterOpponentMistake = 0
    /// How many Tactics events of each kind, used to choose puzzle patterns.
    var tacticCounts: [TacticType: Int] = [:]

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
    /// The player's rating, averaged from the games (1400 if the games don't say).
    var playerRating = 1400
    /// Which time control the report covers (for wording like "your last 20 blitz games").
    var speed: TimeControl?
    /// Positions where you were clearly better after your opponent's mistake and gave it back without a tactic.
    /// Kept for the future "play on against Stockfish" drill; not shown yet.
    var advantageSeeds: [DrillSpot] = []
}

/// Looks through analysed games for the mistakes this player repeats.
/// Only the player's own moves count, never the opponent's.
///
/// Every number below is a first guess and is listed in CLAUDE.md so it can be tuned.
enum LeakDetector {
    /// Games needed before the report appears.
    static let minimumGames = 10

    /// A missed checkmate counts as costing at least this much (hundredths of a pawn),
    /// because the 5-pawn cap hides how much a mate is really worth.
    private static let missedMateCost = 300

    private enum Phase: String {
        case opening = "the opening", middlegame = "the middlegame", endgame = "the endgame"
    }

    /// One time the player did something this leak is about.
    private struct Event {
        let gameIndex: Int
        let ply: Int
        let cost: Int
        /// What to say under the example. If nil we say "Better was X".
        var detail: String?
        var phase: Phase?
        var tactic: TacticType?
        var requiresMate = false
        var mateIn: Int?
        /// Seconds on the player's clock before the move, when the game has clock times.
        var clockBefore: Double?
        var habit: LeakKind = .missedTactics
        var afterOpponentMistake = false
        var isDecoy = false
    }

    static func report(for games: [AnalysedGame]) -> LeakReport {
        var hangs: [Event] = [], tactics: [Event] = [], timeErrors: [Event] = []
        var notPunishing: [Event] = [], rushed: [Event] = []
        var converts: [Event] = [], drifts: [Event] = []
        var decoyCandidates: [Event] = []
        var gamesWithClocks = 0

        /// Stockfish's better move for the player's move at `ply`, in normal notation.
        func betterMove(_ gameIndex: Int, _ ply: Int) -> String? {
            let item = games[gameIndex]
            if let better = item.analysis.betterMoves[ply] { return UCIMove.display(better) }
            guard let uci = item.analysis.lines?[safe: ply - 1]?.first else { return nil }
            return UCIMove.san(for: uci, in: item.game.positions[ply - 1])
        }

        for (gameIndex, item) in games.enumerated() {
            let isWhite = item.summary.playedWhite
            let analysis = item.analysis
            let positions = item.game.positions
            let count = min(positions.count, analysis.evals.count)
            guard count > 2 else { continue }

            /// Evaluation from the player's point of view (positive = good for them), capped at 5 pawns.
            func mine(_ ply: Int) -> Int {
                let value = analysis.evals[ply].cappedCentipawns
                return isWhite ? value : -value
            }
            func playerMoved(_ ply: Int) -> Bool {
                let whiteMoved = (ply % 2 == 1) == analysis.startsWithWhite
                return whiteMoved == isWhite
            }
            func loss(_ ply: Int) -> Int { max(0, mine(ply - 1) - mine(ply)) }
            /// Moves until the player mates, if Stockfish sees a forced mate here (uncapped score).
            func mateForPlayer(_ ply: Int) -> Int? {
                guard case .mate(let moves) = analysis.evals[ply], isWhite ? moves > 0 : moves < 0 else { return nil }
                return abs(moves)
            }
            /// True if the opponent's move just before `ply` gave away 2+ pawns.
            func afterOpponentBlunder(_ ply: Int) -> Bool {
                ply >= 2 && !playerMoved(ply - 1) && mine(ply - 1) - mine(ply - 2) >= 200
            }

            let clocks = clockSeconds(in: item.game.pgn)
            let settings = timeSettings(of: item.game)
            // Daily games have days per move, so clock-based leaks don't apply.
            let hasClocks = clocks.count >= 10 && settings != nil && item.summary.speed != .daily
            if hasClocks { gamesWithClocks += 1 }

            for ply in 1..<count where playerMoved(ply) {
                let afterBlunder = afterOpponentBlunder(ply)
                // Missed checkmate: Stockfish had a forced mate in 1 to 3 and the move played gave it up.
                // This uses the real mate score, so it's caught even when you were already winning.
                var missedMate = false
                if let moves = mateForPlayer(ply - 1), moves <= 3, mateForPlayer(ply) == nil,
                   let first = analysis.lines?[safe: ply - 1]?.first {
                    missedMate = true
                    let better = UCIMove.san(for: first, in: positions[ply - 1]) ?? first
                    tactics.append(Event(gameIndex: gameIndex, ply: ply, cost: max(loss(ply), missedMateCost),
                                         detail: "You missed checkmate in \(moves). Better was \(better)", tactic: .checkmate,
                                         requiresMate: true, mateIn: moves, habit: .missedTactics, afterOpponentMistake: afterBlunder))
                }

                guard let judgement = analysis.judgements[ply] else { continue }
                let lost = loss(ply)

                if !missedMate {
                    // Did the player end up down material? Check after the opponent's reply too.
                    let before = TacticFinder.material(positions[ply - 1], forWhite: isWhite)
                    var after = TacticFinder.material(positions[ply], forWhite: isWhite)
                    if ply + 1 < count { after = min(after, TacticFinder.material(positions[ply + 1], forWhite: isWhite)) }
                    if judgement == .blunder && before - after >= 2 {
                        hangs.append(Event(gameIndex: gameIndex, ply: ply, cost: lost, phase: phase(of: ply, in: positions),
                                           tactic: .hanging, habit: .hangingPieces, afterOpponentMistake: afterBlunder))
                    } else if lost >= 150, let line = analysis.lines?[safe: ply - 1], let first = line.first,
                              TacticFinder.materialGain(from: positions[ply - 1], line: line, forWhite: isWhite) >= 2 {
                        // Stockfish's best line wins material whatever the first move is, and you didn't play it.
                        let type = TacticFinder.classify(firstMove: first, from: positions[ply - 1])
                        let better = UCIMove.san(for: first, in: positions[ply - 1]) ?? first
                        let what: String
                        switch type {
                        case .fork: what = "a fork"
                        case .pin: what = "a pin"
                        case .skewer: what = "a skewer"
                        case .discovery: what = "a discovered attack"
                        case .sacrifice: what = "a sacrifice"
                        default: what = "a winning tactic"
                        }
                        tactics.append(Event(gameIndex: gameIndex, ply: ply, cost: lost,
                                             detail: "You missed \(what). Better was \(better)", tactic: type,
                                             habit: .missedTactics, afterOpponentMistake: afterBlunder))
                    }
                }

                if hasClocks, let settings {
                    // The clock after this move is clocks[ply - 1]; before it, it was the player's
                    // previous reading (two moves back) or the starting time.
                    if ply - 1 < clocks.count, ply < 3 || ply - 3 < clocks.count {
                        let after = clocks[ply - 1]
                        let before = ply >= 3 ? clocks[ply - 3] : settings.base
                        if after < max(8, settings.base * 0.12) {
                            timeErrors.append(Event(gameIndex: gameIndex, ply: ply, cost: lost, clockBefore: before, habit: .timeTrouble))
                        }
                        // Rushed: a mistake played in under 2.5 seconds with more than 30% of the clock left.
                        let spent = before + settings.increment - after
                        if spent >= 0, spent < 2.5, before > settings.base * 0.3 {
                            let left = Int((before / settings.base * 100).rounded())
                            let better = betterMove(gameIndex, ply).map { " Better was \($0)" } ?? ""
                            rushed.append(Event(gameIndex: gameIndex, ply: ply, cost: lost,
                                                detail: String(format: "Played in %.1f s with %d%% of your clock left.", spent, left) + better,
                                                clockBefore: before, habit: .rushedMoves))
                        }
                    }
                }
            }

            // Not punishing: the opponent's move dropped 2+ pawns, and your reply gave back more than half of it.
            for opponentPly in 1..<(count - 1) where !playerMoved(opponentPly) {
                let gain = mine(opponentPly) - mine(opponentPly - 1)
                let replyPly = opponentPly + 1
                let given = loss(replyPly)
                if gain >= 200, given >= 100, Double(given) > 0.5 * Double(gain) {
                    let better = betterMove(gameIndex, replyPly).map { " Better was \($0)" } ?? ""
                    notPunishing.append(Event(gameIndex: gameIndex, ply: replyPly, cost: given,
                                              detail: String(format: "Your opponent gave away about %.1f pawns, but your reply lost %.1f.", Double(gain) / 100, Double(given) / 100) + better,
                                              tactic: .other, habit: .notPunishing, afterOpponentMistake: true))
                }
            }

            // Positions where the opponent's last move gave nothing away, and the player played fine.
            // These are the "nothing to punish" questions that keep the "What did they just leave?" drill honest.
            if count > 20 {
                for opponentPly in 8..<(count - 1) where !playerMoved(opponentPly) {
                    let replyPly = opponentPly + 1
                    guard playerMoved(replyPly),
                          mine(opponentPly) - mine(opponentPly - 1) <= 30,
                          abs(mine(opponentPly)) <= 300,
                          loss(replyPly) <= 30,
                          let line = analysis.lines?[safe: opponentPly], !line.isEmpty,
                          TacticFinder.materialGain(from: positions[opponentPly], line: line, forWhite: isWhite) < 1
                    else { continue }
                    decoyCandidates.append(Event(gameIndex: gameIndex, ply: replyPly, cost: 0, habit: .notPunishing, isDecoy: true))
                }
            }

            // Failing to convert: clearly winning at some point, but didn't win.
            // The moment we show is the player's biggest slip from a position where they were
            // about 2 pawns up or better. If there was no real slip from such a position, we skip the game.
            if item.summary.outcome != .win {
                var peak = 0
                for ply in 0..<count { peak = max(peak, mine(ply)) }
                var shown: Int?
                var biggest = 0
                for ply in 1..<count where playerMoved(ply) && mine(ply - 1) >= 200 && loss(ply) > biggest {
                    biggest = loss(ply)
                    shown = ply
                }
                if peak >= 200, let shown, biggest >= 50 {
                    converts.append(Event(gameIndex: gameIndex, ply: shown, cost: min(peak, 500),
                                          detail: String(format: "You were +%.1f here and this move lost %.1f", Double(mine(shown - 1)) / 100, Double(biggest) / 100),
                                          habit: .notConverting))
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
                    drifts.append(Event(gameIndex: gameIndex, ply: worst, cost: net,
                                        detail: String(format: "Your position slipped by about %.1f pawns over moves 15 to 30", Double(net) / 100),
                                        habit: .middlegameDrift))
                }
            }
        }

        // MARK: Turning events into cards

        func playerMoved(_ gameIndex: Int, _ ply: Int) -> Bool {
            let item = games[gameIndex]
            let whiteMoved = (ply % 2 == 1) == item.analysis.startsWithWhite
            return whiteMoved == item.summary.playedWhite
        }

        /// A drill question needs a move the player actually made, and a better move to find.
        func spot(_ event: Event) -> DrillSpot? {
            let item = games[event.gameIndex]
            guard playerMoved(event.gameIndex, event.ply), event.ply < item.game.moveNames.count,
                  let better = betterMove(event.gameIndex, event.ply) else { return nil }
            let isWhite = item.summary.playedWhite
            let value = item.analysis.evals[event.ply - 1].cappedCentipawns
            // The move text without its number, e.g. "27... Qd4" becomes "Qd4".
            let played = item.game.moveNames[event.ply].split(separator: " ").last.map(String.init) ?? ""
            func mineAt(_ ply: Int) -> Int {
                let value = item.analysis.evals[ply].cappedCentipawns
                return isWhite ? value : -value
            }
            let lines = item.analysis.lines
            let before = lines?[safe: event.ply - 1] ?? []
            return DrillSpot(game: item.game, ply: event.ply, gameLabel: label(item.summary), playedMove: played,
                             betterMove: better, evalBefore: isWhite ? value : -value, playerIsWhite: isWhite,
                             requiresMate: event.requiresMate, betterUCI: before.first,
                             bestLine: Array(before.prefix(4)),
                             playedLine: Array((lines?[safe: event.ply] ?? []).prefix(3)),
                             tactic: event.tactic, mateIn: event.mateIn,
                             loss: max(0, mineAt(event.ply - 1) - mineAt(event.ply)),
                             clockBefore: event.clockBefore, habit: event.habit,
                             afterOpponentMistake: event.afterOpponentMistake, isDecoy: event.isDecoy)
        }

        func example(_ event: Event) -> LeakExample {
            let item = games[event.gameIndex]
            let detail = event.detail ?? betterMove(event.gameIndex, event.ply).map { "Better was \($0)" } ?? "This move lost ground"
            return LeakExample(game: item.game, ply: event.ply, gameLabel: label(item.summary),
                               moveText: item.game.moveNames[event.ply], detail: detail, cost: event.cost)
        }

        // One move, one habit. Order of priority: hanging pieces, then missed tactics with a named type,
        // then "not punishing", then missed tactics labelled "other".
        func key(_ event: Event) -> String { "\(event.gameIndex)-\(event.ply)" }
        var claimed = Set(hangs.map(key))
        let namedTactics = tactics.filter { ($0.tactic ?? .other) != .other }
        claimed.formUnion(namedTactics.map(key))
        notPunishing = notPunishing.filter { !claimed.contains(key($0)) }
        claimed.formUnion(notPunishing.map(key))
        tactics = tactics.filter { ($0.tactic ?? .other) != .other || !claimed.contains(key($0)) }

        // "Not punishing" moves that no tactic explains. If Stockfish's best line wins material, it is a tactic
        // (kept in Tactics). If you were clearly better (+1.5 or more) and just gave it back, it belongs to
        // Advantage capitalisation and is saved as a future "play on against Stockfish" start position.
        var advantageSeeds: [DrillSpot] = []
        var tacticalNotPunishing: [Event] = []
        for event in notPunishing {
            let item = games[event.gameIndex]
            let isWhite = item.summary.playedWhite
            let line = item.analysis.lines?[safe: event.ply - 1] ?? []
            let wins = !line.isEmpty
                && TacticFinder.materialGain(from: item.game.positions[event.ply - 1], line: line, forWhite: isWhite) >= 1
            let value = item.analysis.evals[event.ply - 1].cappedCentipawns
            let lead = isWhite ? value : -value
            if wins {
                tacticalNotPunishing.append(event)
            } else if lead >= 150 {
                if let seed = spot(event) { advantageSeeds.append(seed) }
            }
        }

        var leaks: [Leak] = []
        func add(_ group: LeakGroup, events: [Event], checked: Int, spotLimit: Int = 8) {
            guard !events.isEmpty else { return }
            // Best examples: the costliest, one per game.
            var seen = Set<Int>()
            let sorted = events.sorted { $0.cost > $1.cost }
            let top = sorted.filter { seen.insert($0.gameIndex).inserted }.prefix(3)
            var leak = Leak(group: group, gamesAffected: Set(events.map(\.gameIndex)).count, gamesChecked: checked,
                            totalCost: events.reduce(0) { $0 + $1.cost }, examples: top.map(example),
                            spots: Array(sorted.compactMap(spot).prefix(spotLimit)))

            // The specific habits inside the group, with counts.
            switch group {
            case .tactics:
                var counts: [TacticType: Int] = [:]
                for event in events { counts[event.tactic ?? .other, default: 0] += 1 }
                leak.tacticCounts = counts
                leak.habits = counts.sorted { $0.value > $1.value }.map { $0.key.habitLabel(count: $0.value) }.joined(separator: ", ")
                leak.afterOpponentMistake = events.filter(\.afterOpponentMistake).count
                leak.decoys = Array(decoyCandidates.shuffled().prefix(8).compactMap(spot))
            case .advantage:
                leak.habits = "failing to convert a winning position (\(events.count))"
            case .timeManagement:
                let low = events.filter { $0.habit == .timeTrouble }.count
                let fast = events.filter { $0.habit == .rushedMoves }.count
                leak.habits = [low > 0 ? "mistakes when low on time (\(low))" : nil, fast > 0 ? "rushed moves (\(fast))" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
            case .strategy:
                leak.habits = "slow drift in the middlegame (\(events.count))"
            }
            leaks.append(leak)
        }

        // Tactics: hanging pieces and missed tactics, plus the "after your opponent's mistake" moves that are tactics.
        add(.tactics, events: hangs + tactics + tacticalNotPunishing, checked: games.count, spotLimit: 16)
        add(.advantage, events: converts, checked: games.count)
        add(.strategy, events: drifts, checked: games.count)
        // Skipped silently if no game came with clock times.
        if gamesWithClocks > 0 {
            add(.timeManagement, events: timeErrors + rushed, checked: gamesWithClocks)
        }

        // Only keep groups that repeat, then rank by how much they cost in total.
        let recurring = leaks.filter { $0.gamesAffected >= 2 }
        let ranked = recurring.sorted { $0.totalCost > $1.totalCost }
        return LeakReport(leaks: Array(ranked.prefix(3)), gamesAnalysed: games.count, playerRating: rating(of: games),
                          speed: games.first?.summary.speed, advantageSeeds: advantageSeeds)
    }

    // MARK: - Helpers

    /// The player's average rating, from the Elo tags in their games.
    private static func rating(of games: [AnalysedGame]) -> Int {
        let ratings = games.compactMap { item -> Int? in
            Int(item.game.tags[item.summary.playedWhite ? "WhiteElo" : "BlackElo"] ?? "")
        }
        guard !ratings.isEmpty else { return 1400 }
        return ratings.reduce(0, +) / ratings.count
    }

    private static func label(_ summary: GameSummary) -> String {
        "\(summary.outcome.rawValue) vs \(summary.opponent), \(summary.date.formatted(date: .abbreviated, time: .omitted))"
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

    /// Starting time and increment per move, from the "TimeControl" tag like "180+2" or "600".
    private static func timeSettings(of game: LoadedGame) -> (base: Double, increment: Double)? {
        guard let text = game.tags["TimeControl"] else { return nil }
        let parts = text.split(separator: "+")
        guard let first = parts.first, let base = Double(first), base > 0 else { return nil }
        let increment = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        return (base, increment)
    }
}

private extension Array {
    /// The element at `index`, or nil if it's out of range.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
