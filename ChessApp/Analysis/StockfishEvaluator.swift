import ChessKit
import ChessKitEngine
import Foundation

/// Talks to the Stockfish chess engine that runs inside the app (no internet needed).
///
/// Only one position is analysed at a time; `AnalysisCenter` makes sure of that.
actor StockfishEvaluator {
    /// What Stockfish thinks of one position.
    struct Result {
        /// Score from White's point of view.
        var eval: Evaluation
        /// Stockfish's best move in UCI form, e.g. "e2e4" (nil if the game is over).
        var bestMove: String?
    }

    private let engine = Engine(type: .stockfish)
    private var responses: AsyncStream<EngineResponse>.AsyncIterator?

    /// Starts Stockfish and waits until it's ready (the first start loads its neural networks).
    private func startIfNeeded() async {
        guard responses == nil else { return }
        // Use a few of the phone's cores, leaving the rest so the app stays smooth.
        let cores = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
        await engine.start(coreCount: cores)
        responses = await engine.responseStream?.makeAsyncIterator()
        while await !engine.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await waitUntilReady()
    }

    /// Analyses one position.
    ///
    /// - parameter depth: How many moves ahead Stockfish looks.
    /// - parameter maxMilliseconds: Hard time limit, so long games still finish quickly.
    func evaluate(_ position: Position, depth: Int, maxMilliseconds: Int) async -> Result? {
        let whiteToMove = position.sideToMove == .white

        // Finished games need no engine: checkmate and stalemate have fixed scores.
        // (ChessKit's Board checks the side that just moved, so we flip the turn before asking.)
        var flipped = position
        flipped.toggleSideToMove()
        switch Board(position: flipped).state {
        case .checkmate: return Result(eval: .mate(whiteToMove ? -1 : 1), bestMove: nil)
        case .draw(.stalemate): return Result(eval: .centipawns(0), bestMove: nil)
        default: break
        }

        await startIfNeeded()

        await engine.send(command: .position(.fen(position.fen)))
        await engine.send(command: .go(depth: depth, movetime: maxMilliseconds))

        var bestScore: EngineResponse.Info.Score?
        var bestDepth = -1
        var bestMove: String?

        // An async iterator can't be advanced while stored in an actor property, so use a local copy.
        guard var iterator = responses else { return nil }
        defer { responses = iterator }
        while let response = await iterator.next() {
            // Messages can arrive slightly out of order, so a late message about the previous
            // position may turn up here. Its suggested move would start from a square that
            // doesn't hold one of our pieces, which is how we spot and skip it.
            if case let .info(info) = response,
               let score = info.score, info.multipv ?? 1 == 1,
               let firstMove = info.pv?.first, Self.isOwnMove(firstMove, in: position),
               score.lowerbound != true, score.upperbound != true,
               (info.depth ?? 0) >= bestDepth {
                bestScore = score
                bestDepth = info.depth ?? 0
            } else if case let .bestmove(move, _) = response,
                      move == "(none)" || Self.isOwnMove(move, in: position) {
                bestMove = move == "(none)" ? nil : move
                break
            }
        }

        // Keep the engine in step before the next position.
        responses = iterator
        await waitUntilReady()
        iterator = responses ?? iterator

        guard let bestScore else { return nil }
        // Stockfish scores from the side to move; flip so positive always means White is better.
        let sign = whiteToMove ? 1 : -1
        let eval: Evaluation
        if let mate = bestScore.mate {
            // "mate 0" means the side to move has already been checkmated.
            eval = .mate(mate == 0 ? -sign : mate * sign)
        } else {
            eval = .centipawns(Int(bestScore.cp ?? 0) * sign)
        }
        return Result(eval: eval, bestMove: bestMove)
    }

    /// True if a UCI move like "e2e4" starts on a square holding a piece of the side to move.
    private static func isOwnMove(_ uci: String, in position: Position) -> Bool {
        guard uci.count >= 4 else { return false }
        let start = Square(String(uci.prefix(2)))
        return position.piece(at: start)?.color == position.sideToMove
    }

    private func waitUntilReady() async {
        guard var iterator = responses else { return }
        defer { responses = iterator }
        await engine.send(command: .isready)
        while let response = await iterator.next() {
            if case .readyok = response { return }
        }
    }
}
