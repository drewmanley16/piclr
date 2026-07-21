import Foundation

// MARK: - Crew leaderboard

/// One row of the crew leaderboard (you + everyone you follow), from
/// `crew_leaderboard()`. Ranking is decided client-side so the same rows can be
/// re-sorted without another round trip.
struct LeaderboardEntry: Identifiable, Decodable, Hashable {
    let userId: UUID
    let username: String
    let displayName: String
    let avatarURL: String?
    let avatarInitials: String?
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
        case wins, losses, matches
    }
}

// MARK: - Follow graph

/// An incoming follow request: someone (the follower) has asked to follow the
/// signed-in user (the followee). Synthesized in the store from a pending
/// `follows` row plus the follower's profile.
struct FollowRequest: Identifiable, Hashable {
    let followerId: UUID
    let followeeId: UUID
    let follower: Profile?

    var id: UUID { followerId }
}

struct ContactMatch: Identifiable, Decodable, Hashable {
    var id: UUID { profile.id }
    let phone: String
    let profile: Profile
}

/// The signed-in user's outgoing relationship to another profile, used to
/// gate the public profile view (Instagram-style private accounts).
enum FollowRelationship: Equatable {
    case isSelf       // it's your own profile
    case none         // no outgoing edge → "Follow"
    case requested    // pending outgoing request → "Requested"
    case following    // accepted → you can see their content

    /// Whether the signed-in user is allowed to see this profile's content
    /// (sessions). Mirrors the `sessions_read` RLS policy.
    var canViewContent: Bool { self == .isSelf || self == .following }
}

/// A raw row from the `follows` table (directional follow edge).
struct FollowRow: Decodable, Hashable {
    let followerId: UUID
    let followeeId: UUID
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case followerId = "follower_id"
        case followeeId = "followee_id"
        case status
        case createdAt = "created_at"
    }
}

/// A row in the followers/following list: the other user, plus whether the
/// signed-in user follows them back (Instagram-style). `profile` is nil when
/// it isn't visible (e.g. hidden by RLS), rendering as "Unknown".
struct FollowListEntry: Identifiable, Hashable {
    let userId: UUID
    let profile: Profile?
    let isFollowedByMe: Bool

    var id: UUID { userId }
}

/// Directional follow edge write model. follower_id follows followee_id;
/// the request starts `pending` until the followee accepts.
struct NewFollow: Encodable {
    let followerId: UUID
    let followeeId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case followerId = "follower_id"
        case followeeId = "followee_id"
        case status
    }
}
