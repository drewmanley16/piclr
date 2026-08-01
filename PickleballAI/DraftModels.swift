import Foundation

// MARK: - On-device session draft (built live, written on Finish & Post)

/// Draft-only classifier for an activity. Remote `SessionActivity`/`NewSessionActivity`
/// store `kind` as a raw String; this typed enum is used solely by the on-device
/// draft types below.
enum ActivityKind: String, Codable, Hashable { case practice, match }

// Draft types are Codable so a live session can be persisted to disk and
// restored after a force-quit/crash (see AppStore live-draft persistence).
struct DraftPlayer: Identifiable, Codable, Hashable {
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

struct DraftActivity: Identifiable, Codable, Hashable {
    static let doublesMaxPartners = 1
    static let doublesMaxOpponents = 2

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
    var matchFormat: MatchFormat = .doubles

    var won: Bool { teamScore > opponentScore }
    var isTie: Bool { kind == .match && teamScore == opponentScore }
    var maxPartners: Int { matchFormat == .singles ? 0 : Self.doublesMaxPartners }
    var maxOpponents: Int { matchFormat == .singles ? 1 : Self.doublesMaxOpponents }
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

    /// `matchFormat` was added after live drafts were already persisted on
    /// device. Decode it leniently so an in-progress pre-update session resumes
    /// as doubles instead of being discarded.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try values.decode(ActivityKind.self, forKey: .kind)
        focus = try values.decodeIfPresent(String.self, forKey: .focus) ?? ""
        reps = try values.decodeIfPresent(String.self, forKey: .reps) ?? ""
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        partners = try values.decodeIfPresent([DraftPlayer].self, forKey: .partners) ?? []
        opponents = try values.decodeIfPresent([DraftPlayer].self, forKey: .opponents) ?? []
        teamScore = try values.decodeIfPresent(Int.self, forKey: .teamScore) ?? 11
        opponentScore = try values.decodeIfPresent(Int.self, forKey: .opponentScore) ?? 9
        matchFormat = try values.decodeIfPresent(MatchFormat.self, forKey: .matchFormat) ?? .doubles
    }

    /// Build a finished match activity from a watch live-game score. US → team,
    /// THEM → opponents. Players are attached on the phone before posting.
    init(liveMatch: LiveMatchScore) {
        self.init(kind: .match)
        teamScore = liveMatch.us
        opponentScore = liveMatch.them
    }

    /// New match, optionally carrying forward the partners/opponents of `previous`
    /// (the prior match in a live session), so players don't have to be re-picked
    /// every game. Player structs get fresh ids — `updateSession` writes
    /// `DraftPlayer.id` as the `activity_participants` row id, so reusing ids
    /// across activities would collide on the backend.
    init(kind: ActivityKind, carryingPlayersFrom previous: DraftActivity?) {
        self.init(kind: kind)
        guard kind == .match, let previous, previous.kind == .match else { return }
        matchFormat = previous.matchFormat
        partners = previous.partners.prefix(maxPartners).map {
            DraftPlayer(profile: $0.profile, guestName: $0.guestName)
        }
        opponents = previous.opponents.prefix(maxOpponents).map {
            DraftPlayer(profile: $0.profile, guestName: $0.guestName)
        }
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
        matchFormat = activity.resolvedMatchFormat
    }

    mutating func normalizeRosterForFormat() {
        partners = Array(partners.prefix(maxPartners))
        opponents = Array(opponents.prefix(maxOpponents))
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, focus, reps, notes, partners, opponents
        case teamScore, opponentScore, matchFormat
    }
}

struct SessionDraft: Codable, Equatable {
    /// Stable id for create retries. Storage uploads use this id in their object
    /// path, and `create_own_session` treats a repeated id from the same owner as
    /// the same write. Optional so older persisted drafts still decode.
    var createID: UUID? = UUID()
    var title: String = ""
    var location: String = ""
    var takeaway: String = ""
    var startedAt: Date = Date()
    var endedAt: Date?
    /// Explicit duration, set by the quick-log editor. A live session leaves
    /// this nil and derives its duration from elapsed time instead — a quick log
    /// has no elapsed time to measure, since it's entered after the fact.
    var durationMinutes: Int?
    var activities: [DraftActivity] = []
    /// The in-progress game streaming from the paired Apple Watch, if any. Set
    /// as score snapshots arrive; converted into an `activities` entry when the
    /// game ends. nil when no watch game is live.
    var liveMatch: LiveMatchScore?
    /// Set only after Apple Watch confirms its HealthKit session is collecting.
    var watchWorkoutStartedAt: Date?
    /// Set before launching the Watch app. Posting must not silently omit
    /// metrics merely because the startup acknowledgement was delayed or lost.
    var expectsWatchMetrics: Bool? = false
    /// Aggregate metrics received when the Watch finalizes its HealthKit workout.
    var workoutMetrics: WorkoutMetrics?
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
        workoutMetrics = session.workoutMetrics
        activities = session.sortedActivities.map(DraftActivity.init(activity:))
        postToFeed = session.posted
        existingPhotoPath = session.photoPath
    }
}
