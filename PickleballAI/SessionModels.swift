import Foundation

// MARK: - Date formatting

/// The app's shared ISO-8601 formatters — the single source of truth for both
/// the wire format written to Postgres and parsing of PostgREST timestamps.
/// `ISO8601DateFormatter` is thread-safe, so sharing statics is fine.
enum DateFormatting {
    /// Wire format sent to Postgres (`2026-07-16T12:34:56Z`, no fractional
    /// seconds). Encoding must stay byte-identical to this.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses a PostgREST timestamp (tries fractional seconds, then plain).
    static func parse(_ s: String) -> Date {
        isoFractional.date(from: s) ?? iso.date(from: s) ?? Date()
    }
}

// MARK: - Session read models

/// Embedded `{ count: N }` rows returned by PostgREST aggregate selects.
struct CountRow: Decodable, Hashable { let count: Int }

struct LikeRow: Decodable, Hashable {
    let sessionId: UUID

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

/// Canonical post content embedded for a repost wrapper. Engagement and repost
/// ownership stay on `FeedSession`; everything visible in the post body comes
/// from this original session.
struct RepostSource: Decodable, Hashable {
    let id: UUID
    let userId: UUID
    let title: String?
    let location: String?
    let durationMinutes: Int
    let focus: String?
    let takeaway: String?
    let createdAt: String
    let startedAt: String?
    let endedAt: String?
    let averageHeartRateBPM: Int?
    let maximumHeartRateBPM: Int?
    let activeCaloriesKcal: Int?
    var author: Profile
    var photoUrl: String?
    let photoPath: String?
    let streakWeek: Int?
    var activities: [SessionActivity]?

    var sortedActivities: [SessionActivity] {
        (activities ?? []).sorted { $0.position < $1.position }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title, location
        case durationMinutes = "duration_minutes"
        case focus, takeaway
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case averageHeartRateBPM = "average_heart_rate_bpm"
        case maximumHeartRateBPM = "maximum_heart_rate_bpm"
        case activeCaloriesKcal = "active_calories_kcal"
        case photoUrl = "photo_url"
        case photoPath = "photo_path"
        case streakWeek = "streak_week"
        case author, activities
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
    let averageHeartRateBPM: Int?
    let maximumHeartRateBPM: Int?
    let activeCaloriesKcal: Int?
    var author: Profile
    let repostedFrom: UUID?
    var photoUrl: String?
    let photoPath: String?
    /// Frozen weekly-streak length this post earned (>= 2), or nil. Set server-side
    /// when the post is the first session of a new week that extends the streak.
    let streakWeek: Int?
    private let likes: [CountRow]?
    private let comments: [CountRow]?
    var previewComments: [Comment]?
    var activities: [SessionActivity]?
    var source: RepostSource?

    var isRepost: Bool { repostedFrom != nil }

    var postAuthor: Profile { source?.author ?? author }
    var postTitle: String? { source?.title ?? title }
    var postLocation: String? { source?.location ?? location }
    var postDurationMinutes: Int { source?.durationMinutes ?? durationMinutes }
    var postFocus: String? { source?.focus ?? focus }
    var postTakeaway: String? { source?.takeaway ?? takeaway }
    var postPhotoURL: String? { source?.photoUrl ?? photoUrl }
    var postPhotoPath: String? { source?.photoPath ?? photoPath }
    var postAverageHeartRateBPM: Int? { source?.averageHeartRateBPM ?? averageHeartRateBPM }
    var postMaximumHeartRateBPM: Int? { source?.maximumHeartRateBPM ?? maximumHeartRateBPM }
    var postActiveCaloriesKcal: Int? { source?.activeCaloriesKcal ?? activeCaloriesKcal }
    /// The streak length to badge on this post (a repost shows the original's).
    var postStreakWeek: Int? { source?.streakWeek ?? streakWeek }
    var hasPostWorkoutMetrics: Bool {
        postAverageHeartRateBPM != nil || postMaximumHeartRateBPM != nil || postActiveCaloriesKcal != nil
    }
    var workoutMetrics: WorkoutMetrics? {
        guard averageHeartRateBPM != nil || maximumHeartRateBPM != nil || activeCaloriesKcal != nil else { return nil }
        return WorkoutMetrics(
            averageHeartRateBPM: averageHeartRateBPM,
            maximumHeartRateBPM: maximumHeartRateBPM,
            activeCaloriesKcal: activeCaloriesKcal,
            startedAt: startedDate,
            endedAt: endedDate
        )
    }
    var postActivities: [SessionActivity] { source?.sortedActivities ?? sortedActivities }
    var postDate: Date { source.map { Self.parse($0.createdAt) } ?? date }

    var postDisplayTitle: String {
        if let postTitle, !postTitle.isEmpty { return postTitle }
        if let postFocus, !postFocus.isEmpty { return "\(postFocus) session" }
        return "Session"
    }

    var postCompactDuration: String {
        postDurationMinutes < 60
            ? "\(postDurationMinutes)m"
            : "\(postDurationMinutes / 60)h \(postDurationMinutes % 60)m"
    }

    /// Is the given user tagged as a participant in any of this session's matches?
    func isParticipant(_ userId: UUID) -> Bool {
        postActivities.contains { activity in
            (activity.participants ?? []).contains { $0.profile?.id == userId }
        }
    }

    var likeCount: Int { likes?.first?.count ?? 0 }
    var commentCount: Int { comments?.first?.count ?? 0 }
    var inlineComments: [Comment] {
        (previewComments ?? [])
            .filter { !$0.isDeleted && !$0.isReply }
            .prefix(3)
            .map { $0 }
    }
    var sortedActivities: [SessionActivity] { (activities ?? []).sorted { $0.position < $1.position } }
    var matchCount: Int { postActivities.filter(\.isMatch).count }
    var practiceCount: Int { postActivities.filter { !$0.isMatch }.count }

    /// Distinct people (members + guests) tagged across the session's matches.
    var taggedNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for activity in postActivities {
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

    /// Compact duration label (23m / 1h 5m) for chips and meta lines.
    var compactDuration: String {
        durationMinutes < 60 ? "\(durationMinutes)m" : "\(durationMinutes / 60)h \(durationMinutes % 60)m"
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
        let matches = postActivities.filter(\.isMatch).count
        var parts = ["\(postAuthor.displayName): \(postDisplayTitle)"]
        if matches > 0 { parts.append("\(matches) match\(matches == 1 ? "" : "es")") }
        parts.append("\(postDurationMinutes) min")
        return parts.joined(separator: " · ") + " · on piclr"
    }

    /// Activities that affect the owner's workout record. Reposts project only
    /// tagged source activities into the repost owner's score/role perspective.
    func workoutActivities(for playerID: UUID) -> [SessionActivity] {
        guard let source else { return sortedActivities }
        return source.sortedActivities.compactMap {
            $0.projected(for: playerID, sourceAuthor: source.author)
        }
    }

    var workoutDate: Date { source.map { Self.parse($0.createdAt) } ?? date }
    var workoutDurationMinutes: Int { source?.durationMinutes ?? durationMinutes }
    var workoutDisplayTitle: String { postDisplayTitle }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title, location
        case durationMinutes = "duration_minutes"
        case focus, takeaway, posted
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case averageHeartRateBPM = "average_heart_rate_bpm"
        case maximumHeartRateBPM = "maximum_heart_rate_bpm"
        case activeCaloriesKcal = "active_calories_kcal"
        case repostedFrom = "reposted_from"
        case photoUrl = "photo_url"
        case photoPath = "photo_path"
        case streakWeek = "streak_week"
        case author, likes, comments, activities, source
        case previewComments = "preview_comments"
    }

    /// Shared ISO8601 parser. Kept as a delegating alias so other read models
    /// (notifications, comments, invites) keep their existing call sites.
    static func parse(_ s: String) -> Date {
        DateFormatting.parse(s)
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

    /// Reframe one canonical activity for a tagged player's workout record.
    /// The feed continues to render this activity unchanged from the author.
    func projected(for playerID: UUID, sourceAuthor: Profile) -> SessionActivity? {
        let tags = (participants ?? []).filter { $0.profile?.id == playerID }
        guard tags.count == 1 else { return nil }
        let playerRole = tags[0].role
        let flipSides = playerRole == "opponent"

        var projectedParticipants = (participants ?? []).compactMap { participant -> ActivityParticipant? in
            guard participant.profile?.id != playerID,
                  participant.profile?.id != sourceAuthor.id else { return nil }
            let role: String
            if flipSides {
                role = participant.role == "partner" ? "opponent" : "partner"
            } else {
                role = participant.role
            }
            return participant.withRole(role)
        }
        projectedParticipants.append(
            ActivityParticipant(
                id: sourceAuthor.id,
                role: playerRole,
                guestName: nil,
                profile: ParticipantProfile(profile: sourceAuthor)
            )
        )

        let projectedTeamScore = flipSides ? opponentScore : teamScore
        let projectedOpponentScore = flipSides ? teamScore : opponentScore
        let projectedWon: Bool?
        if isMatch, let team = projectedTeamScore, let opponent = projectedOpponentScore, team != opponent {
            projectedWon = team > opponent
        } else {
            projectedWon = nil
        }

        return SessionActivity(
            id: id,
            kind: kind,
            position: position,
            focus: focus,
            reps: reps,
            notes: notes,
            teamScore: projectedTeamScore,
            opponentScore: projectedOpponentScore,
            won: projectedWon,
            participants: projectedParticipants
        )
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

    func withRole(_ role: String) -> ActivityParticipant {
        ActivityParticipant(id: id, role: role, guestName: guestName, profile: profile)
    }
}

// MARK: - Session write models
//
// Both writes go through an RPC that takes the whole session as one JSON
// payload (`create_own_session` / `update_own_session`), so activities and
// participants are shared between them.

struct SessionWriteParticipant: Encodable {
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

struct SessionWriteActivity: Encodable {
    let id: UUID
    let kind: String
    let position: Int
    let focus: String?
    let reps: String?
    let notes: String?
    let teamScore: Int?
    let opponentScore: Int?
    let won: Bool?
    let participants: [SessionWriteParticipant]

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
    let activities: [SessionWriteActivity]

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

/// Create payload. Carries the session id so the photo can be uploaded to its
/// final path before the row exists, and the Watch metrics the edit path has no
/// way to change.
struct SessionCreatePayload: Encodable {
    let id: UUID
    let title: String
    let location: String
    let takeaway: String
    let durationMinutes: Int
    let posted: Bool
    let startedAt: String
    let endedAt: String
    let photoPath: String
    let averageHeartRateBPM: Int?
    let maximumHeartRateBPM: Int?
    let activeCaloriesKcal: Int?
    let activities: [SessionWriteActivity]

    enum CodingKeys: String, CodingKey {
        case id, title, location, takeaway, posted, activities
        case durationMinutes = "duration_minutes"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case photoPath = "photo_path"
        case averageHeartRateBPM = "average_heart_rate_bpm"
        case maximumHeartRateBPM = "maximum_heart_rate_bpm"
        case activeCaloriesKcal = "active_calories_kcal"
    }
}

struct CreateSessionRPCParams: Encodable {
    let payload: SessionCreatePayload
}

// MARK: - Like write model

struct NewLike: Encodable {
    let userId: UUID
    let sessionId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionId = "session_id"
    }
}
