import ChessKit
import Foundation
import Observation

/// Runs one drill session: up to 10 questions, mixing the player's own mistakes with matching puzzles.
///
/// A question goes like this: you get two tries (a hint is allowed), then the answer is shown.
/// Every question ends with one `DrillOutcome`, saved on the phone for spaced repetition later.
@MainActor
@Observable
final class DrillSessionModel {
    enum Phase {
        /// Waiting for the player to move.
        case asking
        /// Stockfish is checking a move, or the opponent is replying in a puzzle.
        case thinking
        case solved
        /// The answer was shown (second wrong move, or "I give up").
        case revealed
        /// Looking back at a question that was answered earlier.
        case reviewing
    }

    /// One move shown in a replay, marked as the player's or the opponent's.
    struct ReplayMove: Identifiable {
        let id = UUID()
        let san: String
        let mine: Bool
    }

    /// A move the player tried that wasn't right.
    private struct WrongMove {
        let uci: String
        let positionAfter: Position
    }

    let leak: Leak
    let questions: [DrillQuestion]
    private(set) var index = 0
    /// How each question went (nil = not answered yet).
    private(set) var outcomes: [DrillOutcome?]
    private(set) var showSummary = false

    private(set) var board = Board(position: .standard)
    private(set) var selected: Square?
    private(set) var highlights: Set<Square> = []
    private(set) var arrows: [BoardArrow] = []
    private(set) var phase = Phase.asking
    private(set) var message = ""
    /// A one-line "why", shown once the question is over.
    private(set) var explanation: String?
    private(set) var wrongTries = 0
    private(set) var hintUsed = false
    /// Which side is at the bottom of the board for this question.
    private(set) var flipped = false
    /// Seconds left of the forced pause (only used for the "Rushing your moves" drills).
    private(set) var pauseLeft = 0
    /// How long "Rushing your moves" drills make you look before you can move.
    static let rushPauseSeconds = 5

    // Replays ("Why your move fails" / "Why the best move works").
    private(set) var replayTitle: String?
    private(set) var replayMoves: [ReplayMove] = []
    private(set) var isReplaying = false

    // Explore mode.
    private(set) var exploring = false
    private(set) var exploreEval: Evaluation?

    /// The position the question starts from (for puzzles, after the opponent's setup move).
    private var questionStart = Position.standard
    /// Moves still to play in the current puzzle (yours, then theirs, and so on).
    private var puzzleMoves: [String] = []
    private var wrongMoves: [WrongMove] = []
    private var pauseTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var exploreToken = 0
    private let evaluator = AnalysisCenter.shared.evaluator

    var current: DrillQuestion? { index < questions.count ? questions[index] : nil }
    var allAnswered: Bool { !outcomes.contains { $0 == nil } }
    /// Questions solved, in any way.
    var score: Int { outcomes.compactMap { $0 }.filter(\.solved).count }
    var firstTryCount: Int { outcomes.compactMap { $0 }.filter { $0 == .pass }.count }
    var canGoBack: Bool { index > 0 && !showSummary }
    /// Forward (and "Next") only appear once the current question has a result.
    var canGoForward: Bool { !showSummary && outcomes[index] != nil }
    /// True when the first wrong tries are used up and a hint is still allowed.
    var canHint: Bool { phase == .asking && pauseLeft == 0 }

    /// Builds a session for one leak: about half the player's own mistakes, the rest puzzles.
    init(leak: Leak, playerRating: Int) {
        self.leak = leak
        let own = Self.pickSpots(leak.spots, count: PuzzleLibrary.isAvailable ? 5 : 10)
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
        outcomes = Array(repeating: nil, count: mixed.count)
        loadQuestion(at: 0)
    }

    // MARK: - Question text

    var prompt: String {
        guard let question = current else { return "" }
        // Use the starting position, because the board changes as moves are played or replayed.
        let side = questionStart.sideToMove == .white ? "White" : "Black"
        switch question.source {
        case .ownMistake(let spot):
            var text = "From your game (\(spot.gameLabel)). You played \(spot.playedMove) here"
            if let clock = spot.clockBefore, leak.kind == .timeTrouble || leak.kind == .rushedMoves {
                text += ", with \(Self.clockText(clock)) left on your clock"
            }
            return text + ". Find a better move."
        case .puzzle(let puzzle):
            return "Puzzle, rated \(puzzle.rating). Find the best move for \(side)."
        }
    }

    /// Seconds as a clock reading, like "0:08" or "2:41".
    static func clockText(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Chooses own-mistake questions. First pass: one per game. Then more, but never two with the same
    /// answer from the same game.
    private static func pickSpots(_ spots: [DrillSpot], count: Int) -> [DrillSpot] {
        var chosen: [DrillSpot] = []
        var games = Set<String>()
        var answers = Set<String>()
        for spot in spots.shuffled() where chosen.count < count && games.insert(spot.game.pgn).inserted {
            chosen.append(spot)
            answers.insert(spot.game.pgn + "|" + spot.betterMove)
        }
        for spot in spots.shuffled() where chosen.count < count {
            let key = spot.game.pgn + "|" + spot.betterMove
            if answers.insert(key).inserted && !chosen.contains(where: { $0.game.pgn == spot.game.pgn && $0.ply == spot.ply }) {
                chosen.append(spot)
            }
        }
        return chosen
    }

    var sourceName: String {
        guard let question = current else { return "" }
        if case .ownMistake = question.source { return "Your own mistake" }
        return "Practice puzzle"
    }

    /// A short description of a question, for the results list.
    func summary(of question: DrillQuestion) -> String {
        switch question.source {
        case .ownMistake(let spot): "\(spot.gameLabel) · you played \(spot.playedMove)"
        case .puzzle(let puzzle): "Puzzle rated \(puzzle.rating)"
        }
    }

    func isOwnMistake(_ question: DrillQuestion) -> Bool {
        if case .ownMistake = question.source { return true }
        return false
    }

    /// Whether "Why your move fails" has something to show: a wrong move you tried,
    /// or (for your own mistakes) the move you played in the game.
    var canExplainFailure: Bool {
        guard let question = current else { return false }
        if !wrongMoves.isEmpty { return true }
        return isOwnMistake(question)
    }

    // MARK: - Loading and navigation

    private func loadQuestion(at newIndex: Int) {
        index = newIndex
        showSummary = false
        wrongTries = 0
        hintUsed = false
        wrongMoves = []
        selected = nil
        highlights = []
        arrows = []
        message = ""
        explanation = nil
        puzzleMoves = []
        replayTask?.cancel()
        pauseTask?.cancel()
        pauseLeft = 0
        isReplaying = false
        replayTitle = nil
        replayMoves = []
        exploring = false
        exploreEval = nil
        guard let question = current else { return }

        switch question.source {
        case .ownMistake(let spot):
            board = Board(position: spot.game.positions[spot.ply - 1])
            flipped = !spot.playerIsWhite
        case .puzzle(let puzzle):
            board = Board(position: Position(fen: puzzle.fen) ?? .standard)
            // The first move belongs to the opponent and sets up the position.
            if let first = puzzle.moves.first { _ = UCIMove.play(first, on: &board) }
            puzzleMoves = Array(puzzle.moves.dropFirst())
            flipped = board.position.sideToMove == .black
        }
        questionStart = board.position

        if let outcome = outcomes[newIndex] {
            // Already answered: show it again, ready to be looked at.
            phase = .reviewing
            puzzleMoves = []
            message = "\(outcome.label)."
            explanation = explanationSentence(for: question)
            if let key = bestMoves(for: question).first { arrows = [arrow(key)] }
        } else {
            phase = .asking
            if leak.kind == .rushedMoves { startPause(seconds: Self.rushPauseSeconds) }
        }
    }

    func goBack() {
        guard canGoBack else { return }
        loadQuestion(at: index - 1)
    }

    func goForward() {
        guard canGoForward else { return }
        if index + 1 < questions.count {
            loadQuestion(at: index + 1)
        } else {
            replayTask?.cancel()
            pauseTask?.cancel()
            showSummary = true
        }
    }

    func open(_ questionIndex: Int) {
        guard questions.indices.contains(questionIndex) else { return }
        loadQuestion(at: questionIndex)
    }

    func showResults() {
        guard allAnswered else { return }
        replayTask?.cancel()
        pauseTask?.cancel()
        showSummary = true
    }

    // MARK: - Moves

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
        if exploring {
            selectOrMove(square, onMove: { _ in exploreMoved() })
            return
        }
        guard phase == .asking, pauseLeft == 0 else { return }
        selectOrMove(square, onMove: { attempt(from: $0.from, to: $0.to) })
    }

    /// Tap logic shared by answering and exploring: pick a piece, then a square for it.
    private func selectOrMove(_ square: Square, onMove: ((from: Square, to: Square)) -> Void) {
        let mover = board.position.sideToMove
        if let from = selected {
            if square == from {
                selected = nil
            } else if board.position.piece(at: square)?.color == mover {
                selected = square
            } else {
                selected = nil
                if exploring {
                    var trial = board
                    if var move = trial.move(pieceAt: from, to: square) {
                        if case .promotion(let pending) = trial.state { move = trial.completePromotion(of: pending, to: .queen) }
                        _ = move
                        board = trial
                        onMove((from, square))
                    }
                } else {
                    onMove((from, square))
                }
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
        let tried = WrongMove(uci: uci, positionAfter: trial.position)

        switch question.source {
        case .ownMistake(let spot):
            let played = Self.plain(move.san)
            if played == Self.plain(spot.betterMove) {
                board = trial
                solved("That's the move Stockfish picks.")
            } else if played == Self.plain(spot.playedMove) {
                wrong(tried, "Not quite, try again. That's the move you played in the game.")
            } else {
                check(trial.position, against: spot, tried: tried)
            }
        case .puzzle:
            guard let expected = puzzleMoves.first else { return }
            if uci.lowercased() == expected.lowercased() {
                board = trial
                highlights = []
                puzzleMoves.removeFirst()
                if puzzleMoves.isEmpty {
                    solved("Correct!")
                } else {
                    message = "Right, keep going."
                    replyAsOpponent()
                }
            } else {
                wrong(tried, "Not quite, try again.")
            }
        }
    }

    /// Plays the opponent's reply in a puzzle after a short pause.
    private func replyAsOpponent() {
        phase = .thinking
        let shown = index
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard index == shown, let reply = puzzleMoves.first else { return }
            UCIMove.play(reply, on: &board)
            puzzleMoves.removeFirst()
            phase = .asking
            if puzzleMoves.isEmpty { solved("Correct!") }
        }
    }

    /// A move that isn't Stockfish's first choice can still be good: accept it if it loses under 0.3 pawns.
    private func check(_ after: Position, against spot: DrillSpot, tried: WrongMove) {
        phase = .thinking
        message = "Checking your move…"
        let shown = index
        Task {
            let result = await evaluator.evaluate(after, depth: 12, maxMilliseconds: 200)
            guard phase == .thinking, index == shown else { return }
            phase = .asking
            guard let result else {
                message = "I couldn't check that move. Try another."
                return
            }
            if spot.requiresMate {
                // The right answer here is a forced checkmate, so a merely good move isn't enough.
                guard case .mate(let moves) = result.eval, spot.playerIsWhite ? moves > 0 : moves < 0 else {
                    wrong(tried, "Not quite, try again. Look for checkmate.")
                    return
                }
                board = Board(position: after)
                solved("That still forces checkmate. Good find.")
                return
            }
            let value = result.eval.cappedCentipawns
            let mine = spot.playerIsWhite ? value : -value
            if spot.evalBefore - mine <= 30 {
                board = Board(position: after)
                solved("Stockfish likes that almost as much as \(spot.betterMove).")
            } else {
                wrong(tried, "Not quite, try again.")
            }
        }
    }

    // MARK: - Hint

    /// Highlights the piece that should move. Using it changes how the question is graded.
    func hint() {
        guard canHint, let question = current else { return }
        hintUsed = true
        let key: String? = switch question.source {
        case .puzzle: puzzleMoves.first
        case .ownMistake: bestMoves(for: question).first
        }
        if let key, key.count >= 4 {
            highlights = [Square(String(key.prefix(2)))]
            message = "Hint: try moving the highlighted piece."
        }
    }

    // MARK: - Results

    private func solved(_ text: String) {
        let outcome: DrillOutcome = hintUsed ? .hinted : (wrongTries == 0 ? .pass : .secondTry)
        highlights = []
        arrows = []
        selected = nil
        phase = .solved
        message = (outcome == .pass ? "Correct, first try! " : outcome == .hinted ? "Solved, with a hint. " : "Solved on the second try. ") + text
        finish(outcome)
    }

    private func wrong(_ tried: WrongMove, _ text: String) {
        wrongTries += 1
        wrongMoves.append(tried)
        selected = nil
        if wrongTries >= 2 {
            reveal()
        } else {
            // The board didn't change, so the piece is back where it was.
            message = text
        }
    }

    /// Shows the answer: an arrow, then the solution played out. Counts as "revealed".
    func reveal() {
        guard let question = current, phase == .asking || phase == .thinking else { return }
        phase = .revealed
        selected = nil
        highlights = []
        let line = bestMoves(for: question)
        let san = line.first.flatMap { UCIMove.san(for: $0, in: questionStart) }
        message = san.map { "Not this time. The best move was \($0)." } ?? "Not this time."
        finish(.revealed)
        // Play the whole solution out from the start, then return to the start with an arrow on the best move.
        if line.isEmpty { restState() } else { startReplay(from: questionStart, moves: line, title: "The solution") }
    }

    /// Saves the result and prepares the one-line explanation.
    private func finish(_ outcome: DrillOutcome) {
        guard let question = current else { return }
        outcomes[index] = outcome
        DrillStats.record(leak.kind, right: outcome.solved)
        var record = DrillRecord(key: question.stableKey, leak: leak.kind.rawValue, outcome: outcome, date: Date())
        switch question.source {
        case .ownMistake(let spot):
            record.gamePGN = spot.game.pgn
            record.ply = spot.ply
        case .puzzle(let puzzle):
            record.puzzleID = puzzle.id
        }
        DrillHistory.append(record)
        explanation = explanationSentence(for: question)
    }

    private func explanationSentence(for question: DrillQuestion) -> String? {
        switch question.source {
        case .ownMistake(let spot): DrillExplainer.sentence(for: spot, leak: leak.kind)
        case .puzzle(let puzzle): DrillExplainer.sentence(for: puzzle, wanted: leak.themes.isEmpty ? leak.kind.puzzleThemes : leak.themes)
        }
    }

    /// The resting look of a finished question: the starting position with an arrow on the best move.
    private func restState() {
        board = Board(position: questionStart)
        selected = nil
        highlights = []
        if let question = current, let key = bestMoves(for: question).first { arrows = [arrow(key)] } else { arrows = [] }
    }

    // MARK: - Best move and replays

    /// Stockfish's (or the puzzle's) best moves from the question's starting position, as engine moves.
    private func bestMoves(for question: DrillQuestion) -> [String] {
        switch question.source {
        case .puzzle(let puzzle):
            return Array(puzzle.moves.dropFirst())
        case .ownMistake(let spot):
            if !spot.bestLine.isEmpty { return spot.bestLine }
            if let uci = spot.betterUCI ?? UCIMove.uci(forSAN: spot.betterMove, in: questionStart) { return [uci] }
            return []
        }
    }

    private func arrow(_ uci: String) -> BoardArrow {
        BoardArrow(from: Square(String(uci.prefix(2))), to: Square(String(uci.dropFirst(2).prefix(2))))
    }

    /// "Why the best move works": replays the best line (at most 3 moves) from the start of the question.
    func replayBestMove() {
        guard let question = current else { return }
        let line = Array(bestMoves(for: question).prefix(3))
        guard !line.isEmpty else { return }
        startReplay(from: questionStart, moves: line, title: "Why the best move works")
    }

    /// "Why your move fails": shows your move, then the engine's answer to it (at most 3 more moves).
    func replayFailure() {
        guard let question = current else { return }
        replayTask?.cancel()
        exploring = false
        isReplaying = true
        replayTitle = "Why your move fails"
        replayMoves = []
        arrows = []
        board = Board(position: questionStart)

        let shown = index
        replayTask = Task {
            var first: String?
            var reply: [String] = []
            if let wrong = wrongMoves.last {
                first = wrong.uci
                let result = await evaluator.evaluate(wrong.positionAfter, depth: 14, maxMilliseconds: 400)
                reply = Array((result?.line ?? []).prefix(3))
            } else if case .ownMistake(let spot) = question.source {
                // Nothing wrong was tried, so show the move that was played in the game.
                first = UCIMove.uci(forSAN: spot.playedMove, in: questionStart)
                reply = Array(spot.playedLine.prefix(3))
            }
            guard !Task.isCancelled, index == shown, let first else {
                isReplaying = false
                return
            }
            await play(moves: [first] + reply)
        }
    }

    private func startReplay(from position: Position, moves: [String], title: String) {
        replayTask?.cancel()
        exploring = false
        isReplaying = true
        replayTitle = title
        replayMoves = []
        arrows = []
        board = Board(position: position)
        let shown = index
        replayTask = Task {
            guard !Task.isCancelled, index == shown else { return }
            await play(moves: moves)
        }
    }

    /// Plays moves one at a time with an arrow, leaving the last arrow on the board.
    private func play(moves: [String]) async {
        let shown = index
        for (step, uci) in moves.enumerated() {
            guard !Task.isCancelled, index == shown else { return }
            arrows = [arrow(uci)]
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, index == shown, let move = UCIMove.play(uci, on: &board) else { break }
            // The first move is always the player's; replies alternate.
            replayMoves.append(ReplayMove(san: UCIMove.display(move.san), mine: step % 2 == 0))
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !Task.isCancelled, index == shown else { return }
        // Let the end of the line sink in, then go back to the starting position.
        try? await Task.sleep(for: .milliseconds(1100))
        guard !Task.isCancelled, index == shown, !exploring else { return }
        restState()
        isReplaying = false
    }

    // MARK: - Explore mode

    /// Move pieces freely from the question's position, with the eval bar showing who is better.
    func startExploring() {
        replayTask?.cancel()
        isReplaying = false
        replayTitle = nil
        replayMoves = []
        arrows = []
        highlights = []
        selected = nil
        board = Board(position: questionStart)
        exploring = true
        exploreEval = nil
        evaluateExplore()
    }

    /// Puts the pieces back where they were at the start of the question.
    func resetExplore() {
        guard exploring else { return }
        selected = nil
        board = Board(position: questionStart)
        exploreEval = nil
        evaluateExplore()
    }

    func stopExploring() {
        exploring = false
        exploreEval = nil
        exploreToken += 1
        restState()
    }

    private func exploreMoved() {
        evaluateExplore()
    }

    private func evaluateExplore() {
        exploreToken += 1
        let token = exploreToken
        let position = board.position
        Task {
            let result = await evaluator.evaluate(position, depth: 10, maxMilliseconds: 150)
            guard token == exploreToken, exploring else { return }
            exploreEval = result?.eval
        }
    }

    /// Notation without check marks, so "Qb4+" and "Qb4" compare equal.
    private static func plain(_ san: String) -> String {
        san.filter { $0 != "+" && $0 != "#" && $0 != "!" && $0 != "?" }
            .replacingOccurrences(of: "0", with: "O")   // ChessKit writes castling with zeros
            .replacingOccurrences(of: "–", with: "-")
    }
}
