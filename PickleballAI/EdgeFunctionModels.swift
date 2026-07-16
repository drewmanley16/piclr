import Foundation

// MARK: - Edge function payloads

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
