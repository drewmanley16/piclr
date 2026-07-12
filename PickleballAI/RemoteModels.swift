import Foundation

// MARK: - Read models

struct Profile: Identifiable, Decodable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var avatarInitials: String?
    var homeCourt: String?
    var rating: Double?
    var preferredSide: String?
    var heightInches: Double?
    var weightPounds: Double?
    var shoeSize: Double?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarInitials = "avatar_initials"
        case homeCourt = "home_court"
        case rating
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
