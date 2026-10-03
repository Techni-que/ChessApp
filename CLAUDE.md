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
- Stockfish will be bundled later for analysis.

## License
GPLv3 (see LICENSE). This is required because Stockfish is GPLv3, so the app will be open source.
Any added dependency must be GPLv3-compatible.

## Project layout
- `ChessApp.xcodeproj` — open this in Xcode. Files in `ChessApp/` are picked up automatically
  (synchronized folder), so new Swift files don't need to be added to the project by hand.
- `ChessApp/ChessAppApp.swift` — app entry point.
- `ChessApp/GameViewerView.swift` — main screen (board + step buttons).
- `ChessApp/GameViewerModel.swift` — loads a PGN and tracks the current move.
- `ChessApp/ChessBoardView.swift` — draws the board and pieces.
- `ChessApp/SampleGames.swift` — hard-coded sample PGN.

## Checking that it builds
```
xcodebuild -project ChessApp.xcodeproj -scheme ChessApp -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Progress
- [x] Step 1: board screen that steps through one hard-coded sample game.
