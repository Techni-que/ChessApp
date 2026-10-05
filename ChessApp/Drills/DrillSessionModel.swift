import ChessKit
import Foundation
import Observation

/// Runs one drill session: up to 10 questions, mixing the player's own mistakes with matching puzzles.
@MainActor
@Observable
final class DrillSessionModel {
    enum Phase {
        /// Waiting for the player to move.
        case asking
        /// Stockfish is checking a move that wasn't the top choice.
        case thinking
        case solved
        /// The answer is on screen; waiting for "Next".
        case revealed
    }

    let leak: Leak
    let questions: [DrillQuestion]
    private(set) var index = 0
    /// true = right, false = wrong, nil = not answered yet.
    private(set) var results: [Bool?]
    private(set) var board = Board(position: .standard)
    private(set) var selected: Square?
    private(set) var highlights: Set<Square> = []
    private(set) var phase = Phase.asking
    private(set) var message = ""
    private(set) var answerText: String?
    private(set) var wrongTries = 0
    /// Which side is at the bottom of the board for this question.
    private(set) var flipped = false
    /// Seconds left of the forced pause (only used for the "Rushing your moves" drills).
    private(set) var pauseLeft = 0
    private var pauseTask: Task<Void, Never>?
    /// How long "Rushing your moves" drills make you look before you can move.
    static let rushPauseSeconds = 5

    /// Moves still to play in the current puzzle (yours, then theirs, and so on).
    private var puzzleMoves: [String] = []
    private let evaluator = AnalysisCenter.shared.evaluator

    var isFinished: Bool { index >= questions.count }
    var current: DrillQuestion? { isFinished ? nil : questions[index] }
    var score: Int { results.compactMap { $0 }.filter { $0 }.count }

    /// Builds a session for one leak: about half the player's own mistakes, the rest puzzles.
    init(leak: Leak, playerRating: Int) {
        self.leak = leak
        let own = Array(leak.spots.shuffled().prefix(PuzzleLibrary.isAvailable ? 5 : 10))
        let puzzles = PuzzleLibrary.pick(themes: leak.themes.isEmpty ? leak.kind.puzzleThemes : leak.themes, rating: playerRating, count: 10 - own.count)
        var mixed: [DrillQuestion] = []
        var ownQuestions = own.map { DrillQuestion(leak: leak.kind, source: .ownMistake($0)) }
        var puzzleQuestions = puzzles.map { DrillQuestion(leak: leak.kind, source: .puzzle($0)) }
        // Alternate the two kinds so the session doesn't feel repetitive.
        while !ownQuestions.isEmpty || !puzzleQuestions.isEmpty {
            if !ownQuestions.isEmpty { mixed.append(ownQuestions.removeFirst()) }
            if !puzzleQuestions.isEmpty { mixed.append(puzzleQuestions.removeFirst()) }
        }
        questions = mixed
        results = Array(repeating: nil, count: mixed.count)
        loadQuestion()
    }

    // MARK: - Question text

    var prompt: String {
        guard let question = current else { return "" }
        let side = board.position.sideToMove == .white ? "White" : "Black"
        switch question.source {
        case .ownMistake(let spot):
            return "From your game (\(spot.gameLabel)). You played \(spot.playedMove) here. Find a better move."
        case .puzzle(let puzzle):
            return "Puzzle, rated \(puzzle.rating). Find the best move for \(side)."
        }
    }

    var sourceName: String {
        guard let question = current else { return "" }
        if case .ownMistake = question.source { return "Your own mistake" }
        return "Practice puzzle"
    }

    // MARK: - Loading

    private func loadQuestion() {
        guard let question = current else { return }
        wrongTries = 0
        selected = nil
        highlights = []
        answerText = nil
        message = ""
        phase = .asking
        puzzleMoves = []
        pauseTask?.cancel()
        pauseLeft = 0
        if leak.kind == .rushedMoves { startPause(seconds: Self.rushPauseSeconds) }

        switch question.source {
        case .ownMistake(let spot):
            board = Board(position: spot.game.positions[spot.ply - 1])
            flipped = spot.playerIsWhite == false
        case .puzzle(let puzzle):
            board = Board(position: Position(fen: puzzle.fen) ?? .standard)
            // The first move belongs to the opponent and sets up the position.
            if let first = puzzle.moves.first { _ = Self.play(first, on: &board) }
            puzzleMoves = Array(puzzle.moves.dropFirst())
            flipped = board.position.sideToMove == .black
        }
    }

    // MARK: - Moves

    /// Plays an engine-style move like "e2e4" or "e7e8q". Returns the move if it was legal.
    @discardableResult
    private static func play(_ uci: String, on board: inout Board) -> Move? {
        guard uci.count >= 4 else { return nil }
        let start = Square(String(uci.prefix(2)))
        let end = Square(String(uci.dropFirst(2).prefix(2)))
        guard var move = board.move(pieceAt: start, to: end) else { return nil }
        if case .promotion(let pending) = board.state {
            let letter = uci.count == 5 ? uci.suffix(1).uppercased() : "Q"
            move = board.completePromotion(of: pending, to: Piece.Kind(rawValue: letter) ?? .queen)
        }
        return move
    }

    /// Counts down a few seconds during which the board can't be touched.
    private func startPause(seconds: Int) {
        pauseLeft = seconds
        pauseTask = Task {
            while pauseLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                pauseLeft -= 1
            }
        }
    }

    func handleTap(_ square: Square) {
        guard phase == .asking, pauseLeft == 0 else { return }
        let mover = board.position.sideToMove
        if let from = selected {
            if square == from {
                selected = nil
            } else if board.position.piece(at: square)?.color == mover {
                selected = square
            } else {
                selected = nil
                attempt(from: from, to: square)
            }
        } else if board.position.piece(at: square)?.color == mover {
            selected = square
        }
    }

    private func attempt(from: Square, to: Square) {
        guard let question = current else { return }
        var trial = board
        guard var move = trial.move(pieceAt: from, to: to) else {
            message = "That move isn't legal."
            return
        }
        var uci = from.notation + to.notation
        if case .promotion(let pending) = trial.state {
            move = trial.completePromotion(of: pending, to: .queen)
            uci += "q"
        }

        switch question.source {
        case .ownMistake(let spot):
            let played = Self.plain(move.san)
            if played == Self.plain(spot.betterMove) {
                board = trial
                solved("Yes, that's the move Stockfish picks.")
            } else if played == Self.plain(spot.playedMove) {
                wrong("That's the move you played in the game. Try something else.")
            } else {
                check(trial.position, against: spot)
            }
        case .puzzle:
            guard let expected = puzzleMoves.first else { return }
            if uci.lowercased() == expected.lowercased() {
                board = trial
                puzzleMoves.removeFirst()
                if puzzleMoves.isEmpty {
                    solved("Correct!")
                } else {
                    message = "Right, keep going."
                    replyAsOpponent()
                }
            } else {
                wrong("Not the best move here.")
            }
        }
    }

    /// Plays the opponent's reply in a puzzle after a short pause.
    private func replyAsOpponent() {
        phase = .thinking
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard let reply = puzzleMoves.first else { return }
            Self.play(reply, on: &board)
            puzzleMoves.removeFirst()
            phase = .asking
            if puzzleMoves.isEmpty { solved("Correct!") }
        }
    }

    /// A move that isn't Stockfish's first choice can still be good: accept it if it loses under 0.3 pawns.
    private func check(_ after: Position, against spot: DrillSpot) {
        phase = .thinking
        message = "Checking your move…"
        Task {
            let result = await evaluator.evaluate(after, depth: 12, maxMilliseconds: 200)
            guard phase == .thinking else { return }
            phase = .asking
            guard let result else {
                wrong("I couldn't check that move. Try another.")
                return
            }
            if spot.requiresMate {
                // The right answer here is a forced checkmate, so a merely good move isn't enough.
                guard case .mate(let moves) = result.eval, spot.playerIsWhite ? moves > 0 : moves < 0 else {
                    wrong("That doesn't win by force. Look for checkmate.")
                    return
                }
                board = Board(position: after)
                solved("Yes, that still forces checkmate. Good find.")
                return
            }
            let value = result.eval.cappedCentipawns
            let mine = spot.playerIsWhite ? value : -value
            if spot.evalBefore - mine <= 30 {
                board = Board(position: after)
                solved("Good move. Stockfish likes it almost as much as \(spot.betterMove).")
            } else {
                wrong("That gives away too much. Try again.")
            }
        }
    }

    // MARK: - Results

    private func solved(_ text: String) {
        message = text
        highlights = []
        phase = .solved
        results[index] = true
        DrillStats.record(leak.kind, right: true)
    }

    private func wrong(_ text: String) {
        wrongTries += 1
        if wrongTries >= 2 {
            reveal()
        } else {
            message = text
        }
    }

    /// Gives up on the question: shows the answer and counts it as wrong.
    func reveal() {
        guard let question = current, phase == .asking || phase == .thinking else { return }
        phase = .revealed
        results[index] = false
        DrillStats.record(leak.kind, right: false)
        selected = nil

        switch question.source {
        case .ownMistake(let spot):
            message = "Not this time. The best move was \(spot.betterMove)."
            answerText = nil
            showLine(from: board.position)
        case .puzzle:
            guard let expected = puzzleMoves.first else { return }
            let start = Square(String(expected.prefix(2)))
            let end = Square(String(expected.dropFirst(2).prefix(2)))
            highlights = [start, end]
            let san = AnalysisCenter.san(for: expected, in: board.position) ?? expected
            message = "Not this time. The best move was \(san)."
            answerText = nil
        }
    }

    /// Asks Stockfish for the best line and shows it as readable moves.
    private func showLine(from position: Position) {
        let shownIndex = index
        Task {
            guard let result = await evaluator.evaluate(position, depth: 14, maxMilliseconds: 400),
                  index == shownIndex else { return }
            var scratch = Board(position: position)
            var moves: [String] = []
            for uci in result.line.prefix(5) {
                guard let move = Self.play(uci, on: &scratch) else { break }
                moves.append(move.san)
            }
            if let first = result.line.first, first.count >= 4 {
                highlights = [Square(String(first.prefix(2))), Square(String(first.dropFirst(2).prefix(2)))]
            }
            if !moves.isEmpty { answerText = "Best line: " + moves.joined(separator: ", ") }
        }
    }

    func next() {
        pauseTask?.cancel()
        index += 1
        loadQuestion()
    }

    /// Notation without check marks, so "Qb4+" and "Qb4" compare equal.
    private static func plain(_ san: String) -> String {
        san.filter { $0 != "+" && $0 != "#" && $0 != "!" && $0 != "?" }
    }
}
