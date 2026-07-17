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
        avatarPath: String? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.firstName = firstName
        self.lastName = lastName
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

/// A lightweight profile embedded in other records (activities, comments,
/// notifications, invites). Shared across many domains but profile-shaped.
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

    /// Stable `Identifiable` key: the profile id when present, else the guest's
    /// name (guests have no account to key on).
    var id: String { profileId?.uuidString ?? "guest:\(displayName)" }

    init(profile: Profile) {
        profileId = profile.id
        displayName = profile.displayName
        handle = "@\(profile.username)"
        avatarURL = profile.avatarURL
        initials = profile.initials
    }

    init(participant: ParticipantProfile) {
        profileId = participant.id
        displayName = participant.displayName
        handle = "@\(participant.username)"
        avatarURL = participant.avatarURL
        initials = participant.initials
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
/// `sessions` is only populated when `relationship.canViewContent` is true;
/// otherwise it's empty and the UI shows a "This profile is private" state.
struct PublicProfile {
    let profile: Profile
    var relationship: FollowRelationship
    let followerCount: Int
    let followingCount: Int
    var sessions: [FeedSession]
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
