import SwiftUI

/// Shows one game: player names, the board with an eval bar, the current move and step buttons.
/// Stockfish analyses the game automatically when it opens.
struct GameViewerView: View {
    @State private var model: GameViewerModel
    private let analysisCenter = AnalysisCenter.shared

    init(game: LoadedGame, startIndex: Int = 0) {
        let model = GameViewerModel(game: game)
        model.currentIndex = min(max(startIndex, 0), model.moveCount)
        _model = State(initialValue: model)
    }

    private var analysis: GameAnalysis? { analysisCenter.analysis(forPGN: model.game.pgn) }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                playerLine(name: model.black, isWhite: false)
                Text("vs").font(.caption).foregroundStyle(.secondary)
                playerLine(name: model.white, isWhite: true)
            }

            HStack(spacing: 8) {
                EvalBarView(evaluation: analysis?.evals[model.currentIndex])
                ChessBoardView(position: model.currentPosition)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)

            moveInfo

            HStack(spacing: 32) {
                Button(action: model.goToStart) { Image(systemName: "backward.end.fill") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("First move")
                Button(action: model.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("Previous move")
                Button(action: model.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel("Next move")
                Button(action: model.goToEnd) { Image(systemName: "forward.end.fill") }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel("Last move")
            }
            .font(.title)

            analysisStatus
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { analysisCenter.request(model.game, urgent: true) }
    }

    /// A player's name, plus their mistake and blunder count once analysis is done.
    private func playerLine(name: String, isWhite: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.headline)
            if let counts = analysis?.counts(forWhite: isWhite) {
                CountsBadge(counts: counts)
            }
        }
    }

    /// The current move, its score, and (for mistakes) the better move.
    private var moveInfo: some View {
        let judgement = analysis?.judgements[model.currentIndex]
        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(model.currentMoveName.isEmpty ? "Starting position" : model.currentMoveName + (judgement?.symbol ?? ""))
                    .font(.title2.monospaced())
                if let eval = analysis?.evals[model.currentIndex] {
                    Text(eval.text)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let judgement {
                let better = analysis?.betterMoves[model.currentIndex]
                Text(judgement.rawValue + (better.map { " — best was \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(judgement == .blunder ? .red : .orange)
            }
            Text("Move \(model.currentIndex) of \(model.moveCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.game.isComplete {
                Text("Some moves in this game couldn't be read, so it stops early.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var analysisStatus: some View {
        if analysis != nil {
            if let seconds = analysisCenter.seconds(forPGN: model.game.pgn) {
                Text("Analysed in \(Int(seconds.rounded())) s").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            if let progress = analysisCenter.progress(forPGN: model.game.pgn) {
                ProgressView(value: progress) {
                    Text("Stockfish is analysing… \(Int(progress * 100))%").font(.caption)
                }
            } else {
                Label("Waiting for Stockfish…", systemImage: "hourglass").font(.caption)
            }
        }
    }
}

/// Small coloured counts like "2?? 1?" shown next to a player's name.
struct CountsBadge: View {
    let counts: GameAnalysis.Counts

    var body: some View {
        HStack(spacing: 6) {
            if counts.blunders > 0 {
                Text("\(counts.blunders) blunder\(counts.blunders == 1 ? "" : "s")").foregroundStyle(.red)
            }
            if counts.mistakes > 0 {
                Text("\(counts.mistakes) mistake\(counts.mistakes == 1 ? "" : "s")").foregroundStyle(.orange)
            }
            if counts.blunders == 0 && counts.mistakes == 0 {
                Text("no mistakes").foregroundStyle(.green)
            }
        }
        .font(.caption.weight(.semibold))
    }
}

#Preview {
    NavigationStack {
        GameViewerView(game: PGNReader.read(SampleGames.operaGame)!)
    }
}
