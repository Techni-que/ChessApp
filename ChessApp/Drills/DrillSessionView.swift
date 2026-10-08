import SwiftUI

/// A drill session: a board you tap to answer, a hint if you need one, a short "why" afterwards,
/// swiping between questions, and a results list at the end.
struct DrillSessionView: View {
    @State private var model: DrillSessionModel
    @Environment(\.dismiss) private var dismiss
    private let leak: Leak
    private let rating: Int

    init(leak: Leak, playerRating: Int) {
        self.leak = leak
        rating = playerRating
        _model = State(initialValue: DrillSessionModel(leak: leak, playerRating: playerRating))
    }

    var body: some View {
        Group {
            if model.questions.isEmpty {
                emptyState
            } else if model.showSummary {
                resultsView
            } else {
                questionView
            }
        }
        .navigationTitle(leak.group.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Question

    private var questionView: some View {
        ScrollView {
            VStack(spacing: 12) {
                header

                Text(model.exploring ? "Explore: move any pieces. The bar shows who is better." : model.prompt)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    if model.exploring {
                        EvalBarView(evaluation: model.exploreEval)
                    }
                    ChessBoardView(position: model.board.position,
                                   flipped: model.flipped,
                                   selected: model.selected,
                                   highlights: model.highlights,
                                   marks: model.phase == .asking ? model.loosePicks : [],
                                   lastMove: model.lastMove,
                                   arrows: model.arrows,
                                   onTap: { model.handleTap($0) })
                }
                .fixedSize(horizontal: false, vertical: true)

                feedback
                controls
            }
            .padding()
        }
        // Swipe left for the next question (only once this one has a result) and right to go back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                if value.translation.width < -60 {
                    model.goForward()
                } else if value.translation.width > 60 {
                    model.goBack()
                }
            }
        )
    }

    private var header: some View {
        VStack(spacing: 6) {
            ProgressView(value: Double(model.outcomes.compactMap { $0 }.count), total: Double(model.questions.count))
            HStack {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("Previous question")
                Spacer()
                VStack(spacing: 1) {
                    Text("Question \(model.index + 1) of \(model.questions.count)").font(.caption.weight(.semibold))
                    Text(model.sourceName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel("Next question")
            }
            .font(.title3)
        }
    }

    private var feedback: some View {
        VStack(spacing: 6) {
            Text(model.pauseLeft > 0 ? "Wait \(model.pauseLeft)… Look at every check, capture and threat first." : model.message)
                .font(.headline)
                .foregroundStyle(model.pauseLeft > 0 ? Color.secondary : feedbackColor)
                .multilineTextAlignment(.center)
            if let sentence = model.explanation, !model.exploring {
                Text(sentence)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            if let title = model.replayTitle, !model.exploring {
                VStack(spacing: 2) {
                    Text(title + (model.isReplaying && model.replayMoves.isEmpty ? "…" : ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !model.replayMoves.isEmpty {
                        movesText(model.replayMoves)
                            .font(.subheadline.monospaced())
                        Text("Bold: your moves · Grey: opponent's replies")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(minHeight: 50)
    }

    @ViewBuilder
    private var controls: some View {
        if model.exploring {
            HStack(spacing: 12) {
                Button("Reset") { model.resetExplore() }
                    .buttonStyle(.bordered)
                Button("Done exploring") { model.stopExploring() }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.phase == .asking || model.phase == .thinking {
            VStack(spacing: 12) {
                if model.mode == .looseCheck {
                    Button("Check") { model.checkLoose() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.loosePicks.isEmpty || model.phase != .asking || model.pauseLeft > 0)
                }
                HStack(spacing: 16) {
                    Button { model.hint() } label: { Label("Hint", systemImage: "lightbulb") }
                        .buttonStyle(.bordered)
                        .disabled(!model.canHint || model.hintUsed)
                    Button("I give up, show me") { model.reveal() }
                        .font(.footnote)
                        .disabled(model.phase == .thinking || model.pauseLeft > 0)
                }
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if model.canExplainFailure {
                        Button("Why your move fails") { model.replayFailure() }
                            .buttonStyle(.bordered)
                    }
                    Button("Why the best move works") { model.replayBestMove() }
                        .buttonStyle(.bordered)
                }
                .font(.footnote)
                .disabled(model.isReplaying)

                HStack(spacing: 10) {
                    Button { model.startExploring() } label: { Label("Explore", systemImage: "hand.point.up.left") }
                        .buttonStyle(.bordered)
                    if model.canGoForward {
                        Button(model.index + 1 == model.questions.count ? "See my results" : "Next question") { model.goForward() }
                            .buttonStyle(.borderedProminent)
                    }
                    if model.phase == .reviewing && model.allAnswered {
                        Button("Back to results") { model.showResults() }
                    }
                }
            }
        }
    }

    /// Your moves in bold, the opponent's replies in grey.
    private func movesText(_ moves: [DrillSessionModel.ReplayMove]) -> Text {
        var result = Text("")
        for (index, move) in moves.enumerated() {
            if index > 0 { result = result + Text("  ") }
            result = result + (move.mine ? Text(move.san).bold() : Text(move.san).foregroundStyle(.secondary))
        }
        return result
    }

    private var feedbackColor: Color {
        switch model.phase {
        case .solved: .green
        case .revealed: .orange
        default: .primary
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("\(model.score) / \(model.questions.count)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text("\(model.firstTryCount) first try").font(.subheadline).foregroundStyle(.secondary)
                Text(summaryLine).font(.headline).multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    ForEach(Array(model.questions.enumerated()), id: \.element.id) { index, question in
                        Button { model.open(index) } label: {
                            resultRow(index: index, question: question)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("All-time: " + DrillStats.score(for: leak.group.rawValue).summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    Button("Drill this leak again") {
                        model = DrillSessionModel(leak: leak, playerRating: rating)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Back to my leaks") { dismiss() }
                }
            }
            .padding()
        }
    }

    private func resultRow(index: Int, question: DrillQuestion) -> some View {
        let outcome = model.outcomes[index]
        return HStack(spacing: 10) {
            Image(systemName: outcome?.solved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(outcome?.solved == true ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1). \(model.name(of: question))")
                    .font(.subheadline.weight(.semibold))
                Text(model.summary(of: question)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(outcome?.label ?? "").font(.caption).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var summaryLine: String {
        switch model.score * 10 / max(model.questions.count, 1) {
        case 9...: "Excellent. This leak is closing."
        case 6...: "Good work. A bit more practice and it will stick."
        default: "This is a tough one. That's why we're practising it."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing to drill yet").font(.headline)
            Text("This leak doesn't have positions from your games to practise. Play and analyse a few more games.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}
