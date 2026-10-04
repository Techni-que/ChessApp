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
- `ChessApp/GameFetcher.swift` — downloads recent games from the Chess.com and Lichess public APIs.
- `ChessApp/GameSummary.swift` — one game in the list (opponent, result, date, time control, PGN).
- `ChessApp/PGNReader.swift` — turns PGN text into board positions (see "ChessKit quirks").
- `ChessApp/GameViewerView.swift` / `GameViewerModel.swift` — board screen and step buttons.
- `ChessApp/ChessBoardView.swift` — draws the board and pieces.
- `ChessApp/Analysis/` — Stockfish analysis: `StockfishEvaluator` (talks to the engine), `AnalysisCenter` (queue, progress, results), `GameAnalysis` (scores, mistake/blunder rules: 1+ pawn lost = mistake, 2+ = blunder).
- `ChessApp/Leaks/` — Step 4 report: `LeakReport.swift` (finds the player's recurring mistakes in analysed games, ranks by total cost; unlocks at 10 analysed games) and `LeakReportView.swift` (the cards, with examples that open on the board).
- `ChessApp/Drills/` — Step 5: `DrillModels.swift` (puzzle loader, drill stats saved on the phone), `DrillSessionModel.swift` (10-question sessions mixing the player's own mistakes with puzzles), `DrillSessionView.swift`.
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
