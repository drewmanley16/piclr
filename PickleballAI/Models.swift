import Foundation

struct Player: Identifiable, Hashable {
    let id: UUID
    var name: String
    var handle: String
    var rating: Double
    var avatarInitials: String
}

struct Match: Identifiable, Hashable {
    let id: UUID
    var date: Date
    var location: String
    var teamOne: [Player]
    var teamTwo: [Player]
    var teamOneScore: Int
    var teamTwoScore: Int
    var matchType: MatchType
    var focus: SkillFocus
    var note: String

    var winningTeamNames: String {
        let winners = teamOneScore > teamTwoScore ? teamOne : teamTwo
        return winners.map(\.name).joined(separator: " & ")
    }

    var summary: String {
        "\(teamOne.map(\.name).joined(separator: " & ")) vs \(teamTwo.map(\.name).joined(separator: " & "))"
    }
}

struct PracticeSession: Identifiable, Hashable {
    let id: UUID
    var date: Date
    var location: String
    var durationMinutes: Int
    var drills: [Drill]
    var matchesPlayed: Int
    var wins: Int
    var focus: SkillFocus
    var takeaway: String
}

struct Drill: Identifiable, Hashable {
    let id: UUID
    var name: String
    var durationMinutes: Int
    var attempts: Int?
    var makes: Int?
}

struct PickleballGroup: Identifiable, Hashable {
    let id: UUID
    var name: String
    var location: String
    var members: [Player]
    var leaderboard: [LeaderboardRow]
}

struct LeaderboardRow: Identifiable, Hashable {
    let id: UUID
    var player: Player
    var wins: Int
    var losses: Int
    var streak: Int

    var winRate: Int {
        let total = max(wins + losses, 1)
        return Int((Double(wins) / Double(total)) * 100)
    }
}

enum MatchType: String, CaseIterable, Identifiable {
    case casual = "Casual"
    case ladder = "Ladder"
    case tournament = "Tournament"
    case drillGame = "Drill Game"

    var id: String { rawValue }
}

enum SkillFocus: String, CaseIterable, Identifiable {
    case serve = "Serve"
    case returnDepth = "Return Depth"
    case thirdShot = "Third Shot"
    case dinks = "Dinks"
    case resets = "Resets"
    case hands = "Hands"
    case positioning = "Positioning"
    case communication = "Communication"

    var id: String { rawValue }
}

enum FeedItem: Identifiable, Hashable {
    case match(Match)
    case session(PracticeSession)

    var id: UUID {
        switch self {
        case .match(let match):
            return match.id
        case .session(let session):
            return session.id
        }
    }

    var date: Date {
        switch self {
        case .match(let match):
            return match.date
        case .session(let session):
            return session.date
        }
    }
}
