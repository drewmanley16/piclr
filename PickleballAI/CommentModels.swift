import Foundation

// MARK: - Comments

struct Comment: Identifiable, Decodable, Hashable {
    let id: UUID
    let sessionId: UUID
    let userId: UUID
    let parentId: UUID?
    let body: String
    let createdAt: String
    let deletedAt: String?
    private let likes: [CountRow]?
    var author: ParticipantProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case userId = "user_id"
        case parentId = "parent_id"
        case body
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case likes
        case author
    }

    var date: Date { FeedSession.parse(createdAt) }
    var isReply: Bool { parentId != nil }
    var isDeleted: Bool { deletedAt != nil }
    var likeCount: Int { likes?.first?.count ?? 0 }
    var authorName: String { isDeleted ? "Deleted" : author?.displayName ?? "Player" }
    var authorInitials: String {
        if isDeleted { return "–" }
        if let a = author?.avatarInitials, !a.isEmpty { return a }
        let letters = (author?.displayName ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct CommentThread: Identifiable, Hashable {
    let comment: Comment
    let replies: [Comment]

    var id: UUID { comment.id }
}

struct NewComment: Encodable {
    let sessionId: UUID
    let userId: UUID
    let parentId: UUID?
    let body: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case userId = "user_id"
        case parentId = "parent_id"
        case body
    }
}

struct NewCommentLike: Encodable {
    let commentId: UUID
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case commentId = "comment_id"
        case userId = "user_id"
    }
}

struct CommentLikeRow: Decodable {
    let commentId: UUID

    enum CodingKeys: String, CodingKey {
        case commentId = "comment_id"
    }
}
