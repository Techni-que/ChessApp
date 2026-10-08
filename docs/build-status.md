# Chess app: build status

**Start here.** Read this file before any build step, alongside CLAUDE.md for the code. Update it at the end of every step (what's built, what's next, any new decision with a line of why).

Copied from the planning project's `plans/build-status.md` on 7 Oct 2026. The plan files named below (planning-decisions-*.md, mvp-spec.md, aimchess-fixes-plan.md) live in that project, not in this repo.

## Built and tested on the iPhone 14

1. Chessboard (ChessKit).
2. Chess.com username import and game list.
3. On-device Stockfish: eval bar, ?/?? marks, automatic background analysis with Stop (7-39 s per game, cached).
4. Leak report: top leaks, tap an example to jump to the move. Unlocks after 10 games; a leak shows only if it's in 2+ games.
5. Drills per leak: own-mistake positions plus Lichess CC0 puzzles (rated ~1000-2000).
6. Time-control picker: latest 20 rated games per speed, "Load 20 more", default = most-played speed in the last 3 months.
7. Rule-based leaks, no AI: hanging pieces, missed tactics, not punishing blunders, failing to convert, middlegame drift, time trouble, rushing (<2.5 s with >30% clock). Thresholds are in CLAUDE.md.
8. Drill upgrade: one retry, hint, "why" replays, Back/swipe, session summary, explore mode. Fix round (arrow on best move, converting only from +2, real +/- signs, clock on time-trouble questions, no repeat answers, O-O-O) confirmed 7 Oct.

## In progress: step 9, a drill format per leak group

- **Part 1 (pushed 7 Oct, waiting on the user's iPhone test):** report regrouped into group cards; Tactics drills "What's loose?" and "What did they just leave?" (can be "nothing"); same-pattern puzzle blocks from 9,017 puzzles (1.3 MB). Caveat: "What's loose?" rarely appears.
- **Part 2:** Advantage capitalisation, playing on from own +2 positions against Stockfish, graded on keeping the lead. Don't start until the user confirms part 1 on the phone and OKs part 2.
- **Part 3:** Time management. Time trouble = speed rounds on a real countdown, no retry. Rushing = "trap" positions where the obvious move fails, plus a minimum think time.
- **Part 4:** Strategy, after a no-UI Strategy experiment on real games.

## Crash fix (7 Oct, confirmed on the iPhone)

- Crashes on the phone (CrashBug2-5, all identical) were Stockfish aborting on a bad FEN: ChessKit keeps castling rights after the rook is captured on its home square. `StockfishEvaluator.engineSafeFEN` now keeps a castling letter only when the king and rook are really at home.
- Also fixed: the checkmate/stalemate shortcut before asking Stockfish was dead (ChessKit's `toggleSideToMove()` is a no-op).
- Faster analysis (confirmed on the iPhone: about 12 s per game, was 7-39 s): quick pass runs last move to first, Stockfish memory table 16 -> 64 MB, first 12 plies get a lighter look (depth 10, 80 ms). The game screen also shows seconds per move. Not done yet: skip the deep re-check when a game is already decided (scores are capped at +/-5).
- Lag: a cpu_resource report showed 99% CPU for 91 s, all in Stockfish's search (4 threads on an iPhone 14 with 2 fast cores). Fewer engine threads is proposed, not done.

## Build order after step 9

Spaced repetition + Today screen > progress > tilt > UI polish (skill map, style guide) > paywall (RevenueCat) > TestFlight. Marketing (YouTube Shorts) starts only after the app is complete.

## Decisions in force (and why)

- **Group cards: Tactics, Advantage capitalisation, Time management, Strategy** (Opening, Endgame later). Why: the user's layout; groups give the report structure, while the specific habits inside each card still drive the drills.
- **"Not punishing blunders" split by cause.** Needed a tactic -> Tactics, shown as a count "after your opponent's mistake". Was +1.5 or better and gave it back with no tactic -> Advantage capitalisation (becomes a vs-Stockfish start position). Why: no double counting, nothing falls through the gap.
- **Tactic labels:** hanging pieces, checkmate, fork, pin, skewer, discovery, other. Measured match vs Lichess tags: fork 58%, skewer 64%, pin 70%, discovery 81%. **Sacrifice left out** (35%). Why: good enough to group mistakes but never guess; use "other" when unsure.
- **Cost unit stays "pawns".** Why: user's call, it's the standard eval unit. Note it's a sum of swings capped at +/-5, so one +5 to -5 blunder counts as 10.
- **Strategy v1:** middlegame drift (name kept, since it measures small losses in quiet positions, not coordination), pawn structure (own pawn move making doubled/isolated/backward pawns, then eval drop), unused pieces, king safety. Passive play deferred until the rule is checked on real games. Why: only add what can be detected honestly.
- **Strategy drill = pick 1 of 3 candidates, multistep (2-3 rounds), with a ~0.7 pawn gap between candidates.** Why: with smaller gaps our quick analysis can't honestly say which move is best.
- **Every stat stays within its own time control, rated games only, every game counts.** Why: casual bullet would skew rapid; consistency is part of improving.
- **Progress by game blocks** (last 10-20 vs previous), rates not totals, "early signal" labels, split "In your games" / "In practice".
- **No AI explanations, template "why" lines only; no full generic 1200-2000 roadmap in v1.** Why: accuracy and cost.
- **Open source (GPL)** so Stockfish can run on the phone; subscriptions still allowed.

## Open questions

- Whether to cut "Paste a game" and turn the sample game into a demo profile (helps App Review).
- Opening mistakes and endgame leaks: rules not designed yet.
- Spaced repetition defaults proposed: own mistakes first with puzzles as filler, extra drill on days with nothing due, reminder off by default.

## How to work

- Public repo: github.com/Techni-que/ChessApp. Push after each finished, tested step (standing OK).
- Free Personal Team signing: the app expires every 7 days, press Run to reinstall.
- Use Sonnet 5.5 for coding unless the user says otherwise.
- One session editing this folder at a time.
- One session per build step: build, Simulator-test, user tests on iPhone, push, update this file.
- The user batches feedback after testing in one message, and wants short, human replies and pushback when Claude disagrees.
