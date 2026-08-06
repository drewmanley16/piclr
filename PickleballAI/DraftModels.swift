import Foundation

// MARK: - On-device session draft (built live, written on Finish & Post)

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
    var notes: String = ""
    var partners: [DraftPlayer] = []
    var opponents: [DraftPlayer] = []
    var teamScore: Int = 11
    var opponentScore: Int = 9
    var matchFormat: MatchFormat = .doubles
    /// Decode-only marker for an activity restored from a draft written before
    /// practice logging was removed. Such entries carry no score worth keeping,
    /// so `restorePersistedDraft` drops them rather than resurrecting them as
    /// bogus 11–9 matches. Absent from `CodingKeys`, so it is never persisted.
    var isLegacyPractice = false

    var won: Bool { teamScore > opponentScore }
    var isTie: Bool { teamScore == opponentScore }
    var maxPartners: Int { matchFormat == .singles ? 0 : Self.doublesMaxPartners }
    var maxOpponents: Int { matchFormat == .singles ? 1 : Self.doublesMaxOpponents }
    /// What to persist in `won`: nil for a tie (neither win nor loss), so ties
    /// never count against a record on the server (leaderboard, rivalries).
    var wonValue: Bool? {
        teamScore == opponentScore ? nil : teamScore > opponentScore
    }
    var summary: String { "Match \(teamScore)–\(opponentScore)" }

    private enum CodingKeys: String, CodingKey {
        case id, notes, partners, opponents, teamScore, opponentScore, matchFormat
    }

    /// Read-only: `kind` is no longer a property, but drafts persisted before
    /// practice logging was removed still carry it. Kept out of `CodingKeys` so
    /// it is never written back.
    private enum LegacyCodingKeys: String, CodingKey {
        case kind
    }

    init() {}

    /// `matchFormat` was added after live drafts were already persisted on
    /// device. Decode it leniently so an in-progress pre-update session resumes
    /// as doubles instead of being discarded. `kind` is likewise read-only
    /// legacy: it disappeared with practice logging.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        partners = try values.decodeIfPresent([DraftPlayer].self, forKey: .partners) ?? []
        opponents = try values.decodeIfPresent([DraftPlayer].self, forKey: .opponents) ?? []
        teamScore = try values.decodeIfPresent(Int.self, forKey: .teamScore) ?? 11
        opponentScore = try values.decodeIfPresent(Int.self, forKey: .opponentScore) ?? 9
        matchFormat = try values.decodeIfPresent(MatchFormat.self, forKey: .matchFormat) ?? .doubles

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        isLegacyPractice = try legacy.decodeIfPresent(String.self, forKey: .kind) == "practice"
    }

    /// Build a finished match activity from a watch live-game score. US → team,
    /// THEM → opponents. Players are attached on the phone before posting.
    init(liveMatch: LiveMatchScore) {
        teamScore = liveMatch.us
        opponentScore = liveMatch.them
    }

    /// New match, optionally carrying forward the partners/opponents of `previous`
    /// (the prior match in a live session), so players don't have to be re-picked
    /// every game. Player structs get fresh ids — `updateSession` writes
    /// `DraftPlayer.id` as the `activity_participants` row id, so reusing ids
    /// across activities would collide on the backend.
    init(carryingPlayersFrom previous: DraftActivity?) {
        guard let previous else { return }
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
