# ChessApp

A chess improvement companion for iPhone. Users load their own games, step through them,
and (later) get engine analysis and training from their mistakes.

## The person building this
The owner is a student with zero coding experience who builds the app by working with Claude Code.
- Work in small steps: one feature per session, and get it building before moving on.
- Explain every change in plain English, without jargon (or explain the jargon).
- When the owner has to do something in Xcode, say exactly what to click and where.
- Ask before creating a GitHub repo, pushing, or doing anything that publishes or costs money.

## Stack
- Native SwiftUI, iOS 18+, Swift Observation (`@Observable`).
- Chess rules and PGN parsing: ChessKit (https://github.com/chesskit-app/chesskit-swift), via Swift Package Manager.
- All data stays on the device. No accounts, no server.
- Stockfish runs on the phone via ChessKitEngine (https://github.com/chesskit-app/chesskit-engine), Swift Package Manager.
  Its two neural-network files (~78 MB) are not in git: run `sh scripts/download-stockfish-nets.sh` once after cloning (they live in `ChessApp/Engine/`).

## License
GPLv3 (see LICENSE). This is required because Stockfish is GPLv3, so the app will be open source.
Any added dependency must be GPLv3-compatible.

## Project layout
- `ChessApp.xcodeproj` — open this in Xcode. Files in `ChessApp/` are picked up automatically
  (synchronized folder), so new Swift files don't need to be added to the project by hand.
- `ChessApp/ChessAppApp.swift` — app entry point.
- `ChessApp/HomeView.swift` — first screen: username box, recent games list, paste/sample options.
- `ChessApp/GameFetcher.swift` — downloads the newest rated games of one speed from the Chess.com and Lichess public APIs, and looks up which speeds a player uses.
- `ChessApp/TimeControl.swift` — the speed groups (Bullet, Blitz, Rapid, Classical, Daily) and how each site's labels map onto them.
- `ChessApp/GameSummary.swift` — one game in the list (opponent, result, date, time control, PGN).
- `ChessApp/PGNReader.swift` — turns PGN text into board positions (see "ChessKit quirks").
- `ChessApp/GameViewerView.swift` / `GameViewerModel.swift` — board screen and step buttons.
- `ChessApp/ChessBoardView.swift` — draws the board and pieces.
- `ChessApp/Analysis/` — Stockfish analysis: `StockfishEvaluator` (talks to the engine), `AnalysisCenter` (queue, progress, results), `GameAnalysis` (scores, mistake/blunder rules: 1+ pawn lost = mistake, 2+ = blunder).
- `ChessApp/Leaks/` — Step 4 report: `LeakReport.swift` (finds the player's recurring mistakes in analysed games, ranks by total cost; unlocks at 10 analysed games) and `LeakReportView.swift` (the cards, with examples that open on the board).
- `ChessApp/Drills/` — Steps 5 and 8 (drill upgrade: forgiving wrong moves, hint, replays, explore mode, results list; `DrillExplainer.swift` holds the one-line explanation templates; outcomes are logged by `DrillHistory` in `drill-history.json` for spaced repetition): `DrillModels.swift` (puzzle loader, drill stats saved on the phone), `DrillSessionModel.swift` (10-question sessions mixing the player's own mistakes with puzzles), `DrillSessionView.swift`.
- `ChessApp/Puzzles/puzzles.csv` — ~6,000 puzzles rated 1000-2000 trimmed from the free Lichess puzzle database (https://database.lichess.org, CC0 / public domain). Columns as in the original CSV.
- `ChessApp/EvalBarView.swift` — the eval bar next to the board.
- `scripts/download-stockfish-nets.sh` — fetches the Stockfish network files.
- `ChessApp/PastePGNView.swift` — backup option: paste a PGN.
- `ChessApp/SampleGames.swift` — hard-coded sample PGN.

## ChessKit quirks (as of 0.17.0)
Don't use `Game(pgn:)` or `Move(san:)` to load games. They fail on en passant captures and ignore
disambiguation on captures (e.g. "Rexe3"). `PGNReader` resolves moves itself via `Board.legalMoves`
and plays them on a `Board`. It was checked against 531 real Chess.com games (final positions matched).

## APIs (free, no login)
- Chess.com: `api.chess.com/pub/player/{user}/games/archives`, then the newest monthly archives.
- Lichess: `lichess.org/api/games/user/{user}?max=20&pgnInJson=true`, Accept `application/x-ndjson`.
  Lichess allows only one request at a time per IP; a 429 means wait a minute.

## Run in Release
The shared Run scheme (`ChessApp.xcodeproj/xcshareddata/xcschemes/ChessApp.xcscheme`) uses the Release configuration on purpose. In Debug, Stockfish's C++ is compiled with no optimisation and analysis is many times slower on a phone. The game screen shows "Analysed in N s" so speed can be checked.

## Checking that it builds
```
xcodebuild -project ChessApp.xcodeproj -scheme ChessApp -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Progress
- [x] Step 1: board screen that steps through one hard-coded sample game.
- [x] Step 2: enter a Chess.com/Lichess username, list recent games, open one on the board. Paste PGN as a fallback.
- [x] Step 3: on-device Stockfish analysis: eval bar, mistake/blunder labels with the best move, background analysis of the last 20 games with per-game counts. Confirmed on iPhone 14 (20 games, 7-39 s each). Analysis starts automatically after games load, with Stop/Resume; results are saved on the phone.
- [x] Step 4: "top 3 leaks" report (hanging pieces, missed tactics, not converting wins, middlegame drift, time trouble). Needs 10 analysed games. Tested in the Simulator with real games.
- [x] Step 5: "Drill this leak" on each leak card: 10-question sessions mixing the player's own mistakes (accepts Stockfish's best move or anything within 0.3 pawns; shows the line after 2 wrong tries) with matching Lichess puzzles. Right/wrong per leak saved on the phone. Tested in the Simulator; not yet checked on the iPhone.
- [x] Step 6 (partly): time-control picker. Only speeds the player has rated games in are shown (from each site's stats), the most recent choice is remembered, and the newest 20 RATED games of that speed are fetched (Chess.com: walks back up to 12 months; Lichess: filtered by the API). "Load 20 more" fetches the next 20. Leak report, drills and puzzle rating follow the chosen speed; time-trouble leak is skipped for Daily. Tested in the Simulator on both sites.
- Starting speed: a speed the player has picked themselves wins; otherwise the speed with the most rated games in the last 3 months; otherwise their all-time most-played.
- Decided NOT to build: "Just for fun" speed toggle, "Not a real game" option, game tags, an all-vs-serious toggle, outlier prompts.
- Later ideas: side-by-side "top leak by speed" card (never a blended report), cross-speed tilt signal, spaced repetition + Today screen, progress by games (not dates).
- [x] Step 7: leak accuracy. Missed tactics now come from Stockfish's best line (not the first move), labelled Fork / Pin / Checkmate / Other; missed mates (mate in 1-3) use the uncapped mate score. New leaks: "Not punishing your opponent's blunders" and "Rushing your moves". Old saved analyses lack Stockfish's lines and are redone automatically.

## Leak thresholds (first guesses, tune with real players)
All live in `ChessApp/Leaks/LeakReport.swift` unless noted. Mistake = lose 1+ pawn, blunder = lose 2+ (`GameAnalysis.swift`). Scores are capped at +/-5 pawns except mates.
- Hanging pieces: a blunder AND material down 2+ points within the next move or two.
- Missed tactics: lost 1.5+ pawns AND Stockfish's best line wins 2+ points of material within 4 plies (judged after the opponent's reply). Type: Fork = the moved piece attacks 2+ non-pawn enemies and none of equal or lower value can take it; Pin = bishop/rook/queen with a more valuable piece (or king) directly behind; otherwise Other (`TacticFinder.swift`). Missed mate = Stockfish had mate in <= 3 and the move played gave it up (counts as 3 pawns of cost).
- Not converting: peaked at +2 or better and didn't win. Drift: moves 15-30, no single mistake, small losses add up to 1+ pawn and the position slides 1.5+ pawns.
- Time trouble: error with clock under max(8 s, 12% of the starting time). Rushed: mistake played in under 2.5 s with more than 30% of the starting time left (increments counted). Both skipped for Daily or without clock data.
- Not punishing: opponent's move gave away 2+ pawns and your reply lost 1+ pawn and more than half of that gain.
- One move lands on one card: hanging pieces > missed tactics with a named type (checkmate/fork/pin) > not punishing > missed tactics labelled other. Time trouble, rushing, drift and converting can still overlap with these.
- A leak needs 2+ games to show; the top 3 by total cost are shown. Rushing drills lock the board for 5 s (`DrillSessionModel.rushPauseSeconds`).
- [x] Step 8: drill upgrade. First wrong move snaps back ("Not quite, try again"), second reveals the solution with an arrow that stays; Hint button; each question ends as pass / hinted / second-try / revealed and is saved (`DrillHistory`, for spaced repetition in step 9); "Why your move fails" / "Why the best move works" replays (max 3 moves) plus a one-line template explanation (no AI); back button and swipe between questions (forward only after a result); results list with ticks and crosses where each drill reopens; Explore mode with eval bar and Reset. Rushing 5 s lock and mate-only rule kept.
- Step 8 fix round (from the owner's iPhone screenshots and screen recording): after a reveal or any replay the board returns to the starting position with one arrow on the best move; "The solution" line shows the player's moves in bold and the opponent's in grey; the convert drill/examples only use moments where the player was +2 or better before the slip (and the sentence names the real sign, the opponent's best reply and the swing); puzzle sentences describe what the solution really does (fork/pin only when the puzzle is tagged that way and the board agrees) or are left out; short navigation titles (`LeakKind.shortTitle`); castling shown as O-O / O-O-O; time-trouble and rushing questions say how much clock was left; one drill session never has two questions with the same answer from the same game.
- Known: the "pawns per game" figure on a card is the SUM of the evaluation swings of every mistake counted for that leak in a game (a single mistake can be up to 10 because scores are capped at +/-5), not material. Left as is; consider rewording.

