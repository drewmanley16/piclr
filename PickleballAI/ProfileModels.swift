import Foundation

// MARK: - Profile (read model)

struct Profile: Identifiable, Codable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var firstName: String?
    var lastName: String?
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
    /// Public Pro flag (from `profiles.is_pro`), safe to render on any user.
    var isPro: Bool
    var weeklyGoal: Int?
    var streakRemindersEnabled: Bool?
    var isPrivate: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case firstName = "first_name"
        case lastName = "last_name"
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
        case isPro = "is_pro"
        case weeklyGoal = "weekly_goal"
        case streakRemindersEnabled = "streak_reminders_enabled"
        case isPrivate = "is_private"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        displayName = try c.decode(String.self, forKey: .displayName)
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        avatarInitials = try c.decodeIfPresent(String.self, forKey: .avatarInitials)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        homeCourt = try c.decodeIfPresent(String.self, forKey: .homeCourt)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        skillLevel = try c.decodeIfPresent(String.self, forKey: .skillLevel)
        onboardingCompletedAt = try c.decodeIfPresent(String.self, forKey: .onboardingCompletedAt)
        paddle = try c.decodeIfPresent(String.self, forKey: .paddle)
        preferredSide = try c.decodeIfPresent(String.self, forKey: .preferredSide)
        heightInches = try c.decodeIfPresent(Double.self, forKey: .heightInches)
        weightPounds = try c.decodeIfPresent(Double.self, forKey: .weightPounds)
        shoeSize = try c.decodeIfPresent(Double.self, forKey: .shoeSize)
        birthday = try c.decodeIfPresent(String.self, forKey: .birthday)
        // Tolerate narrow selects that omit the column (defaults to non-Pro).
        isPro = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        weeklyGoal = try c.decodeIfPresent(Int.self, forKey: .weeklyGoal)
        streakRemindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .streakRemindersEnabled)
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
        firstName: String? = nil,
        lastName: String? = nil,
        avatarInitials: String? = nil,
        avatarURL: String? = nil,
        avatarPath: String? = nil,
        isPro: Bool = false
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.firstName = firstName
        self.lastName = lastName
        self.avatarInitials = avatarInitials
        self.avatarURL = avatarURL
        self.avatarPath = avatarPath
        self.isPro = isPro
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
        weeklyGoal = nil
        streakRemindersEnabled = nil
        isPrivate = nil
    }
}

/// A lightweight profile embedded in other records (activities, comments,
/// notifications, invites). Shared across many domains but profile-shaped.
struct ParticipantProfile: Decodable, Hashable {
    let id: UUID
    let username: String
    let displayName: String
    let avatarInitials: String?
    var avatarURL: String?
    let avatarPath: String?
    let isPro: Bool

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarInitials = "avatar_initials"
        case avatarURL = "avatar_url"
        case avatarPath = "avatar_path"
        case isPro = "is_pro"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarInitials = try c.decodeIfPresent(String.self, forKey: .avatarInitials)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        isPro = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
    }

    var initials: String {
        if let a = avatarInitials, !a.isEmpty { return a }
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    init(profile: Profile) {
        id = profile.id
        username = profile.username
        displayName = profile.displayName
        avatarInitials = profile.avatarInitials
        avatarURL = profile.avatarURL
        avatarPath = profile.avatarPath
        isPro = profile.isPro
    }
}

/// The minimum identity needed to render a person anywhere in the UI.
/// Models that represent people embed this so views can always show the real
/// avatar and navigate; a nil `profileId` means a guest — non-navigable by
/// construction.
struct PersonRef: Identifiable, Hashable, Codable {
    /// The account behind this person, or nil for a guest player with no profile.
    let profileId: UUID?
    let displayName: String
    let handle: String?
    let avatarURL: String?
    let initials: String
    /// Public Pro flag; false for guests (no account).
    var isPro: Bool = false

    /// Stable `Identifiable` key: the profile id when present, else the guest's
    /// name (guests have no account to key on).
    var id: String { profileId?.uuidString ?? "guest:\(displayName)" }

    init(profile: Profile) {
        profileId = profile.id
        displayName = profile.displayName
        handle = "@\(profile.username)"
        avatarURL = profile.avatarURL
        initials = profile.initials
        isPro = profile.isPro
    }

    init(participant: ParticipantProfile) {
        profileId = participant.id
        displayName = participant.displayName
        handle = "@\(participant.username)"
        avatarURL = participant.avatarURL
        initials = participant.initials
        isPro = participant.isPro
    }

    init(guestName: String) {
        profileId = nil
        displayName = guestName
        handle = nil
        avatarURL = nil
        let letters = guestName.split(separator: " ").prefix(2).compactMap { $0.first }
        initials = letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// A snapshot of another user's profile as seen by the signed-in user.
/// `sessions` holds the subject's posted sessions, visible to anyone.
struct PublicProfile {
    let profile: Profile
    var relationship: FollowRelationship
    let followerCount: Int
    let followingCount: Int
    var sessions: [FeedSession]

    /// Whether sessions and follower/following lists are visible to the
    /// signed-in user. Public accounts (or self/accepted-follow) are always
    /// visible; other private accounts show a "This account is private" lock.
    var contentVisible: Bool {
        profile.isPrivate != true || relationship == .isSelf || relationship == .following
    }
}

// MARK: - Profile write models

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

/// Lightweight partial-profile response for `select("id, is_private")` — the
/// full `Profile` type has non-optional `username`/`display_name` and throws
/// decoding a row that omits them.
struct PrivacyFlag: Decodable {
    let id: UUID
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case isPrivate = "is_private"
    }
}

struct PrivacyUpdate: Encodable {
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case isPrivate = "is_private"
    }
}

struct ProfileUpdate: Encodable {
    let firstName: String
    let lastName: String
    let displayName: String
    let homeCourt: String?
    let rating: Double?
    let preferredSide: String?
    let birthday: String?

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case displayName = "display_name"
        case homeCourt = "home_court"
        case rating
        case preferredSide = "preferred_side"
        case birthday
    }
}

struct GoalPrefsUpdate: Encodable {
    let weeklyGoal: Int
    let streakRemindersEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case weeklyGoal = "weekly_goal"
        case streakRemindersEnabled = "streak_reminders_enabled"
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
