import SwiftUI

/// A drill session: a board you tap to answer, short feedback, then a results screen.
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
            } else if model.isFinished {
                resultsView
            } else {
                questionView
            }
        }
        .navigationTitle(leak.kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Question

    private var questionView: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(model.index), total: Double(model.questions.count))
            HStack {
                Text("Question \(model.index + 1) of \(model.questions.count)").font(.caption.weight(.semibold))
                Spacer()
                Text(model.sourceName).font(.caption).foregroundStyle(.secondary)
            }

            Text(model.prompt)
                .font(.subheadline)
                .multilineTextAlignment(.center)

            ChessBoardView(position: model.board.position,
                           flipped: model.flipped,
                           selected: model.selected,
                           highlights: model.highlights,
                           onTap: { model.handleTap($0) })

            VStack(spacing: 4) {
                Text(model.message)
                    .font(.headline)
                    .foregroundStyle(feedbackColor)
                    .multilineTextAlignment(.center)
                if let line = model.answerText {
                    Text(line).font(.subheadline.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(minHeight: 60)

            if model.phase == .solved || model.phase == .revealed {
                Button(model.index + 1 == model.questions.count ? "See my results" : "Next question") { model.next() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("I give up, show me") { model.reveal() }
                    .font(.footnote)
                    .disabled(model.phase == .thinking)
            }
            Spacer(minLength: 0)
        }
        .padding()
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
            VStack(spacing: 16) {
                Text("\(model.score) / \(model.questions.count)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text(summaryLine).font(.headline).multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { _, result in
                        Image(systemName: result == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result == true ? .green : .red)
                    }
                }

                let total = DrillStats.score(for: leak.kind)
                Text("All-time for this leak: \(total.right) right, \(total.wrong) wrong")
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
