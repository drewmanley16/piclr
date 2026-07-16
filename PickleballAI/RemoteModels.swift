import Foundation

// MARK: - Read models

struct Profile: Identifiable, Decodable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var avatarInitials: String?
    var avatarURL: String?
    var avatarPath: String?
    var homeCourt: String?
    var rating: Double?
    var skillLevel: String?
    var onboardingCompletedAt: String?
    var paddle: String?
    var preferredSide: String?
    var heightInches: Double?
    var weightPounds: Double?
    var shoeSize: Double?
    var birthday: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarInitials = "avatar_initials"
        case avatarURL = "avatar_url"
        case avatarPath = "avatar_path"
        case homeCourt = "home_court"
        case rating
        case skillLevel = "skill_level"
        case onboardingCompletedAt = "onboarding_completed_at"
        case paddle
        case preferredSide = "preferred_side"
        case heightInches = "height_inches"
        case weightPounds = "weight_pounds"
        case shoeSize = "shoe_size"
        case birthday
    }

    var initials: String {
        if let a = avatarInitials, !a.isEmpty { return a }
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    var hasCompletedOnboarding: Bool {
        onboardingCompletedAt != nil
    }

    init(
        id: UUID,
        username: String,
        displayName: String,
        avatarInitials: String? = nil,
        avatarURL: String? = nil,
        avatarPath: String? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarInitials = avatarInitials
        self.avatarURL = avatarURL
        self.avatarPath = avatarPath
        homeCourt = nil
        rating = nil
        skillLevel = nil
        onboardingCompletedAt = nil
        paddle = nil
        preferredSide = nil
        heightInches = nil
        weightPounds = nil
        shoeSize = nil
        birthday = nil
    }
}

/// Embedded `{ count: N }` rows returned by PostgREST aggregate selects.
struct CountRow: Decodable, Hashable { let count: Int }

struct LikeRow: Decodable, Hashable {
    let sessionId: UUID

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

struct FeedSession: Identifiable, Decodable, Hashable {
    let id: UUID
    let userId: UUID
    let title: String?
    let location: String?
    let durationMinutes: Int
    let focus: String?
    let takeaway: String?
    let posted: Bool
    let createdAt: String
    let startedAt: String?
    let endedAt: String?
    var author: Profile
    let repostedFrom: UUID?
    var photoUrl: String?
    let photoPath: String?
    private let likes: [CountRow]?
    private let comments: [CountRow]?
    var previewComments: [Comment]?
    var activities: [SessionActivity]?

    var isRepost: Bool { repostedFrom != nil }

    /// Is the given user tagged as a participant in any of this session's matches?
    func isParticipant(_ userId: UUID) -> Bool {
        sortedActivities.contains { activity in
            (activity.participants ?? []).contains { $0.profile?.id == userId }
        }
    }

    var likeCount: Int { likes?.first?.count ?? 0 }
    var commentCount: Int { comments?.first?.count ?? 0 }
    var inlineComments: [Comment] { (previewComments ?? []).prefix(3).map { $0 } }
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
    var startedDate: Date { startedAt.map(Self.parse) ?? date }
    var endedDate: Date { endedAt.map(Self.parse) ?? startedDate.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let focus, !focus.isEmpty { return "\(focus) session" }
        return "Session"
    }

    /// Human-readable subtitle: focus · duration · location (no chips).
    var metaLine: String {
        var parts: [String] = []
        if let focus, !focus.isEmpty { parts.append(focus) }
        parts.append("\(durationMinutes) min")
        if let location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    var shareSummary: String {
        var parts = ["\(author.displayName) — \(displayTitle)"]
        if matchCount > 0 { parts.append("\(matchCount) match\(matchCount == 1 ? "" : "es")") }
        parts.append("\(durationMinutes) min")
        return parts.joined(separator: " · ") + " · on pickleball.ai"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title, location
        case durationMinutes = "duration_minutes"
        case focus, takeaway, posted
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case repostedFrom = "reposted_from"
        case photoUrl = "photo_url"
        case photoPath = "photo_path"
        case author, likes, comments, activities
        case previewComments = "preview_comments"
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

/// The outcome of a match, from the logging user's perspective.
enum MatchResult {
    case win, loss, tie

    /// Single-letter badge (W / L / T).
    var badge: String {
        switch self {
        case .win:  return "W"
        case .loss: return "L"
        case .tie:  return "T"
        }
    }
}


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
    var participants: [ActivityParticipant]?

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
    /// Win/loss/tie derived from the scores, so a tie (equal scores) is never
    /// mistaken for a loss — the stored `won` flag can't represent a draw.
    var matchResult: MatchResult? {
        guard isMatch, let t = teamScore, let o = opponentScore else { return nil }
        if t > o { return .win }
        if t < o { return .loss }
        return .tie
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
    var profile: ParticipantProfile?

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
    var avatarURL: String?
    let avatarPath: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarInitials = "avatar_initials"
        case avatarURL = "avatar_url"
        case avatarPath = "avatar_path"
    }

    var initials: String {
        if let a = avatarInitials, !a.isEmpty { return a }
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
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
    var id: UUID = UUID()
    let activityId: UUID
    let sessionId: UUID
    let profileId: UUID?
    let guestName: String?
    let role: String

    enum CodingKeys: String, CodingKey {
        case id
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

    init(id: UUID = UUID(), profile: Profile? = nil, guestName: String? = nil) {
        self.id = id
        self.profile = profile
        self.guestName = guestName
    }

    init(participant: ActivityParticipant) {
        id = participant.id
        guestName = participant.guestName
        if let member = participant.profile {
            profile = Profile(
                id: member.id,
                username: member.username,
                displayName: member.displayName,
                avatarInitials: member.avatarInitials,
                avatarURL: member.avatarURL,
                avatarPath: member.avatarPath
            )
        }
    }

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
    var isTie: Bool { kind == .match && teamScore == opponentScore }
    /// What to persist in `won`: nil for a tie (neither win nor loss), so ties
    /// never count against a record on the server (leaderboard, rivalries).
    var wonValue: Bool? {
        guard kind == .match else { return nil }
        return teamScore == opponentScore ? nil : teamScore > opponentScore
    }
    var summary: String {
        switch kind {
        case .practice: return focus.isEmpty ? "Practice" : "\(focus) practice"
        case .match: return "Match \(teamScore)–\(opponentScore)"
        }
    }

    init(kind: ActivityKind) {
        self.kind = kind
    }

    init(activity: SessionActivity) {
        id = activity.id
        kind = activity.isMatch ? .match : .practice
        focus = activity.focus ?? ""
        reps = activity.reps ?? ""
        notes = activity.notes ?? ""
        partners = activity.partners.map(DraftPlayer.init(participant:))
        opponents = activity.opponents.map(DraftPlayer.init(participant:))
        teamScore = activity.teamScore ?? 11
        opponentScore = activity.opponentScore ?? 9
    }
}

struct SessionDraft: Equatable {
    var title: String = ""
    var location: String = ""
    var takeaway: String = ""
    var startedAt: Date = Date()
    var endedAt: Date?
    var activities: [DraftActivity] = []
    var postToFeed: Bool = true
    var photoData: Data? = nil
    var existingPhotoPath: String?
    var removePhoto = false

    init() {}

    init(session: FeedSession) {
        title = session.title ?? ""
        location = session.location ?? ""
        takeaway = session.takeaway ?? ""
        startedAt = session.startedDate
        endedAt = session.endedDate
        activities = session.sortedActivities.map(DraftActivity.init(activity:))
        postToFeed = session.posted
        existingPhotoPath = session.photoPath
    }
}

struct SessionUpdateParticipant: Encodable {
    let id: UUID
    let profileId: UUID?
    let guestName: String?
    let role: String

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case guestName = "guest_name"
        case role
    }
}

struct SessionUpdateActivity: Encodable {
    let id: UUID
    let kind: String
    let position: Int
    let focus: String?
    let reps: String?
    let notes: String?
    let teamScore: Int?
    let opponentScore: Int?
    let won: Bool?
    let participants: [SessionUpdateParticipant]

    enum CodingKeys: String, CodingKey {
        case id, kind, position, focus, reps, notes, won, participants
        case teamScore = "team_score"
        case opponentScore = "opponent_score"
    }
}

struct SessionUpdatePayload: Encodable {
    let title: String
    let location: String
    let takeaway: String
    let durationMinutes: Int
    let posted: Bool
    let startedAt: String
    let endedAt: String
    let photoPath: String
    let activities: [SessionUpdateActivity]

    enum CodingKeys: String, CodingKey {
        case title, location, takeaway, posted, activities
        case durationMinutes = "duration_minutes"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case photoPath = "photo_path"
    }
}

struct UpdateSessionRPCParams: Encodable {
    let targetSessionId: UUID
    let payload: SessionUpdatePayload

    enum CodingKeys: String, CodingKey {
        case targetSessionId = "target_session_id"
        case payload
    }
}

// MARK: - Reposts

struct RepostRequest: Identifiable, Decodable, Hashable {
    let id: UUID
    let sessionId: UUID
    let requesterId: UUID
    let status: String
    var requester: ParticipantProfile?
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

// MARK: - Activity notifications

struct AppNotification: Identifiable, Decodable, Hashable {
    let id: UUID
    let type: String
    let read: Bool
    let createdAt: String
    /// Pre-rendered phrase for notifications the generic actor/type message can't
    /// express (e.g. a rivalry's exact record). When present it wins.
    let detail: String?
    var actor: ParticipantProfile?
    let session: NotifSessionRef?
    let comment: NotifCommentRef?
    let invite: NotifInviteRef?

    enum CodingKeys: String, CodingKey {
        case id, type, read, detail
        case createdAt = "created_at"
        case actor, session, comment, invite
    }

    var date: Date { FeedSession.parse(createdAt) }

    var actorInitials: String {
        if let a = actor?.avatarInitials, !a.isEmpty { return a }
        let letters = (actor?.displayName ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var handle: String { actor.map { "@\($0.username)" } ?? "Someone" }

    var message: String {
        if let detail, !detail.isEmpty { return detail }
        switch type {
        case "like":            return "\(handle) liked your session"
        case "comment":         return "\(handle) commented: \(comment?.body ?? "")"
        case "follow":          return "\(handle) started following you"
        case "tag":             return "\(handle) tagged you in a session"
        case "repost_approved": return "\(handle) approved your repost"
        case "invite_received": return "\(handle) invited you to play at \(invite?.courtName ?? "a court")"
        case "invite_response":  return "\(handle) responded to your invite"
        case "rivalry":         return "\(handle) played you"
        default:                return "\(handle) interacted with your post"
        }
    }

    var icon: String {
        switch type {
        case "like":    return "hand.thumbsup.fill"
        case "comment": return "bubble.right.fill"
        case "follow":  return "person.fill.badge.plus"
        case "tag":     return "flag.checkered"
        case "invite_received", "invite_response": return "figure.pickleball"
        case "rivalry": return "flame.fill"
        default:        return "bell.fill"
        }
    }
}

struct NotifSessionRef: Decodable, Hashable {
    let id: UUID
    let title: String?
}

struct NotifCommentRef: Decodable, Hashable {
    let id: UUID
    let body: String
}

struct NotifInviteRef: Decodable, Hashable {
    let id: UUID
    let court: NotifCourtRef?
    var courtName: String? { court?.name }
}

struct NotifCourtRef: Decodable, Hashable {
    let name: String
}

// MARK: - Comments

struct Comment: Identifiable, Decodable, Hashable {
    let id: UUID
    let sessionId: UUID
    let userId: UUID
    let body: String
    let createdAt: String
    var author: ParticipantProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case userId = "user_id"
        case body
        case createdAt = "created_at"
        case author
    }

    var date: Date { FeedSession.parse(createdAt) }
    var authorName: String { author?.displayName ?? "Player" }
    var authorInitials: String {
        if let a = author?.avatarInitials, !a.isEmpty { return a }
        let letters = (author?.displayName ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct NewComment: Encodable {
    let sessionId: UUID
    let userId: UUID
    let body: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case userId = "user_id"
        case body
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

/// A snapshot of another user's profile as seen by the signed-in user.
/// `sessions` is only populated when `relationship.canViewContent` is true;
/// otherwise it's empty and the UI shows a "This profile is private" state.
struct PublicProfile {
    let profile: Profile
    var relationship: FollowRelationship
    let followerCount: Int
    let followingCount: Int
    var sessions: [FeedSession]
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

struct BlockedAccount: Identifiable, Decodable, Hashable {
    let blockedId: UUID
    let blockedUsername: String
    let blockedDisplayName: String
    let blockedAvatarPath: String?
    let createdAt: String

    var id: UUID { blockedId }
    var initials: String {
        let letters = blockedDisplayName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case blockedId = "blocked_id"
        case blockedUsername = "blocked_username"
        case blockedDisplayName = "blocked_display_name"
        case blockedAvatarPath = "blocked_avatar_path"
        case createdAt = "created_at"
    }
}

enum ReportTarget: Identifiable, Hashable {
    case user(UUID)
    case session(UUID)
    case comment(UUID)

    var id: String { "\(type):\(targetId.uuidString)" }
    var targetId: UUID {
        switch self {
        case .user(let id), .session(let id), .comment(let id): return id
        }
    }
    var type: String {
        switch self {
        case .user: return "user"
        case .session: return "session"
        case .comment: return "comment"
        }
    }
    var title: String {
        switch self {
        case .user: return "Report player"
        case .session: return "Report session"
        case .comment: return "Report comment"
        }
    }
}

enum ReportReason: String, CaseIterable, Identifiable {
    case harassment
    case spam
    case impersonation
    case inappropriate
    case cheating
    case other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .harassment: return "Harassment or bullying"
        case .spam: return "Spam"
        case .impersonation: return "Impersonation"
        case .inappropriate: return "Inappropriate content"
        case .cheating: return "Cheating or fraud"
        case .other: return "Other"
        }
    }
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
    let birthday: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case homeCourt = "home_court"
        case rating
        case preferredSide = "preferred_side"
        case birthday
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

struct NewBlock: Encodable {
    let blockerId: UUID
    let blockedId: UUID

    enum CodingKeys: String, CodingKey {
        case blockerId = "blocker_id"
        case blockedId = "blocked_id"
    }
}

struct NewReport: Encodable {
    let reporterId: UUID
    let targetType: String
    let targetId: UUID
    let reason: String
    let details: String?

    enum CodingKeys: String, CodingKey {
        case reporterId = "reporter_id"
        case targetType = "target_type"
        case targetId = "target_id"
        case reason, details
    }
}

struct DeleteAccountResponse: Decodable {
    let deleted: Bool
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

// MARK: - Session invites (RSVP)

struct Court: Identifiable, Decodable, Hashable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude
    }
}

struct NewCourt: Encodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let createdBy: UUID

    enum CodingKeys: String, CodingKey {
        case name, latitude, longitude
        case createdBy = "created_by"
    }
}

enum RSVPStatus: String, Codable, CaseIterable {
    case pending, yes, no, maybe

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .yes:     return "Yes"
        case .no:      return "No"
        case .maybe:   return "Maybe"
        }
    }
}

struct SessionInvite: Identifiable, Decodable, Hashable {
    let id: UUID
    let hostId: UUID
    let courtId: UUID
    let scheduledAt: String
    let note: String?
    let createdAt: String
    var host: ParticipantProfile?
    var court: Court?
    var recipients: [InviteRecipient]?

    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case courtId = "court_id"
        case scheduledAt = "scheduled_at"
        case note
        case createdAt = "created_at"
        case host, court, recipients
    }

    var scheduledAtDate: Date { FeedSession.parse(scheduledAt) }
    var createdAtDate: Date { FeedSession.parse(createdAt) }
    var isPast: Bool { scheduledAtDate < Date() }

    func myResponse(userId: UUID) -> RSVPStatus? {
        recipients?.first { $0.userId == userId }.flatMap { RSVPStatus(rawValue: $0.status) }
    }

    var yesCount: Int { recipients?.filter { $0.status == "yes" }.count ?? 0 }
}

struct NewSessionInvite: Encodable {
    let hostId: UUID
    let courtId: UUID
    let scheduledAt: Date
    let note: String?

    enum CodingKeys: String, CodingKey {
        case hostId = "host_id"
        case courtId = "court_id"
        case scheduledAt = "scheduled_at"
        case note
    }
}

struct InviteRecipient: Identifiable, Decodable, Hashable {
    let id: UUID
    let inviteId: UUID
    let userId: UUID
    let status: String
    var user: ParticipantProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case inviteId = "invite_id"
        case userId = "user_id"
        case status, user
    }
}

struct NewInviteRecipient: Encodable {
    let inviteId: UUID
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case inviteId = "invite_id"
        case userId = "user_id"
    }
}

struct InviteRecipientUpdate: Encodable {
    let status: String
    let respondedAt: Date

    enum CodingKeys: String, CodingKey {
        case status
        case respondedAt = "responded_at"
    }
}
