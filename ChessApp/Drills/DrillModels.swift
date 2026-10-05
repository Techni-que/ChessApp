import ChessKit
import Foundation

/// A puzzle from the free Lichess puzzle database (CC0 / public domain).
/// `moves` starts with the opponent's move, then alternates: your move, their reply, and so on.
struct Puzzle: Identifiable {
    let id: String
    let fen: String
    let moves: [String]
    let rating: Int
    let themes: Set<String>
}

/// Finds puzzles that fit a leak. Puzzles come from `puzzles.csv`, bundled with the app.
/// If that file is missing the drills simply use the player's own mistakes.
enum PuzzleLibrary {
    private static let all: [Puzzle] = {
        guard let url = Bundle.main.url(forResource: "puzzles", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            // PuzzleId,FEN,Moves,Rating,RatingDeviation,Popularity,NbPlays,Themes,...
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 8, let rating = Int(parts[3]) else { return nil }
            return Puzzle(id: String(parts[0]), fen: String(parts[1]),
                          moves: parts[2].split(separator: " ").map(String.init),
                          rating: rating, themes: Set(parts[7].split(separator: " ").map(String.init)))
        }
    }()

    static var isAvailable: Bool { !all.isEmpty }

    /// Puzzles with any of these themes, near the player's rating (within about 200 points), in random order.
    static func pick(themes wanted: Set<String>, rating: Int, count: Int) -> [Puzzle] {
        guard count > 0 else { return [] }
        let target = min(max(rating, 1000), 2000)
        let close = all.filter { abs($0.rating - target) <= 200 && !$0.themes.isDisjoint(with: wanted) }
        return Array(close.shuffled().prefix(count))
    }
}

/// How a question went. Spaced repetition will use this later:
/// pass moves a position up a step, hinted and second-try keep it where it is, revealed sends it back to day 1.
enum DrillOutcome: String, Codable {
    case pass, hinted, secondTry, revealed

    var solved: Bool { self != .revealed }

    var label: String {
        switch self {
        case .pass: "First try"
        case .hinted: "With a hint"
        case .secondTry: "Second try"
        case .revealed: "Shown the answer"
        }
    }
}

/// One question in a drill session.
struct DrillQuestion: Identifiable {
    enum Source {
        case ownMistake(DrillSpot)
        case puzzle(Puzzle)
    }

    let id = UUID()
    let leak: LeakKind
    let source: Source

    /// A key that stays the same between launches, so the same position can be recognised later.
    var stableKey: String {
        switch source {
        case .ownMistake(let spot): "own-\(Self.fingerprint(spot.game.pgn))-\(spot.ply)"
        case .puzzle(let puzzle): "puzzle-\(puzzle.id)"
        }
    }

    /// A small text fingerprint (FNV-1a). Swift's own hashValue changes every launch, so we can't use it.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// One answered question, saved on the phone for spaced repetition later.
struct DrillRecord: Codable {
    let key: String
    let leak: String
    let outcome: DrillOutcome
    let date: Date
    /// For the player's own mistakes: the game and move, so the position can be rebuilt later.
    var gamePGN: String?
    var ply: Int?
    /// For puzzles: the Lichess puzzle id.
    var puzzleID: String?
}

/// The log of answered questions (newest last, capped at 400 so it stays small).
enum DrillHistory {
    private static let url: URL = {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "drill-history.json")
    }()

    static func all() -> [DrillRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([DrillRecord].self, from: data) else { return [] }
        return records
    }

    static func append(_ record: DrillRecord) {
        var records = all()
        records.append(record)
        if records.count > 400 { records.removeFirst(records.count - 400) }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: url, options: .atomic) }
    }
}

/// Right and wrong answers per leak, saved on the phone for a future progress screen.
enum DrillStats {
    struct Score: Codable {
        var right = 0
        var wrong = 0
    }

    private static let key = "drillStats"

    static func all() -> [String: Score] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let scores = try? JSONDecoder().decode([String: Score].self, from: data) else { return [:] }
        return scores
    }

    static func score(for leak: LeakKind) -> Score { all()[leak.rawValue] ?? Score() }

    static func record(_ leak: LeakKind, right: Bool) {
        var scores = all()
        var score = scores[leak.rawValue] ?? Score()
        if right { score.right += 1 } else { score.wrong += 1 }
        scores[leak.rawValue] = score
        if let data = try? JSONEncoder().encode(scores) { UserDefaults.standard.set(data, forKey: key) }
    }
}
