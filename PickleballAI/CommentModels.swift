import Foundation

// MARK: - Comments

struct Comment: Identifiable, Decodable, Hashable {
    let id: UUID
    let sessionId: UUID
    let userId: UUID
    let body: String
    let createdAt: String
    var author: ParticipantProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case userId = "user_id"
        case body
        case createdAt = "created_at"
        case author
    }

    var date: Date { FeedSession.parse(createdAt) }
    var authorName: String { author?.displayName ?? "Player" }
    var authorInitials: String {
        if let a = author?.avatarInitials, !a.isEmpty { return a }
        let letters = (author?.displayName ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct NewComment: Encodable {
    let sessionId: UUID
    let userId: UUID
    let body: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case userId = "user_id"
        case body
    }
}
