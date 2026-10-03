import Foundation

/// Downloads a player's recent games from Chess.com or Lichess using their free public APIs.
/// No account or password is needed: game histories on both sites are public.
enum GameFetcher {
    enum FetchError: LocalizedError {
        case playerNotFound(String)
        case busy
        case noGames
        case network

        var errorDescription: String? {
            switch self {
            case .playerNotFound(let name): "Couldn't find a player called \"\(name)\". Check the spelling and the site."
            case .busy: "The site is busy right now. Wait a minute and try again."
            case .noGames: "No recent standard chess games found for this player."
            case .network: "Couldn't connect. Check your internet connection and try again."
            }
        }
    }

    /// How many games to show.
    static let maxGames = 20

    static func recentGames(for username: String, on site: ChessSite) async throws -> [GameSummary] {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let games = switch site {
        case .chessCom: try await chessComGames(for: name)
        case .lichess: try await lichessGames(for: name)
        }
        guard !games.isEmpty else { throw FetchError.noGames }
        return games
    }

    // MARK: Chess.com

    /// Chess.com groups games by month. We read the list of months,
    /// then load the newest months until we have enough games.
    private static func chessComGames(for username: String) async throws -> [GameSummary] {
        let user = username.lowercased()
        guard let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let archivesURL = URL(string: "https://api.chess.com/pub/player/\(encoded)/games/archives")
        else { throw FetchError.playerNotFound(username) }

        let archives = try await get(ChessComArchives.self, from: archivesURL, username: username)

        var games: [GameSummary] = []
        for monthURL in archives.archives.reversed().prefix(3) {
            guard let url = URL(string: monthURL) else { continue }
            let month = try await get(ChessComMonth.self, from: url, username: username)
            games += month.games
                .filter { $0.rules == "chess" && $0.pgn != nil }
                .compactMap { $0.summary(for: user) }
            if games.count >= maxGames { break }
        }
        return Array(games.sorted { $0.date > $1.date }.prefix(maxGames))
    }

    private struct ChessComArchives: Decodable {
        let archives: [String]
    }

    private struct ChessComMonth: Decodable {
        let games: [ChessComGame]
    }

    private struct ChessComGame: Decodable {
        struct Player: Decodable {
            let username: String
            let result: String
        }
        let url: String
        let pgn: String?
        let time_control: String
        let time_class: String
        let end_time: TimeInterval
        let rules: String
        let white: Player
        let black: Player

        func summary(for user: String) -> GameSummary? {
            guard let pgn else { return nil }
            let playedWhite = white.username.lowercased() == user
            let me = playedWhite ? white : black
            let opponent = playedWhite ? black : white
            let draws: Set<String> = ["agreed", "repetition", "stalemate", "insufficient", "50move", "timevsinsufficient"]
            let outcome: GameSummary.Outcome = me.result == "win" ? .win : draws.contains(me.result) ? .draw : .loss

            // time_control looks like "180", "180+2", or "1/86400" for daily games.
            let parts = time_control.split(separator: "+").map { Int($0) }
            let isDaily = time_control.contains("/")
            let timeControl = TimeControlText.make(
                speed: time_class,
                initialSeconds: isDaily ? nil : parts.first ?? nil,
                incrementSeconds: parts.count > 1 ? parts[1] : nil
            )
            return GameSummary(
                id: url,
                opponent: opponent.username,
                playedWhite: playedWhite,
                outcome: outcome,
                date: Date(timeIntervalSince1970: end_time),
                timeControl: timeControl,
                pgn: pgn
            )
        }
    }

    // MARK: Lichess

    /// Lichess sends one game per line (a format called NDJSON).
    private static func lichessGames(for username: String) async throws -> [GameSummary] {
        guard let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://lichess.org/api/games/user/\(encoded)?max=\(maxGames)&pgnInJson=true&clocks=true")
        else { throw FetchError.playerNotFound(username) }

        var request = URLRequest(url: url)
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let data = try await send(request, username: username)

        let user = username.lowercased()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(LichessGame.self, from: Data($0.utf8)) }
            .filter { $0.variant == "standard" || $0.variant == "fromPosition" }
            .compactMap { $0.summary(for: user) }
    }

    private struct LichessGame: Decodable {
        struct Players: Decodable {
            let white: Player
            let black: Player
        }
        struct Player: Decodable {
            struct User: Decodable { let name: String }
            let user: User?
            let aiLevel: Int?

            var displayName: String {
                if let user { return user.name }
                if let aiLevel { return "Stockfish level \(aiLevel)" }
                return "Anonymous"
            }
        }
        struct Clock: Decodable {
            let initial: Int
            let increment: Int
        }
        let id: String
        let variant: String
        let speed: String
        let createdAt: TimeInterval
        let players: Players
        let winner: String?
        let clock: Clock?
        let pgn: String?

        func summary(for user: String) -> GameSummary? {
            guard let pgn else { return nil }
            let playedWhite = players.white.user?.name.lowercased() == user
            let outcome: GameSummary.Outcome = switch winner {
            case nil: .draw
            case "white": playedWhite ? .win : .loss
            default: playedWhite ? .loss : .win
            }
            return GameSummary(
                id: id,
                opponent: (playedWhite ? players.black : players.white).displayName,
                playedWhite: playedWhite,
                outcome: outcome,
                date: Date(timeIntervalSince1970: createdAt / 1000),
                timeControl: TimeControlText.make(speed: speed, initialSeconds: clock?.initial, incrementSeconds: clock?.increment),
                pgn: pgn
            )
        }
    }

    // MARK: Networking

    private static func get<T: Decodable>(_ type: T.Type, from url: URL, username: String) async throws -> T {
        let data = try await send(URLRequest(url: url), username: username)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FetchError.noGames
        }
    }

    private static func send(_ request: URLRequest, username: String) async throws -> Data {
        var request = request
        request.setValue("ChessApp/0.1 (open-source iOS app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.network
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 404, 410: throw FetchError.playerNotFound(username)
        case 429: throw FetchError.busy
        default: throw FetchError.network
        }
    }
}
