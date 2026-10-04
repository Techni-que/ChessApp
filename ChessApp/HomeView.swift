import SwiftUI

/// The first screen: type a Chess.com or Lichess username to see that player's recent games.
struct HomeView: View {
    // Remembered between app launches, so you don't have to retype your username.
    @AppStorage("username") private var username = ""
    @AppStorage("site") private var site = ChessSite.chessCom
    // The time control being looked at (remembered between launches).
    @AppStorage("speed") private var speed = TimeControl.blitz

    @State private var games: [GameSummary] = []
    /// How many games the player has at each speed (decides which speeds are offered).
    @State private var speedCounts: [TimeControl: Int] = [:]
    /// How many games we've asked for so far (20, then 40 after "Load 20 more", ...).
    @State private var gameLimit = GameFetcher.pageSize
    /// Bumped on every new request so a slow, outdated answer can't overwrite a newer one.
    @State private var requestID = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingPaste = false
    @State private var leakReport: LeakReport?
    @State private var path: [LoadedGameRoute] = []
    private let analysisCenter = AnalysisCenter.shared

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

                if availableSpeeds.count > 1 {
                    Section {
                        Picker("Time control", selection: $speed) {
                            ForEach(availableSpeeds) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Time control")
                    } footer: {
                        Text("Your mistakes are different in different speeds, so each one gets its own report.")
                    }
                }

                if !games.isEmpty {
                    Section {
                        analysisSummary
                        leakReportRow
                    } footer: {
                        Text("Your games are checked by Stockfish on your phone while the app is open. Tap a game to see its result.")
                    }

                    Section {
                        ForEach(games) { game in
                            Button { open(pgn: game.pgn) } label: {
                                GameRow(game: game)
                            }
                            .foregroundStyle(.primary)
                        }
                        if games.count >= gameLimit {
                            Button(action: loadMore) {
                                HStack {
                                    Text("Load \(GameFetcher.pageSize) more")
                                    if isLoading {
                                        Spacer()
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(isLoading)
                        }
                    } header: {
                        Text("Recent \(speed.sentenceName) games")
                    } footer: {
                        if games.count < gameLimit {
                            Text(shortfallText)
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
                GameViewerView(game: route.game, startIndex: route.startIndex)
            }
            .sheet(item: $leakReport) { LeakReportView(report: $0) }
            .sheet(isPresented: $showingPaste) {
                PastePGNView { pgn in open(pgn: pgn) }
            }
            .onChange(of: site) {
                games = []
                speedCounts = [:]
                errorMessage = nil
            }
            .onChange(of: speed) {
                // Picking a different speed loads that speed's newest games.
                guard !speedCounts.isEmpty else { return }
                gameLimit = GameFetcher.pageSize
                // Clear the old speed's list straight away so it isn't shown under the new heading.
                games = []
                loadGames()
            }
        }
    }

    /// Speeds the player has games in, in the usual order.
    private var availableSpeeds: [TimeControl] {
        TimeControl.allCases.filter { (speedCounts[$0] ?? 0) > 0 }
    }

    /// Tells the player when a speed has fewer games than we asked for.
    private var shortfallText: String {
        let months = site == .chessCom ? " in the last \(GameFetcher.maxMonths) months" : ""
        return "Only found \(games.count) rated \(speed.sentenceName) games\(months)."
    }

    /// Looks up which speeds the player uses, picks one, then loads its games.
    private func findGames() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        requestID += 1
        let thisRequest = requestID
        let chosenSite = site
        Task {
            do {
                let counts = try await GameFetcher.gameCounts(for: name, on: chosenSite)
                guard thisRequest == requestID else { return }
                guard !counts.isEmpty else { throw GameFetcher.FetchError.noGames }
                speedCounts = counts
                // Keep the remembered speed if they play it; otherwise their most-played one.
                if (counts[speed] ?? 0) == 0, let mostPlayed = counts.max(by: { $0.value < $1.value })?.key {
                    speed = mostPlayed
                }
                gameLimit = GameFetcher.pageSize
                isLoading = false
                loadGames()
            } catch {
                guard thisRequest == requestID else { return }
                games = []
                speedCounts = [:]
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// Loads the newest games of the chosen speed (up to `gameLimit`) and starts analysing them.
    private func loadGames() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        requestID += 1
        let thisRequest = requestID
        let chosenSite = site, chosenSpeed = speed, limit = gameLimit
        Task {
            do {
                let loaded = try await GameFetcher.recentGames(for: name, on: chosenSite, speed: chosenSpeed, limit: limit)
                guard thisRequest == requestID else { return }
                games = loaded
                // Games already analysed are remembered, so switching back and forth costs nothing.
                analysisCenter.clearWaiting()
                analyseAll()
            } catch {
                guard thisRequest == requestID else { return }
                games = []
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func loadMore() {
        gameLimit += GameFetcher.pageSize
        loadGames()
    }

    /// How many of the listed games are fully analysed, plus a Stop/Resume button.
    private var analysisSummary: some View {
        let done = games.filter { analysisCenter.analysis(forPGN: $0.pgn) != nil }.count
        return HStack {
            if done == games.count {
                Label("All \(games.count) games analysed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(analysisCenter.isPaused ? "Paused: \(done) of \(games.count) analysed" : "Analysing: \(done) of \(games.count) done",
                      systemImage: "cpu")
                Spacer()
                Button(analysisCenter.isPaused ? "Resume" : "Stop") {
                    if analysisCenter.isPaused {
                        analysisCenter.resume()
                    } else {
                        analysisCenter.pause()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Analysed games, paired with their summaries, in list order.
    private var analysedGames: [AnalysedGame] {
        games.compactMap { summary in
            guard let analysis = analysisCenter.analysis(forPGN: summary.pgn),
                  let game = PGNReader.read(summary.pgn) else { return nil }
            return AnalysedGame(summary: summary, game: game, analysis: analysis)
        }
    }

    /// Appears once enough games are analysed.
    @ViewBuilder
    private var leakReportRow: some View {
        let done = games.filter { analysisCenter.analysis(forPGN: $0.pgn) != nil }.count
        if done >= LeakDetector.minimumGames {
            Button {
                leakReport = LeakDetector.report(for: analysedGames)
            } label: {
                Label("See my top 3 leaks", systemImage: "chart.bar.doc.horizontal")
            }
        } else {
            Text(unlockText(done: done))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// What to say while the report is locked, and what's needed to unlock it.
    private func unlockText(done: Int) -> String {
        let name = speed.sentenceName
        if games.count < LeakDetector.minimumGames {
            // Not enough games exist yet, so analysing won't help; they need to play more.
            return "\(LeakDetector.minimumGames - games.count) more \(name) games to unlock your leaks. Play a few more and come back."
        }
        return "\(LeakDetector.minimumGames - done) more \(name) games to analyse to unlock your leaks."
    }

    private func analyseAll() {
        for summary in games {
            if let game = PGNReader.read(summary.pgn) {
                analysisCenter.request(game)
            }
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
    private let analysisCenter = AnalysisCenter.shared

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
                analysisLine
            }
            Spacer()
            Text(game.outcome.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color(for: game.outcome))
        }
    }

    /// Your own mistakes and blunders in this game, or analysis progress.
    @ViewBuilder
    private var analysisLine: some View {
        if let analysis = analysisCenter.analysis(forPGN: game.pgn) {
            CountsBadge(counts: analysis.counts(forWhite: game.playedWhite))
        } else if let progress = analysisCenter.progress(forPGN: game.pgn) {
            Text("Analysing… \(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
        } else if analysisCenter.isQueued(pgn: game.pgn) {
            Text("Waiting to analyse").font(.caption).foregroundStyle(.secondary)
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
    /// Which position to open on (0 = the starting position).
    var startIndex = 0

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    HomeView()
}
