import Foundation

// MARK: - Edge function payloads

struct DeleteAccountResponse: Decodable {
    let deleted: Bool
}

struct CompleteOnboardingRequest: Encodable {
    let firstName: String
    let lastName: String
    let displayName: String
    let username: String
    let avatarInitials: String
    let skillLevel: String
    let duprRating: Double?

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
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

struct UsernameAvailabilityRequest: Encodable {
    let username: String
    let checkUsernameOnly: Bool

    enum CodingKeys: String, CodingKey {
        case username
        case checkUsernameOnly = "check_username_only"
    }
}

struct UsernameAvailabilityResponse: Decodable {
    let available: Bool
}

struct MatchContactsRequest: Encodable {
    let phones: [String]
}

struct MatchContactsResponse: Decodable {
    let matches: [ContactMatch]
}
