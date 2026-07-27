import Foundation

/// One row from the `public_feed_preview` RPC — a deliberately trimmed view of
/// a posted session for signed-out browsing. Distinct from `FeedSession`: no
/// comment previews, no other participants' identities, nothing that requires
/// an authenticated viewer to resolve safely.
struct PublicFeedPreviewItem: Identifiable, Decodable, Hashable {
    let id: UUID
    let createdAt: String
    let title: String?
    let location: String?
    let durationMinutes: Int
    let authorId: UUID
    let authorUsername: String
    let authorDisplayName: String
    let authorAvatarURL: String?
    let authorAvatarInitials: String?
    let likeCount: Int
    let commentCount: Int
    let matches: [PublicMatchResult]

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case title, location
        case durationMinutes = "duration_minutes"
        case authorId = "author_id"
        case authorUsername = "author_username"
        case authorDisplayName = "author_display_name"
        case authorAvatarURL = "author_avatar_url"
        case authorAvatarInitials = "author_avatar_initials"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case matches
    }

    var date: Date { DateFormatting.parse(createdAt) }
    var wins: Int { matches.filter { $0.won == true }.count }
    var losses: Int { matches.filter { $0.won == false }.count }
}

struct PublicMatchResult: Decodable, Hashable {
    let teamScore: Int?
    let opponentScore: Int?
    let won: Bool?

    enum CodingKeys: String, CodingKey {
        case teamScore = "team_score"
        case opponentScore = "opponent_score"
        case won
    }

    var scoreLine: String? {
        guard let teamScore, let opponentScore else { return nil }
        return "\(teamScore)–\(opponentScore)"
    }
}
