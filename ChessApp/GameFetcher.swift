import Foundation

/// Downloads a player's recent games from Chess.com or Lichess using their free public APIs.
/// No account or password is needed: game histories on both sites are public.
enum GameFetcher {
    enum FetchError: LocalizedError {
        case playerNotFound(String)
        case busy
        case noGames
        case noGamesOfSpeed(TimeControl)
        case network

        var errorDescription: String? {
            switch self {
            case .playerNotFound(let name): "Couldn't find a player called \"\(name)\". Check the spelling and the site."
            case .busy: "The site is busy right now. Wait a minute and try again."
            case .noGames: "No recent standard chess games found for this player."
            case .noGamesOfSpeed(let speed): "No recent \(speed.sentenceName) games found for this player. Try another time control."
            case .network: "Couldn't connect. Check your internet connection and try again."
            }
        }
    }

    /// How many games to load at a time.
    static let pageSize = 20
    /// Chess.com only hands over games month by month, so we stop after this many months back.
    static let maxMonths = 12

    /// The newest rated games of one speed (for example blitz), newest first.
    /// If the player has fewer than `limit` games of that speed you simply get fewer back.
    static func recentGames(for username: String, on site: ChessSite, speed: TimeControl, limit: Int = pageSize) async throws -> [GameSummary] {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let games = switch site {
        case .chessCom: try await chessComGames(for: name, speed: speed, limit: limit)
        case .lichess: try await lichessGames(for: name, speed: speed, limit: limit)
        }
        guard !games.isEmpty else { throw FetchError.noGamesOfSpeed(speed) }
        return games
    }

    /// The speed a player has played most (rated games) in the last 3 months, or nil if they
    /// haven't played any in that time. Used to pick a sensible starting speed, so someone who
    /// moved from bullet to rapid isn't shown bullet just because they played more of it years ago.
    static func mostPlayedRecently(for username: String, on site: ChessSite) async -> TimeControl? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        var speeds: [TimeControl] = []
        switch site {
        case .chessCom:
            let user = name.lowercased()
            guard let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let archivesURL = URL(string: "https://api.chess.com/pub/player/\(encoded)/games/archives"),
                  let archives = try? await get(ChessComArchives.self, from: archivesURL, username: name) else { return nil }
            // Three months of archives cover the last 90 days.
            for monthURL in archives.archives.reversed().prefix(4) {
                guard let url = URL(string: monthURL),
                      let month = try? await get(ChessComMonth.self, from: url, username: name) else { continue }
                speeds += month.games
                    .filter { $0.rules == "chess" && $0.rated == true && Date(timeIntervalSince1970: $0.end_time) >= cutoff }
                    .compactMap { TimeControl.from(siteSpeed: $0.time_class) }
            }
        case .lichess:
            let sinceMilliseconds = Int(cutoff.timeIntervalSince1970 * 1000)
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://lichess.org/api/games/user/\(encoded)?since=\(sinceMilliseconds)&max=300&rated=true&moves=false") else { return nil }
            var request = URLRequest(url: url)
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            guard let data = try? await send(request, username: name) else { return nil }
            speeds = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { line -> TimeControl? in
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let speed = object["speed"] as? String else { return nil }
                    return TimeControl.from(siteSpeed: speed)
                }
        }
        let counts = Dictionary(grouping: speeds, by: { $0 }).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key
    }

    /// How many rated games a player has played at each speed, over their whole history.
    /// Used to show only the speeds they actually play, and to pick the most-played one.
    static func gameCounts(for username: String, on site: ChessSite) async throws -> [TimeControl: Int] {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        switch site {
        case .chessCom: return try await chessComCounts(for: name)
        case .lichess: return try await lichessCounts(for: name)
        }
    }

    // MARK: Chess.com

    /// Chess.com groups games by month. We read the list of months,
    /// then load the newest months until we have enough games.
    private static func chessComGames(for username: String, speed: TimeControl, limit: Int) async throws -> [GameSummary] {
        let user = username.lowercased()
        guard let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let archivesURL = URL(string: "https://api.chess.com/pub/player/\(encoded)/games/archives")
        else { throw FetchError.playerNotFound(username) }

        let archives = try await get(ChessComArchives.self, from: archivesURL, username: username)

        var games: [GameSummary] = []
        // Walk back month by month, keeping only rated games of this speed, until we have enough.
        for monthURL in archives.archives.reversed().prefix(maxMonths) {
            guard let url = URL(string: monthURL) else { continue }
            let month = try await get(ChessComMonth.self, from: url, username: username)
            games += month.games
                .filter { $0.rules == "chess" && $0.pgn != nil && $0.rated == true }
                .compactMap { $0.summary(for: user) }
                .filter { $0.speed == speed }
            if games.count >= limit { break }
        }
        return Array(games.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Chess.com's player stats list wins, losses and draws for each speed.
    private static func chessComCounts(for username: String) async throws -> [TimeControl: Int] {
        let user = username.lowercased()
        guard let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.chess.com/pub/player/\(encoded)/stats")
        else { throw FetchError.playerNotFound(username) }
        let data = try await send(URLRequest(url: url), username: username)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.network }
        var counts: [TimeControl: Int] = [:]
        for (key, value) in object where key.hasPrefix("chess_") {
            guard let speed = TimeControl.from(siteSpeed: String(key.dropFirst(6))),
                  let record = (value as? [String: Any])?["record"] as? [String: Any] else { continue }
            let total = ["win", "loss", "draw"].reduce(0) { $0 + ((record[$1] as? Int) ?? 0) }
            if total > 0 { counts[speed, default: 0] += total }
        }
        return counts
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
        let rated: Bool?
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
                speed: TimeControl.from(siteSpeed: time_class) ?? .classical,
                pgn: pgn
            )
        }
    }

    // MARK: Lichess

    /// Lichess sends one game per line (a format called NDJSON).
    private static func lichessGames(for username: String, speed: TimeControl, limit: Int) async throws -> [GameSummary] {
        // Lichess can filter by speed and by rated games itself, so we only download what we want.
        guard let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://lichess.org/api/games/user/\(encoded)?max=\(limit)&rated=true&perfType=\(speed.lichessPerfTypes)&pgnInJson=true&clocks=true")
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
            // Lichess sometimes sends a few more than asked for, so trim to what we want.
            .prefix(limit)
            .map { $0 }
    }

    /// Lichess's user profile lists how many games the player has at each speed.
    private static func lichessCounts(for username: String) async throws -> [TimeControl: Int] {
        guard let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://lichess.org/api/user/\(encoded)")
        else { throw FetchError.playerNotFound(username) }
        let data = try await send(URLRequest(url: url), username: username)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.network }
        // Closed or brand-new accounts have no stats; that just means no games.
        guard let perfs = object["perfs"] as? [String: Any] else { return [:] }
        var counts: [TimeControl: Int] = [:]
        for (key, value) in perfs {
            guard let speed = TimeControl.from(siteSpeed: key),
                  let games = (value as? [String: Any])?["games"] as? Int, games > 0 else { continue }
            counts[speed, default: 0] += games
        }
        return counts
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
                speed: TimeControl.from(siteSpeed: speed) ?? .classical,
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
