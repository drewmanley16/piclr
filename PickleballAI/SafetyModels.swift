import Foundation

// MARK: - Blocking & reporting

struct BlockedAccount: Identifiable, Decodable, Hashable {
    let blockedId: UUID
    let blockedUsername: String
    let blockedDisplayName: String
    let blockedAvatarPath: String?
    let createdAt: String

    var id: UUID { blockedId }
    var initials: String {
        let letters = blockedDisplayName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case blockedId = "blocked_id"
        case blockedUsername = "blocked_username"
        case blockedDisplayName = "blocked_display_name"
        case blockedAvatarPath = "blocked_avatar_path"
        case createdAt = "created_at"
    }
}

enum ReportTarget: Identifiable, Hashable {
    case user(UUID)
    case session(UUID)
    case comment(UUID)

    var id: String { "\(type):\(targetId.uuidString)" }
    var targetId: UUID {
        switch self {
        case .user(let id), .session(let id), .comment(let id): return id
        }
    }
    var type: String {
        switch self {
        case .user: return "user"
        case .session: return "session"
        case .comment: return "comment"
        }
    }
    var title: String {
        switch self {
        case .user: return "Report player"
        case .session: return "Report session"
        case .comment: return "Report comment"
        }
    }
}

enum ReportReason: String, CaseIterable, Identifiable {
    case harassment
    case spam
    case impersonation
    case inappropriate
    case cheating
    case other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .harassment: return "Harassment or bullying"
        case .spam: return "Spam"
        case .impersonation: return "Impersonation"
        case .inappropriate: return "Inappropriate content"
        case .cheating: return "Cheating or fraud"
        case .other: return "Other"
        }
    }
}

struct NewBlock: Encodable {
    let blockerId: UUID
    let blockedId: UUID

    enum CodingKeys: String, CodingKey {
        case blockerId = "blocker_id"
        case blockedId = "blocked_id"
    }
}

struct NewReport: Encodable {
    let reporterId: UUID
    let targetType: String
    let targetId: UUID
    let reason: String
    let details: String?

    enum CodingKeys: String, CodingKey {
        case reporterId = "reporter_id"
        case targetType = "target_type"
        case targetId = "target_id"
        case reason, details
    }
}
