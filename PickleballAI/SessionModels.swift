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

// MARK: - Session update (write models)

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

// MARK: - Session / like write models

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
