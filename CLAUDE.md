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
- [x] Step 3: on-device Stockfish analysis: eval bar, mistake/blunder labels with the best move, "Analyse all 20 games" with per-game counts. Verified in the Simulator; awaiting check on the iPhone.
