import Foundation

// MARK: - Read models

struct Profile: Identifiable, Decodable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var avatarInitials: String?
    var avatarURL: String?
    var homeCourt: String?
    var rating: Double?
    var skillLevel: String?
    var onboardingCompletedAt: String?
    var paddle: String?
    var preferredSide: String?
    var heightInches: Double?
    var weightPounds: Double?
    var shoeSize: Double?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarInitials = "avatar_initials"
        case avatarURL = "avatar_url"
        case homeCourt = "home_court"
        case rating
        case skillLevel = "skill_level"
        case onboardingCompletedAt = "onboarding_completed_at"
        case paddle
        case preferredSide = "preferred_side"
        case heightInches = "height_inches"
        case weightPounds = "weight_pounds"
        case shoeSize = "shoe_size"
    }

    var initials: String {
        if let a = avatarInitials, !a.isEmpty { return a }
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    var hasCompletedOnboarding: Bool {
        onboardingCompletedAt != nil
    }
}

/// Embedded `{ count: N }` rows returned by PostgREST aggregate selects.
struct CountRow: Decodable, Hashable { let count: Int }

struct FeedSession: Identifiable, Decodable, Hashable {
    let id: UUID
    let userId: UUID
    let title: String?
    let location: String?
    let durationMinutes: Int
    let focus: String?
    let takeaway: String?
    let createdAt: String
    let author: Profile
    let repostedFrom: UUID?
    private let likes: [CountRow]?
    private let comments: [CountRow]?
    private let activities: [SessionActivity]?

    var isRepost: Bool { repostedFrom != nil }

    /// Is the given user tagged as a participant in any of this session's matches?
    func isParticipant(_ userId: UUID) -> Bool {
        sortedActivities.contains { activity in
            (activity.participants ?? []).contains { $0.profile?.id == userId }
        }
    }

    var likeCount: Int { likes?.first?.count ?? 0 }
    var commentCount: Int { comments?.first?.count ?? 0 }
    var sortedActivities: [SessionActivity] { (activities ?? []).sorted { $0.position < $1.position } }
    var matchCount: Int { sortedActivities.filter(\.isMatch).count }
    var practiceCount: Int { sortedActivities.filter { !$0.isMatch }.count }

    /// Distinct people (members + guests) tagged across the session's matches.
    var taggedNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for activity in sortedActivities {
            for p in activity.participants ?? [] {
                let key = p.profile?.id.uuidString ?? p.guestName ?? p.id.uuidString
                if seen.insert(key).inserted { names.append(p.displayName) }
            }
        }
        return names
    }

    var date: Date { Self.parse(createdAt) }
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let focus, !focus.isEmpty { return "\(focus) session" }
        return "Session"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title, location
        case durationMinutes = "duration_minutes"
        case focus, takeaway
        case createdAt = "created_at"
        case repostedFrom = "reposted_from"
        case author, likes, comments, activities
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String) -> Date {
        isoFractional.date(from: s) ?? iso.date(from: s) ?? Date()
    }
}

// MARK: - Session activities (read models)

struct SessionActivity: Identifiable, Decodable, Hashable {
    let id: UUID
    let kind: String
    let position: Int
    let focus: String?
    let reps: String?
    let notes: String?
    let teamScore: Int?
    let opponentScore: Int?
    let won: Bool?
    let participants: [ActivityParticipant]?

    enum CodingKeys: String, CodingKey {
        case id, kind, position, focus, reps, notes
        case teamScore = "team_score"
        case opponentScore = "opponent_score"
        case won, participants
    }

    var isMatch: Bool { kind == "match" }
    var partners: [ActivityParticipant] { (participants ?? []).filter { $0.role == "partner" } }
    var opponents: [ActivityParticipant] { (participants ?? []).filter { $0.role == "opponent" } }
    var scoreLine: String? {
        guard let t = teamScore, let o = opponentScore else { return nil }
        return "\(t)–\(o)"
    }
    var title: String {
        if isMatch { return scoreLine.map { "Match \($0)" } ?? "Match" }
        if let focus, !focus.isEmpty { return "\(focus) practice" }
        return "Practice"
    }
}

struct ActivityParticipant: Identifiable, Decodable, Hashable {
    let id: UUID
    let role: String
    let guestName: String?
    let profile: ParticipantProfile?

    enum CodingKeys: String, CodingKey {
        case id, role
        case guestName = "guest_name"
        case profile
    }

    var displayName: String { profile?.displayName ?? guestName ?? "Player" }
    var handle: String? { profile.map { "@\($0.username)" } }
    var isGuest: Bool { profile == nil }
}

struct ParticipantProfile: Decodable, Hashable {
    let id: UUID
    let username: String
    let displayName: String
    let avatarInitials: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarInitials = "avatar_initials"
    }
}

// MARK: - Session activities (write models)

struct NewSessionActivity: Encodable {
    var id: UUID = UUID()
    let sessionId: UUID
    let kind: String
    let position: Int
    let focus: String?
    let reps: String?
    let notes: String?
    let teamScore: Int?
    let opponentScore: Int?
    let won: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case kind, position, focus, reps, notes
        case teamScore = "team_score"
        case opponentScore = "opponent_score"
        case won
    }
}

struct NewActivityParticipant: Encodable {
    let activityId: UUID
    let sessionId: UUID
    let profileId: UUID?
    let guestName: String?
    let role: String

    enum CodingKeys: String, CodingKey {
        case activityId = "activity_id"
        case sessionId = "session_id"
        case profileId = "profile_id"
        case guestName = "guest_name"
        case role
    }
}

// MARK: - On-device session draft (built live, written on Finish & Post)

enum ActivityKind: String, Hashable { case practice, match }

struct DraftPlayer: Identifiable, Hashable {
    var id = UUID()
    var profile: Profile?
    var guestName: String?

    var displayName: String { profile?.displayName ?? guestName ?? "Player" }
    var handle: String? { profile.map { "@\($0.username)" } }
    var initials: String {
        if let profile { return profile.initials }
        let letters = (guestName ?? "").split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct DraftActivity: Identifiable, Hashable {
    var id = UUID()
    var kind: ActivityKind
    // practice
    var focus: String = ""
    var reps: String = ""
    var notes: String = ""
    // match
    var partners: [DraftPlayer] = []
    var opponents: [DraftPlayer] = []
    var teamScore: Int = 11
    var opponentScore: Int = 9

    var won: Bool { teamScore > opponentScore }
    var summary: String {
        switch kind {
        case .practice: return focus.isEmpty ? "Practice" : "\(focus) practice"
        case .match: return "Match \(teamScore)–\(opponentScore)"
        }
    }
}

struct SessionDraft {
    var title: String = ""
    var location: String = ""
    var startedAt: Date = Date()
    var activities: [DraftActivity] = []
    var postToFeed: Bool = true
}

// MARK: - Reposts

struct RepostRequest: Identifiable, Decodable, Hashable {
    let id: UUID
    let sessionId: UUID
    let requesterId: UUID
    let status: String
    let requester: ParticipantProfile?
    let session: RepostSessionInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case requesterId = "requester_id"
        case status, requester, session
    }
}

struct RepostSessionInfo: Decodable, Hashable {
    let id: UUID
    let userId: UUID
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
    }
}

struct NewRepostRequest: Encodable {
    let sessionId: UUID
    let requesterId: UUID

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case requesterId = "requester_id"
    }
}

enum GearCategory: String, CaseIterable, Identifiable {
    case paddle = "Paddle"
    case shoes = "Shoes"
    case bag = "Bag"
    case apparel = "Apparel"
    case accessory = "Accessory"
    case other = "Other"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .paddle: return "figure.pickleball"
        case .shoes: return "shoe"
        case .bag: return "bag"
        case .apparel: return "tshirt"
        case .accessory: return "eyeglasses"
        case .other: return "shippingbox"
        }
    }
}

struct GearItem: Identifiable, Decodable, Hashable {
    let id: UUID
    let userId: UUID
    let category: String
    let name: String
    let brand: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case category, name, brand
    }

    var categoryIcon: String {
        GearCategory(rawValue: category)?.systemImage ?? "shippingbox"
    }
}

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

// MARK: - Write models

struct NewProfile: Encodable {
    let id: UUID
    let username: String
    let displayName: String
    let avatarInitials: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarInitials = "avatar_initials"
    }
}

struct NewSession: Encodable {
    var id: UUID = UUID()
    let userId: UUID
    let title: String?
    let location: String?
    let durationMinutes: Int
    let focus: String?
    let takeaway: String?
    let posted: Bool
    var startedAt: String? = nil
    var endedAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title, location
        case durationMinutes = "duration_minutes"
        case focus, takeaway, posted
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

struct NewLike: Encodable {
    let userId: UUID
    let sessionId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionId = "session_id"
    }
}

struct ProfileUpdate: Encodable {
    let displayName: String
    let homeCourt: String?
    let rating: Double?
    let preferredSide: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case homeCourt = "home_court"
        case rating
        case preferredSide = "preferred_side"
    }
}

struct MeasuresUpdate: Encodable {
    let heightInches: Double?
    let weightPounds: Double?
    let shoeSize: Double?

    enum CodingKeys: String, CodingKey {
        case heightInches = "height_inches"
        case weightPounds = "weight_pounds"
        case shoeSize = "shoe_size"
    }
}

struct NewGear: Encodable {
    let userId: UUID
    let category: String
    let name: String
    let brand: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case category, name, brand
    }
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

struct CompleteOnboardingRequest: Encodable {
    let displayName: String
    let username: String
    let avatarInitials: String
    let skillLevel: String
    let duprRating: Double?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case avatarInitials = "avatar_initials"
        case skillLevel = "skill_level"
        case duprRating = "dupr_rating"
    }
}

struct CompleteOnboardingResponse: Decodable {
    let profile: Profile
}

struct MatchContactsRequest: Encodable {
    let phones: [String]
}

struct MatchContactsResponse: Decodable {
    let matches: [ContactMatch]
}
