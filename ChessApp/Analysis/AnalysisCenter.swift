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
    /// How many seconds each finished analysis took.
    private(set) var seconds: [String: Double] = [:]
    /// Games waiting to be analysed.
    private(set) var queue: [(key: String, game: LoadedGame, urgent: Bool)] = []
    /// True after the user taps Stop. Only the game being looked at (urgent) is still analysed.
    private(set) var isPaused = false

    // Quick first pass: kept modest so a 40-move game takes well under a minute on an iPhone 14.
    private let quickDepth = 12
    private let quickMilliseconds = 150
    // The first 6 moves each (12 plies) rarely hold mistakes, so they get a lighter look.
    private let openingPlies = 12
    private let openingDepth = 10
    private let openingMilliseconds = 80
    // Suspected mistakes get a deeper second look, so sacrifices aren't wrongly flagged.
    private let deepDepth = 16
    private let deepMilliseconds = 500

    let evaluator = StockfishEvaluator()

    /// Finished analyses are saved here so they survive closing the app and are never redone.
    private static let saveURL: URL = {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "analyses.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.saveURL),
           let saved = try? JSONDecoder().decode([String: GameAnalysis].self, from: data) {
            // Older saved analyses lack Stockfish's best lines, which the leak report now needs.
            // Dropping them makes those games get analysed again.
            results = saved.filter { $0.value.lines != nil }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(results) else { return }
        try? data.write(to: Self.saveURL, options: .atomic)
    }
    private var worker: Task<Void, Never>?

    func analysis(forPGN pgn: String) -> GameAnalysis? { results[pgn] }
    func progress(forPGN pgn: String) -> Double? { progress[pgn] }
    func seconds(forPGN pgn: String) -> Double? { seconds[pgn] }
    func isQueued(pgn: String) -> Bool { queue.contains { $0.key == pgn } }
    var isBusy: Bool { worker != nil }

    /// Adds a game to the queue. `urgent` puts it first (used for the game on screen).
    func request(_ game: LoadedGame, urgent: Bool = false) {
        let key = game.pgn
        guard results[key] == nil, progress[key] == nil else { return }
        queue.removeAll { $0.key == key }
        if urgent { queue.insert((key, game, true), at: 0) } else { queue.append((key, game, false)) }
        startWorkerIfNeeded()
    }

    /// Forgets games that are still waiting (not the one open on screen), for when a new list of games is loaded.
    func clearWaiting() { queue.removeAll { !$0.urgent } }

    /// Stops background analysis. The game being analysed goes back in the queue.
    func pause() { isPaused = true }

    /// Carries on with the waiting games.
    func resume() {
        isPaused = false
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            // While paused, only games the user opened (urgent) are analysed.
            while let index = queue.firstIndex(where: { !isPaused || $0.urgent }) {
                let next = queue.remove(at: index)
                progress[next.key] = 0
                let start = Date()
                if let result = await analyse(next.game, key: next.key, urgent: next.urgent) {
                    results[next.key] = result
                    seconds[next.key] = Date().timeIntervalSince(start)
                    save()
                } else {
                    // Stopped part-way: keep the game at the front of the queue.
                    queue.insert(next, at: 0)
                }
                progress[next.key] = nil
            }
            worker = nil
        }
    }

    private func analyse(_ game: LoadedGame, key: String, urgent: Bool) async -> GameAnalysis? {
        let positions = game.positions
        var evals: [Evaluation] = []
        var bestMoves: [String?] = []
        var lines: [[String]] = []
        await evaluator.newGame()

        // Pass 1: a quick look at every position, from the last move back to the first.
        // Going backwards lets Stockfish reuse what it remembers about the position that comes next,
        // which makes each look faster. The opening gets a lighter look; pass 2 re-checks any suspect.
        var found: [StockfishEvaluator.Result?] = Array(repeating: nil, count: positions.count)
        for (done, index) in positions.indices.reversed().enumerated() {
            if isPaused && !urgent { return nil }
            let isOpening = index < openingPlies
            found[index] = await evaluator.evaluate(positions[index],
                                                    depth: isOpening ? openingDepth : quickDepth,
                                                    maxMilliseconds: isOpening ? openingMilliseconds : quickMilliseconds)
            progress[key] = 0.85 * Double(done + 1) / Double(positions.count)
        }
        for result in found {
            // If Stockfish didn't answer, reuse the score before it so no fake swing appears.
            evals.append(result?.eval ?? evals.last ?? .centipawns(0))
            bestMoves.append(result?.bestMove)
            lines.append(Self.bestLine(result))
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
                if isPaused && !urgent { return nil }
                if let result = await evaluator.evaluate(positions[index], depth: deepDepth, maxMilliseconds: deepMilliseconds) {
                    evals[index] = result.eval
                    bestMoves[index] = result.bestMove
                    lines[index] = Self.bestLine(result)
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
            startsWithWhite: positions.first?.sideToMove != .black,
            lines: lines
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

    /// Stockfish's best line, kept short (6 moves is plenty to see what a tactic wins).
    private static func bestLine(_ result: StockfishEvaluator.Result?) -> [String] {
        guard let result else { return [] }
        if !result.line.isEmpty { return Array(result.line.prefix(6)) }
        return result.bestMove.map { [$0] } ?? []
    }

    /// Turns an engine move like "g1f3" into normal chess notation like "Nf3".
    static func san(for uci: String, in position: Position) -> String? {
        UCIMove.san(for: uci, in: position)
    }
}
