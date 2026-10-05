import SwiftUI

/// The "top 3 leaks" report: what keeps costing you points, with examples you can open on the board.
struct LeakReportView: View {
    let report: LeakReport
    @State private var path: [LoadedGameRoute] = []
    @State private var drilling: Leak?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Based on your last \(report.gamesAnalysed) \(report.speed?.sentenceName ?? "") games. Only your own moves are counted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if report.leaks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                            Text("No repeating leaks found").font(.headline)
                            Text("Nothing went wrong in the same way twice in these games. Play more games and check again.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }

                    ForEach(Array(report.leaks.enumerated()), id: \.element.id) { index, leak in
                        LeakCard(rank: index + 1, leak: leak, open: { example in
                            path.append(LoadedGameRoute(game: example.game, startIndex: example.ply))
                        }, drill: { drilling = leak })
                    }
                }
                .padding()
            }
            .navigationTitle("Your top leaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(item: $drilling) { leak in
                DrillSessionView(leak: leak, playerRating: report.playerRating)
            }
            .navigationDestination(for: LoadedGameRoute.self) { route in
                GameViewerView(game: route.game, startIndex: route.startIndex)
            }
        }
    }
}

private struct LeakCard: View {
    let rank: Int
    let leak: Leak
    let open: (LeakExample) -> Void
    let drill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: leak.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(rank)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(leak.title).font(.headline)
                }
            }

            if let breakdown = leak.breakdown {
                Text(breakdown).font(.subheadline.weight(.semibold))
            }

            Text("Happens in \(leak.gamesAffected) of \(leak.gamesChecked) games · costs about \(leak.pawnsPerGame) pawns per game")
                .font(.subheadline.weight(.semibold))

            Text(leak.kind.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("See it in your games")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            ForEach(leak.examples) { example in
                Button { open(example) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(example.moveText) — \(example.detail)").font(.subheadline)
                            Text(example.gameLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            let score = DrillStats.score(for: leak.kind)
            Button(action: drill) {
                Label("Drill this leak", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            if score.right + score.wrong > 0 {
                Text("Practised so far: \(score.right) right, \(score.wrong) wrong")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.25)))
    }
}
