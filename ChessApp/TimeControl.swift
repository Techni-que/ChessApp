import Foundation

/// The speed of a game, grouped the way most players think about it.
/// Ultra-bullet counts as bullet. Chess.com's "daily" and Lichess's "correspondence" are both Daily.
/// (Chess.com has no Classical, so that option simply won't appear for Chess.com players.)
enum TimeControl: String, CaseIterable, Identifiable, Codable {
    case bullet = "Bullet"
    case blitz = "Blitz"
    case rapid = "Rapid"
    case classical = "Classical"
    case daily = "Daily"

    var id: String { rawValue }

    /// Turns a site's own speed label (like "blitz", "ultraBullet" or "daily") into our group.
    static func from(siteSpeed: String) -> TimeControl? {
        switch siteSpeed.lowercased() {
        case "bullet", "ultrabullet": .bullet
        case "blitz": .blitz
        case "rapid": .rapid
        case "classical": .classical
        case "daily", "correspondence": .daily
        default: nil
        }
    }

    /// The Lichess `perfType` value that asks the site for only this speed.
    var lichessPerfTypes: String {
        switch self {
        case .bullet: "ultraBullet,bullet"
        case .blitz: "blitz"
        case .rapid: "rapid"
        case .classical: "classical"
        case .daily: "correspondence"
        }
    }

    /// Lower-case name for sentences, like "blitz games".
    var sentenceName: String { rawValue.lowercased() }
}
