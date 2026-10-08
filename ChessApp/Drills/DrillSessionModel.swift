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

    // "What's loose?" and "What did they just leave?"
    /// The squares you have tapped so far in a "What's loose?" question.
    private(set) var loosePicks: Set<Square> = []
    /// The squares of the opponent's last move, shown in "What did they just leave?" questions.
    private(set) var lastMove: Set<Square> = []
    private var looseAnswer: [Square] = []
    /// Where the best line starts: the position before the player's move. For "What's loose?" this differs
    /// from `questionStart`, which is the position after the move.
    private var lineStart = Position.standard

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
        let built = leak.group == .tactics
            ? Self.tacticsQuestions(leak: leak, rating: playerRating)
            : Self.mixedQuestions(leak: leak, rating: playerRating)
        questions = built
        outcomes = Array(repeating: nil, count: built.count)
        loadQuestion(at: 0)
    }

    /// The default session: about half the player's own mistakes, the rest puzzles, alternating.
    private static func mixedQuestions(leak: Leak, rating: Int) -> [DrillQuestion] {
        let own = pickSpots(leak.spots, count: PuzzleLibrary.isAvailable ? 5 : 10)
        let themes = leak.group.puzzleThemes
        let puzzles = PuzzleLibrary.pick(themes: themes, rating: rating, count: 10 - own.count)
        var mixed: [DrillQuestion] = []
        var ownQuestions = own.map { DrillQuestion(group: leak.group, source: .ownMistake($0)) }
        var puzzleQuestions = puzzles.map { DrillQuestion(group: leak.group, source: .puzzle($0), wantedThemes: themes) }
        while !ownQuestions.isEmpty || !puzzleQuestions.isEmpty {
            if !ownQuestions.isEmpty { mixed.append(ownQuestions.removeFirst()) }
            if !puzzleQuestions.isEmpty { mixed.append(puzzleQuestions.removeFirst()) }
        }
        return mixed
    }

    /// A Tactics session: up to 2 "What's loose?", up to 2 "What did they just leave?", up to 3 find-the-move
    /// questions from your own games, then puzzles of the patterns you miss most, with the same pattern kept together.
    private static func tacticsQuestions(leak: Leak, rating: Int) -> [DrillQuestion] {
        func key(_ spot: DrillSpot) -> String { "\(spot.game.pgn)#\(spot.ply)" }
        var used = Set<String>()
        var questions: [DrillQuestion] = []

        // 1. What's loose? (only positions where we can name the loose pieces and they match what Stockfish takes)
        let looseSpots = leak.spots.filter { $0.habit == .hangingPieces && looseSquares(for: $0) != nil }
        for spot in pickSpots(looseSpots, count: 2) {
            questions.append(DrillQuestion(group: .tactics, source: .ownMistake(spot), mode: .looseCheck))
            used.insert(key(spot))
        }

        // 2. What did they just leave?
        let leftSpots = leak.spots.filter { $0.afterOpponentMistake && !used.contains(key($0)) }
        for spot in pickSpots(leftSpots, count: 2) {
            questions.append(DrillQuestion(group: .tactics, source: .ownMistake(spot), mode: .leftCheck))
            used.insert(key(spot))
        }

        // 3. Find the better move in your own missed tactics.
        let restSpots = leak.spots.filter { !used.contains(key($0)) }
        let findCount = max(0, min(3, 10 - questions.count - 3))
        for spot in pickSpots(restSpots, count: findCount) {
            questions.append(DrillQuestion(group: .tactics, source: .ownMistake(spot)))
        }

        // 4. Puzzles, same pattern together. Patterns come from what you miss most.
        let remaining = max(0, 10 - questions.count)
        var patterns = leak.tacticCounts.sorted { $0.value > $1.value }.map(\.key).filter { $0 != .other }
        if patterns.isEmpty { patterns = [.other] }
        patterns = Array(patterns.prefix(2))
        var usedPuzzles = Set<String>()
        var blocks: [DrillQuestion] = []
        for (index, pattern) in patterns.enumerated() {
            let share = patterns.count == 1 ? remaining : (index == 0 ? (remaining + 1) / 2 : remaining / 2)
            for puzzle in PuzzleLibrary.pick(themes: pattern.themes, rating: rating, count: share, excluding: usedPuzzles) {
                usedPuzzles.insert(puzzle.id)
                blocks.append(DrillQuestion(group: .tactics, source: .puzzle(puzzle), wantedThemes: pattern.themes))
            }
        }
        // If a pattern didn't have enough puzzles, top up with general tactics puzzles.
        if blocks.count < remaining {
            let themes = TacticType.other.themes
            for puzzle in PuzzleLibrary.pick(themes: themes, rating: rating, count: remaining - blocks.count, excluding: usedPuzzles) {
                blocks.append(DrillQuestion(group: .tactics, source: .puzzle(puzzle), wantedThemes: themes))
            }
        }
        // If we still have fewer than 10 questions (few spots), add more of your own.
        questions += blocks
        if questions.count < 10 {
            let more = leak.spots.filter { !used.contains(key($0)) }
            for spot in pickSpots(more, count: 10 - questions.count) where !questions.contains(where: { q in
                if case .ownMistake(let s) = q.source { return key(s) == key(spot) } else { return false }
            }) {
                questions.append(DrillQuestion(group: .tactics, source: .ownMistake(spot)))
            }
        }
        return questions
    }

    /// The player's pieces that the opponent can simply win after the move the player made, if we can name them
    /// and they include the piece Stockfish's reply actually takes. nil means "don't ask this question".
    private static func looseSquares(for spot: DrillSpot) -> [Square]? {
        guard spot.ply < spot.game.positions.count else { return nil }
        let after = spot.game.positions[spot.ply]
        let loose = TacticFinder.enPrise(after, color: spot.playerIsWhite ? .white : .black)
        guard !loose.isEmpty, let reply = spot.playedLine.first, reply.count >= 4 else { return nil }
        let target = Square(String(reply.dropFirst(2).prefix(2)))
        return loose.contains(target) ? loose : nil
    }

    // MARK: - Question text

    var prompt: String {
        guard let question = current else { return "" }
        // Use the starting position, because the board changes as moves are played or replayed.
        let side = questionStart.sideToMove == .white ? "White" : "Black"
        switch question.source {
        case .ownMistake(let spot):
            switch question.mode {
            case .looseCheck:
                return "From your game (\(spot.gameLabel)). You played \(spot.playedMove), and this is the position now. Your opponent is to move. Tap every one of your pieces they can win, then press Check."
            case .leftCheck:
                let theirs = Self.lastMoveText(for: spot)
                return "From your game (\(spot.gameLabel)). Your opponent just played \(theirs) (marked on the board). It left something. Find the move that punishes it."
            case .findMove:
                var text = "From your game (\(spot.gameLabel)). You played \(spot.playedMove) here"
                if let clock = spot.clockBefore, spot.habit == .timeTrouble || spot.habit == .rushedMoves {
                    text += ", with \(Self.clockText(clock)) left on your clock"
                }
                return text + ". Find a better move."
            }
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
        return name(of: question)
    }

    /// The kind of question, for the header and the results list.
    func name(of question: DrillQuestion) -> String {
        switch (question.source, question.mode) {
        case (.ownMistake, .looseCheck): "What's loose?"
        case (.ownMistake, .leftCheck): "What did they just leave?"
        case (.ownMistake, .findMove): "Your own mistake"
        case (.puzzle, _): "Practice puzzle"
        }
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

    /// What kind of question is on screen.
    var mode: DrillQuestion.Mode { current?.mode ?? .findMove }
    /// True while a "What's loose?" question is waiting for your picks.
    var isLooseQuestion: Bool { mode == .looseCheck }

    /// The opponent's last move in normal notation, like "Nf3".
    private static func lastMoveText(for spot: DrillSpot) -> String {
        guard spot.ply >= 1, spot.ply - 1 < spot.game.moveNames.count else { return "a move" }
        return spot.game.moveNames[spot.ply - 1].split(separator: " ").last.map(String.init) ?? "a move"
    }

    /// The squares the opponent's last move went from and to, if we can work them out.
    private static func lastMoveSquares(for spot: DrillSpot) -> Set<Square> {
        guard spot.ply >= 2, let uci = UCIMove.uci(forSAN: lastMoveText(for: spot), in: spot.game.positions[spot.ply - 2]) else { return [] }
        return [Square(String(uci.prefix(2))), Square(String(uci.dropFirst(2).prefix(2)))]
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
        loosePicks = []
        lastMove = []
        looseAnswer = []
        guard let question = current else { return }

        switch question.source {
        case .ownMistake(let spot):
            lineStart = spot.game.positions[spot.ply - 1]
            flipped = !spot.playerIsWhite
            switch question.mode {
            case .looseCheck:
                // Show the position AFTER your move, and ask which pieces are now loose.
                board = Board(position: spot.game.positions[spot.ply])
                looseAnswer = Self.looseSquares(for: spot) ?? []
            case .leftCheck:
                board = Board(position: lineStart)
                lastMove = Self.lastMoveSquares(for: spot)
            case .findMove:
                board = Board(position: lineStart)
            }
        case .puzzle(let puzzle):
            board = Board(position: Position(fen: puzzle.fen) ?? .standard)
            // The first move belongs to the opponent and sets up the position.
            if let first = puzzle.moves.first { _ = UCIMove.play(first, on: &board) }
            puzzleMoves = Array(puzzle.moves.dropFirst())
            flipped = board.position.sideToMove == .black
            lineStart = board.position
        }
        questionStart = board.position

        if let outcome = outcomes[newIndex] {
            // Already answered: show it again, ready to be looked at.
            phase = .reviewing
            puzzleMoves = []
            message = "\(outcome.label)."
            explanation = explanationSentence(for: question)
            restState()
        } else {
            phase = .asking
            // Rushed moves get a forced pause before you may touch the board.
            if case .ownMistake(let spot) = question.source, spot.habit == .rushedMoves {
                startPause(seconds: Self.rushPauseSeconds)
            }
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
        if mode == .looseCheck {
            // Pick (or un-pick) one of your own pieces.
            guard let piece = board.position.piece(at: square),
                  case .ownMistake(let spot) = current?.source, piece.color == (spot.playerIsWhite ? .white : .black) else {
                message = "Tap one of your own pieces."
                return
            }
            if loosePicks.contains(square) { loosePicks.remove(square) } else { loosePicks.insert(square) }
            return
        }
        selectOrMove(square, onMove: { attempt(from: $0.from, to: $0.to) })
    }

    /// "Check" in a "What's loose?" question: compare your picks with the pieces the opponent can win.
    func checkLoose() {
        guard mode == .looseCheck, phase == .asking else { return }
        guard !loosePicks.isEmpty else {
            message = "Tap the pieces you think are loose first."
            return
        }
        let answer = Set(looseAnswer)
        if loosePicks == answer {
            solved("Yes, those are the loose pieces.")
        } else if !loosePicks.isSubset(of: answer) {
            wrong(nil, "Not quite, try again. One of those pieces is safe.")
        } else {
            wrong(nil, "Not quite, try again. You missed a loose piece.")
        }
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
        if question.mode == .looseCheck {
            if let square = looseAnswer.first(where: { !loosePicks.contains($0) }) {
                highlights = [square]
                message = "Hint: the highlighted piece is one of the loose ones."
            }
            return
        }
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
        if mode == .looseCheck { restState() }
    }

    private func wrong(_ tried: WrongMove?, _ text: String) {
        wrongTries += 1
        if let tried { wrongMoves.append(tried) }
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
        if question.mode == .looseCheck {
            // Show the loose pieces and what the opponent takes; the safe move comes in the explanation.
            message = "Not this time. These were the loose pieces."
            finish(.revealed)
            restState()
            return
        }
        let line = bestMoves(for: question)
        let san = line.first.flatMap { UCIMove.san(for: $0, in: lineStart) }
        message = san.map { "Not this time. The best move was \($0)." } ?? "Not this time."
        finish(.revealed)
        // Play the whole solution out from the start, then return to the start with an arrow on the best move.
        if line.isEmpty { restState() } else { startReplay(from: lineStart, moves: line, title: "The solution") }
    }

    /// Saves the result and prepares the one-line explanation.
    private func finish(_ outcome: DrillOutcome) {
        guard let question = current else { return }
        outcomes[index] = outcome
        DrillStats.record(leak.group.rawValue, outcome: outcome)
        var record = DrillRecord(key: question.stableKey, leak: leak.group.rawValue, outcome: outcome, date: Date())
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
        case .ownMistake(let spot):
            switch question.mode {
            case .looseCheck:
                let base = DrillExplainer.sentence(for: spot, leak: .hangingPieces)
                return base.contains("safer") ? base : base + " A safer move was \(spot.betterMove)."
            case .leftCheck:
                return DrillExplainer.sentence(for: spot, leak: .notPunishing)
            case .findMove:
                return DrillExplainer.sentence(for: spot, leak: spot.habit)
            }
        case .puzzle(let puzzle):
            return DrillExplainer.sentence(for: puzzle, wanted: question.wantedThemes.isEmpty ? leak.group.puzzleThemes : question.wantedThemes)
        }
    }

    /// The resting look of a finished question: the starting position with an arrow on the best move.
    private func restState() {
        board = Board(position: questionStart)
        selected = nil
        // "What's loose?": show the loose pieces and the capture the opponent has.
        if let question = current, question.mode == .looseCheck, case .ownMistake(let spot) = question.source {
            highlights = Set(looseAnswer)
            if let reply = spot.playedLine.first, reply.count >= 4 { arrows = [arrow(reply)] } else { arrows = [] }
            return
        }
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
            if let uci = spot.betterUCI ?? UCIMove.uci(forSAN: spot.betterMove, in: lineStart) { return [uci] }
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
        startReplay(from: lineStart, moves: line, title: "Why the best move works")
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
        board = Board(position: lineStart)

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
                first = UCIMove.uci(forSAN: spot.playedMove, in: lineStart)
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
