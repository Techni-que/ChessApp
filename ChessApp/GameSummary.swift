import Foundation

/// The chess websites the app can fetch games from.
enum ChessSite: String, CaseIterable, Identifiable {
    case chessCom = "Chess.com"
    case lichess = "Lichess"

    var id: String { rawValue }
}

/// One game in the list: who played, how it ended, and its full PGN text.
struct GameSummary: Identifiable, Hashable {
    enum Outcome: String {
        case win = "Won", loss = "Lost", draw = "Draw"
    }

    let id: String
    let opponent: String
    /// True if the searched player had the white pieces.
    let playedWhite: Bool
    let outcome: Outcome
    let date: Date
    /// For example "Blitz · 3+2".
    let timeControl: String
    /// The speed group (bullet, blitz, rapid or classical).
    let speed: TimeControl
    let pgn: String
}

/// Turns seconds-based clock settings into short text like "3+2" or "10 min".
enum TimeControlText {
    static func make(speed: String, initialSeconds: Int?, incrementSeconds: Int?) -> String {
        let speedName = speed.prefix(1).uppercased() + speed.dropFirst()
        guard let initialSeconds else { return speedName }
        let minutes = initialSeconds % 60 == 0 ? "\(initialSeconds / 60)" : String(format: "%g", Double(initialSeconds) / 60)
        let clock = (incrementSeconds ?? 0) > 0 ? "\(minutes)+\(incrementSeconds!)" : "\(minutes) min"
        return "\(speedName) · \(clock)"
    }
}
