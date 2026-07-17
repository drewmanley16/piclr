import Foundation

// MARK: - Activity notifications

struct AppNotification: Identifiable, Decodable, Hashable {
    let id: UUID
    let type: String
    let read: Bool
    let createdAt: String
    /// Pre-rendered phrase for notifications the generic actor/type message can't
    /// express (e.g. a rivalry's exact record). When present it wins.
    let detail: String?
    var actor: ParticipantProfile?
    let session: NotifSessionRef?
    let comment: NotifCommentRef?
    let invite: NotifInviteRef?

    enum CodingKeys: String, CodingKey {
        case id, type, read, detail
        case createdAt = "created_at"
        case actor, session, comment, invite
    }

    var date: Date { FeedSession.parse(createdAt) }

    var actorInitials: String {
        if let a = actor?.avatarInitials, !a.isEmpty { return a }
        let letters = (actor?.displayName ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var handle: String { actor.map { "@\($0.username)" } ?? "Someone" }

    var message: String {
        if let detail, !detail.isEmpty { return detail }
        switch type {
        case "like":            return "\(handle) liked your session"
        case "comment":         return "\(handle) commented: \(comment?.body ?? "")"
        case "follow":          return "\(handle) started following you"
        case "tag":             return "\(handle) tagged you in a session"
        case "repost_approved": return "\(handle) approved your repost"
        case "invite_received": return "\(handle) invited you to play at \(invite?.courtName ?? "a court")"
        case "invite_response":  return "\(handle) responded to your invite"
        case "invite_cancelled": return "\(handle) canceled the invite"
        case "rivalry":         return "\(handle) played you"
        default:                return "\(handle) interacted with your post"
        }
    }

    var icon: String {
        switch type {
        case "like":    return "hand.thumbsup.fill"
        case "comment": return "bubble.right.fill"
        case "follow":  return "person.fill.badge.plus"
        case "tag":     return "flag.checkered"
        case "invite_received", "invite_response": return "figure.pickleball"
        case "invite_cancelled": return "xmark.circle.fill"
        case "rivalry": return "flame.fill"
        default:        return "bell.fill"
        }
    }
}

struct NotifSessionRef: Decodable, Hashable {
    let id: UUID
    let title: String?
}

struct NotifCommentRef: Decodable, Hashable {
    let id: UUID
    let body: String
}

struct NotifInviteRef: Decodable, Hashable {
    let id: UUID
    let court: NotifCourtRef?
    var courtName: String? { court?.name }
}

struct NotifCourtRef: Decodable, Hashable {
    let name: String
}
