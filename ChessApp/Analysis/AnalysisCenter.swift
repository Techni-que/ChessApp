import ChessKit
import Foundation
import Observation

/// Runs Stockfish over whole games, one position at a time, and remembers the results.
///
/// Games wait in a queue. Opening a game moves it to the front, so what you're looking at
/// is analysed first while "Analyse all" keeps working through the rest.
@MainActor
@Observable
final class AnalysisCenter {
    static let shared = AnalysisCenter()

    /// Finished analyses, keyed by the game's PGN text.
    private(set) var results: [String: GameAnalysis] = [:]
    /// Progress (0 to 1) of the game being analysed right now.
    private(set) var progress: [String: Double] = [:]
    /// Games waiting to be analysed.
    private(set) var queue: [(key: String, game: LoadedGame)] = []

    // Quick first pass: kept modest so a 40-move game takes well under a minute on an iPhone 14.
    private let quickDepth = 13
    private let quickMilliseconds = 250
    // Suspected mistakes get a deeper second look, so sacrifices aren't wrongly flagged.
    private let deepDepth = 18
    private let deepMilliseconds = 800

    private let evaluator = StockfishEvaluator()
    private var worker: Task<Void, Never>?

    func analysis(forPGN pgn: String) -> GameAnalysis? { results[pgn] }
    func progress(forPGN pgn: String) -> Double? { progress[pgn] }
    func isQueued(pgn: String) -> Bool { queue.contains { $0.key == pgn } }
    var isBusy: Bool { worker != nil }

    /// Adds a game to the queue. `urgent` puts it first (used for the game on screen).
    func request(_ game: LoadedGame, urgent: Bool = false) {
        let key = game.pgn
        guard results[key] == nil, progress[key] == nil else { return }
        queue.removeAll { $0.key == key }
        if urgent { queue.insert((key, game), at: 0) } else { queue.append((key, game)) }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                progress[next.key] = 0
                results[next.key] = await analyse(next.game, key: next.key)
                progress[next.key] = nil
            }
            worker = nil
        }
    }

    private func analyse(_ game: LoadedGame, key: String) async -> GameAnalysis {
        let positions = game.positions
        var evals: [Evaluation] = []
        var bestMoves: [String?] = []

        // Pass 1: a quick look at every position.
        for (index, position) in positions.enumerated() {
            let result = await evaluator.evaluate(position, depth: quickDepth, maxMilliseconds: quickMilliseconds)
            evals.append(result?.eval ?? evals.last ?? .centipawns(0))
            bestMoves.append(result?.bestMove)
            progress[key] = 0.85 * Double(index + 1) / Double(positions.count)
        }

        // Pass 2: look deeper at both sides of every suspected mistake, then re-judge.
        // Repeats (at most 3 times) in case the deeper scores reveal new suspects.
        var deepened = Set<Int>()
        for _ in 0..<3 {
            let current = Self.judge(evals, positions)
            let suspects = current.indices.filter { current[$0] != nil }
            let toDeepen = Set(suspects.flatMap { [$0 - 1, $0] }).subtracting(deepened).sorted()
            if toDeepen.isEmpty { break }
            for (step, index) in toDeepen.enumerated() {
                if let result = await evaluator.evaluate(positions[index], depth: deepDepth, maxMilliseconds: deepMilliseconds) {
                    evals[index] = result.eval
                    bestMoves[index] = result.bestMove
                }
                deepened.insert(index)
                progress[key] = min(0.99, 0.85 + 0.15 * Double(step + 1) / Double(toDeepen.count))
            }
        }

        let judgements = Self.judge(evals, positions)
        var betterMoves: [String?] = [nil]
        for index in positions.indices.dropFirst() {
            betterMoves.append(judgements[index] == nil ? nil : bestMoves[index - 1].flatMap { Self.san(for: $0, in: positions[index - 1]) })
        }
        return GameAnalysis(
            evals: evals,
            judgements: judgements,
            betterMoves: betterMoves,
            startsWithWhite: positions.first?.sideToMove != .black
        )
    }

    /// Judges every move by how much evaluation the player who moved gave away.
    private static func judge(_ evals: [Evaluation], _ positions: [Position]) -> [MoveJudgement?] {
        var judgements: [MoveJudgement?] = [nil]
        for index in positions.indices.dropFirst() {
            let moverIsWhite = positions[index - 1].sideToMove == .white
            let change = evals[index].cappedCentipawns - evals[index - 1].cappedCentipawns
            judgements.append(MoveJudgement.judge(lossInCentipawns: moverIsWhite ? -change : change))
        }
        return judgements
    }

    /// Turns an engine move like "g1f3" into normal chess notation like "Nf3".
    private static func san(for uci: String, in position: Position) -> String? {
        guard uci.count >= 4 else { return nil }
        let start = Square(String(uci.prefix(2)))
        let end = Square(String(uci.dropFirst(2).prefix(2)))
        var board = Board(position: position)
        guard var move = board.move(pieceAt: start, to: end) else { return nil }
        if uci.count == 5, let kind = Piece.Kind(rawValue: uci.suffix(1).uppercased()) {
            move = board.completePromotion(of: move, to: kind)
        }
        return move.san
    }
}
