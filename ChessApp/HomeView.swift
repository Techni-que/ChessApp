import SwiftUI

/// The first screen: type a Chess.com or Lichess username to see that player's recent games.
struct HomeView: View {
    // Remembered between app launches, so you don't have to retype your username.
    @AppStorage("username") private var username = ""
    @AppStorage("site") private var site = ChessSite.chessCom

    @State private var games: [GameSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingPaste = false
    @State private var path: [LoadedGameRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Site", selection: $site) {
                        ForEach(ChessSite.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    TextField("Your \(site.rawValue) username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(findGames)

                    Button(action: findGames) {
                        HStack {
                            Text("Find my games")
                            if isLoading {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                if !games.isEmpty {
                    Section("Recent games") {
                        ForEach(games) { game in
                            Button { open(pgn: game.pgn) } label: {
                                GameRow(game: game)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section {
                    Button("Paste a game (PGN) instead") { showingPaste = true }
                    Button("Open a sample game") { open(pgn: SampleGames.operaGame) }
                }
            }
            .navigationTitle("ChessApp")
            .navigationDestination(for: LoadedGameRoute.self) { route in
                GameViewerView(game: route.game)
            }
            .sheet(isPresented: $showingPaste) {
                PastePGNView { pgn in open(pgn: pgn) }
            }
            .onChange(of: site) {
                games = []
                errorMessage = nil
            }
        }
    }

    private func findGames() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                games = try await GameFetcher.recentGames(for: name, on: site)
            } catch {
                games = []
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func open(pgn: String) {
        guard let game = PGNReader.read(pgn) else {
            errorMessage = "That game couldn't be read."
            return
        }
        path.append(LoadedGameRoute(game: game))
    }
}

/// One line in the games list, e.g. "Won vs Magnus · Blitz · 3+2 · 2 Oct".
private struct GameRow: View {
    let game: GameSummary

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(game.playedWhite ? Color.white : Color.black)
                .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                .frame(width: 14, height: 14)
                .accessibilityLabel(game.playedWhite ? "Played white" : "Played black")
            VStack(alignment: .leading, spacing: 2) {
                Text("vs \(game.opponent)").font(.body.weight(.medium))
                Text("\(game.timeControl) · \(game.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(game.outcome.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color(for: game.outcome))
        }
    }

    private func color(for outcome: GameSummary.Outcome) -> Color {
        switch outcome {
        case .win: .green
        case .loss: .red
        case .draw: .secondary
        }
    }
}

/// Wraps a loaded game so it can be pushed onto the navigation stack.
struct LoadedGameRoute: Hashable {
    let id = UUID()
    let game: LoadedGame

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    HomeView()
}
