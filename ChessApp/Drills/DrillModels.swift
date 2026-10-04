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
    /// Lichess puzzle themes that train each leak.
    static func themes(for leak: LeakKind) -> Set<String> {
        switch leak {
        case .hangingPieces: ["hangingPiece", "trappedPiece"]
        case .missedTactics: ["fork", "pin", "skewer", "discoveredAttack", "doubleCheck"]
        case .notConverting: ["advantage", "crushing", "endgame"]
        case .middlegameDrift: ["quietMove", "defensiveMove"]
        case .timeTrouble: ["short", "oneMove"]
        }
    }

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

    /// Puzzles for a leak, closest to the player's rating first (within about 200 points).
    static func pick(for leak: LeakKind, rating: Int, count: Int) -> [Puzzle] {
        guard count > 0 else { return [] }
        let wanted = themes(for: leak)
        let target = min(max(rating, 1000), 2000)
        let close = all.filter { abs($0.rating - target) <= 200 && !$0.themes.isDisjoint(with: wanted) }
        return Array(close.shuffled().prefix(count))
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
