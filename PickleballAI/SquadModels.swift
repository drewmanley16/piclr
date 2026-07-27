import Foundation

/// A formal named group ("clan") — distinct from the crew leaderboard's
/// follow-graph concept. Users may belong to multiple squads. See
/// `AppStore+Squads.swift`.
struct Squad: Identifiable, Decodable, Hashable {
    let id: UUID
    let name: String
    let ownerId: UUID
    let joinCode: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
        case joinCode = "join_code"
        case createdAt = "created_at"
    }
}

enum SquadRole: String, Decodable, Hashable {
    case owner, member
}

/// A raw row from the `squad_members` table (before profile hydration).
struct SquadMemberRow: Decodable, Hashable {
    let id: UUID
    let squadId: UUID
    let userId: UUID
    let role: SquadRole

    enum CodingKeys: String, CodingKey {
        case id
        case squadId = "squad_id"
        case userId = "user_id"
        case role
    }
}

/// A roster row: a squad_members edge plus the hydrated profile. `profile` is
/// nil when it isn't visible (mirrors `FollowListEntry`).
struct SquadMember: Identifiable, Hashable {
    let userId: UUID
    let role: SquadRole
    let profile: Profile?

    var id: UUID { userId }
    var isOwner: Bool { role == .owner }
}

/// One row of a squad-scoped leaderboard, from `squad_leaderboard()`. Same
/// stat shape as `LeaderboardEntry` but a distinct type since it's a
/// different RPC/query surface.
struct SquadLeaderboardEntry: Identifiable, Decodable, Hashable {
    let userId: UUID
    let username: String
    let displayName: String
    let avatarURL: String?
    let avatarInitials: String?
    let isPro: Bool
    let wins: Int
    let losses: Int
    let matches: Int

    var id: UUID { userId }
    var winRate: Int { matches == 0 ? 0 : Int((Double(wins) / Double(matches) * 100).rounded()) }
    var recordLine: String { "\(wins)–\(losses)" }
    var initials: String {
        if let a = avatarInitials, !a.isEmpty { return a }
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case avatarInitials = "avatar_initials"
        case isPro = "is_pro"
        case wins, losses, matches
    }
}
