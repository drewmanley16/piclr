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
    private let likes: [CountRow]?
    private let comments: [CountRow]?

    var likeCount: Int { likes?.first?.count ?? 0 }
    var commentCount: Int { comments?.first?.count ?? 0 }

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
        case author, likes, comments
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

struct FriendRequest: Identifiable, Decodable, Hashable {
    let id: UUID
    let requesterId: UUID
    let addresseeId: UUID
    let status: String
    let createdAt: String
    let requester: Profile?
    let addressee: Profile?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case addresseeId = "addressee_id"
        case status
        case createdAt = "created_at"
        case requester, addressee
    }

    func otherProfile(for userId: UUID) -> Profile? {
        requesterId == userId ? addressee : requester
    }

    func otherUserId(for userId: UUID) -> UUID {
        requesterId == userId ? addresseeId : requesterId
    }
}

struct ContactMatch: Identifiable, Decodable, Hashable {
    var id: UUID { profile.id }
    let phone: String
    let profile: Profile
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
    let userId: UUID
    let title: String?
    let location: String?
    let durationMinutes: Int
    let focus: String?
    let takeaway: String?
    let posted: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case title, location
        case durationMinutes = "duration_minutes"
        case focus, takeaway, posted
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

struct NewFriendRequest: Encodable {
    let requesterId: UUID
    let addresseeId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case requesterId = "requester_id"
        case addresseeId = "addressee_id"
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
