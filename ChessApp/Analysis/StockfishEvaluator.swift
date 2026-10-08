import ChessKit
import ChessKitEngine
import Foundation

/// Talks to the Stockfish chess engine that runs inside the app (no internet needed).
///
/// Only one position is analysed at a time; `AnalysisCenter` makes sure of that.
/// Every wait for the engine has a time limit. If Stockfish ever goes quiet, the engine is
/// restarted and that one position is skipped instead of freezing the whole analysis.
actor StockfishEvaluator {
    /// What Stockfish thinks of one position.
    struct Result {
        /// Score from White's point of view.
        var eval: Evaluation
        /// Stockfish's best move in UCI form, e.g. "e2e4" (nil if the game is over).
        var bestMove: String?
        /// The line Stockfish expects, as engine moves like ["e2e4", "e7e5"].
        var line: [String] = []
    }

    // The engine can only think about one position at a time. Anything that wants it
    // (the background analysis, a drill) waits its turn here.
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if isBusy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isBusy = true
        }
    }

    private func release() {
        if waiting.isEmpty { isBusy = false } else { waiting.removeFirst().resume() }
    }

    /// Hands out engine messages one at a time, so a wait can be raced against a timer.
    private final class Reader: @unchecked Sendable {
        var iterator: AsyncStream<EngineResponse>.AsyncIterator
        init(_ iterator: AsyncStream<EngineResponse>.AsyncIterator) { self.iterator = iterator }
        func next() async -> EngineResponse? { await iterator.next() }
    }

    private var engine = Engine(type: .stockfish)
    private var reader: Reader?

    /// How many times the engine had to be restarted.
    private(set) var restarts = 0

    /// Starts Stockfish and waits until it's ready (the first start loads its neural networks).
    private func startIfNeeded() async -> Bool {
        if reader != nil { return true }
        // Use a few of the phone's cores, leaving the rest so the app stays smooth.
        let cores = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
        await engine.start(coreCount: cores)
        guard let stream = await engine.responseStream else { return false }
        reader = Reader(stream.makeAsyncIterator())
        let deadline = Date().addingTimeInterval(20)
        while await !engine.isRunning {
            if Date() > deadline { await restart(); return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // A bigger memory table lets Stockfish reuse more work between neighbouring positions.
        await engine.send(command: .setoption(id: "Hash", value: "64"))
        return await waitUntilReady(timeout: 20)
    }

    /// Throws the engine away and makes a fresh one. The next analysis starts it again.
    private func restart() async {
        restarts += 1
        await engine.stop()
        engine = Engine(type: .stockfish)
        reader = nil
    }

    /// Tells the engine a new game is starting, so it forgets the previous one.
    func newGame() async {
        await acquire()
        defer { release() }
        guard await startIfNeeded() else { return }
        await engine.send(command: .ucinewgame)
        _ = await waitUntilReady(timeout: 5)
    }

    /// Waits for the next engine message, giving up after `seconds`.
    /// Returns nil on timeout (or if the engine's message stream ended).
    private func nextResponse(timeout seconds: Double) async -> EngineResponse? {
        guard let reader else { return nil }
        return await withTaskGroup(of: EngineResponse?.self) { group in
            group.addTask { await reader.next() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Analyses one position. Returns nil if the engine didn't answer in time.
    ///
    /// - parameter depth: How many moves ahead Stockfish looks.
    /// - parameter maxMilliseconds: Hard time limit, so long games still finish quickly.
    func evaluate(_ position: Position, depth: Int, maxMilliseconds: Int) async -> Result? {
        await acquire()
        defer { release() }
        return await run(position, depth: depth, maxMilliseconds: maxMilliseconds)
    }

    private func run(_ position: Position, depth: Int, maxMilliseconds: Int) async -> Result? {
        let whiteToMove = position.sideToMove == .white

        // Finished games need no engine: checkmate and stalemate have fixed scores.
        // (ChessKit's Board checks the side that just moved, so we flip the turn before asking.)
        // ChessKit's `toggleSideToMove()` does nothing since 0.17, so the turn is flipped in the FEN text.
        var fenParts = position.fen.split(separator: " ").map(String.init)
        if fenParts.count >= 4 {
            fenParts[1] = whiteToMove ? "b" : "w"
            fenParts[3] = "-"
            if let flipped = Position(fen: fenParts.joined(separator: " ")) {
                switch Board(position: flipped).state {
                case .checkmate: return Result(eval: .mate(whiteToMove ? -1 : 1), bestMove: nil)
                case .draw(.stalemate): return Result(eval: .centipawns(0), bestMove: nil)
                default: break
                }
            }
        }

        guard let fen = Self.engineSafeFEN(position) else { return nil }
        guard await startIfNeeded() else { return nil }

        await engine.send(command: .position(.fen(fen)))
        await engine.send(command: .go(depth: depth, movetime: maxMilliseconds))

        var bestScore: EngineResponse.Info.Score?
        var bestDepth = -1
        var bestMove: String?
        var bestLine: [String] = []

        // The engine should answer within its time limit; allow some slack, then ask it to stop.
        var wait = Double(maxMilliseconds) / 1000 + 2
        var askedToStop = false
        while true {
            guard let response = await nextResponse(timeout: wait) else {
                if askedToStop {
                    // Still silent: the engine is stuck. Restart it and skip this position.
                    await restart()
                    return nil
                }
                await engine.send(command: .stop)
                askedToStop = true
                wait = 2
                continue
            }
            // Messages can arrive slightly out of order, so a late message about the previous
            // position may turn up here. Its suggested move would start from a square that
            // doesn't hold one of our pieces, which is how we spot and skip it.
            if case let .info(info) = response,
               let score = info.score, info.multipv ?? 1 == 1,
               let firstMove = info.pv?.first, Self.isOwnMove(firstMove, in: position),
               score.lowerbound != true, score.upperbound != true,
               (info.depth ?? 0) >= bestDepth {
                bestScore = score
                bestLine = info.pv ?? []
                bestDepth = info.depth ?? 0
            } else if case let .bestmove(move, _) = response,
                      move == "(none)" || Self.isOwnMove(move, in: position) {
                bestMove = move == "(none)" ? nil : move
                break
            }
        }

        // Keep the engine in step before the next position.
        guard await waitUntilReady(timeout: 3) else { return nil }

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
        return Result(eval: eval, bestMove: bestMove, line: bestLine)
    }

    /// The position as FEN text that Stockfish can read safely, or nil if it shouldn't be sent at all.
    ///
    /// ChessKit only drops a castling right when the king or rook MOVES, not when the rook is
    /// captured on its starting square. Stockfish trusts the castling letters and searches for
    /// the rook without stopping at the board's edge, which corrupts its memory and crashes the app.
    /// So a castling letter is kept only if the king and that rook are really on their starting squares.
    static func engineSafeFEN(_ position: Position) -> String? {
        let kings = position.pieces.filter { $0.kind == .king }
        guard kings.count == 2, Set(kings.map(\.color)).count == 2 else { return nil }
        var parts = position.fen.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return nil }

        func has(_ kind: Piece.Kind, _ color: Piece.Color, _ square: String) -> Bool {
            let piece = position.piece(at: Square(square))
            return piece?.kind == kind && piece?.color == color
        }
        let rights: [(letter: Character, color: Piece.Color, king: String, rook: String)] = [
            ("K", .white, "e1", "h1"), ("Q", .white, "e1", "a1"),
            ("k", .black, "e8", "h8"), ("q", .black, "e8", "a8"),
        ]
        let kept = rights.filter { right in
            parts[2].contains(right.letter) && has(.king, right.color, right.king) && has(.rook, right.color, right.rook)
        }
        parts[2] = kept.isEmpty ? "-" : String(kept.map(\.letter))
        return parts.joined(separator: " ")
    }

    /// True if a UCI move like "e2e4" starts on a square holding a piece of the side to move.
    private static func isOwnMove(_ uci: String, in position: Position) -> Bool {
        guard uci.count >= 4 else { return false }
        let start = Square(String(uci.prefix(2)))
        return position.piece(at: start)?.color == position.sideToMove
    }

    /// Sends "isready" and waits for the engine's "readyok". Restarts the engine if it never comes.
    private func waitUntilReady(timeout seconds: Double) async -> Bool {
        await engine.send(command: .isready)
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let response = await nextResponse(timeout: remaining) else {
                await restart()
                return false
            }
            if case .readyok = response { return true }
        }
    }
}
