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

    /// True for notifications the app raises about you, to you — milestones,
    /// streak nudges, the weekly wrap. They carry no actor, so there is no
    /// avatar to draw: the row shows `icon` in an accent circle instead of an
    /// initials fallback, which would render a meaningless "?".
    var isSelfGenerated: Bool { actor == nil }

    private var handle: String { actor.map { "@\($0.username)" } ?? "Someone" }

    var message: String {
        if let detail, !detail.isEmpty { return detail }
        switch type {
        case "like":            return "\(handle) liked your session"
        case "comment":         return "\(handle) commented: \(comment?.body ?? "")"
        case "comment_reply":   return "\(handle) replied: \(comment?.body ?? "")"
        case "comment_like":    return "\(handle) liked your comment"
        case "mention":         return "\(handle) mentioned you: \(comment?.body ?? "")"
        case "follow":          return "\(handle) started following you"
        case "tag":             return "\(handle) tagged you in a session"
        case "repost":          return "\(handle) reposted your session"
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
        case "comment_reply": return "arrowshape.turn.up.left.fill"
        case "comment_like": return "hand.thumbsup.fill"
        case "mention": return "at"
        case "follow":  return "person.fill.badge.plus"
        case "tag":     return "flag.checkered"
        case "repost", "repost_approved": return "arrow.2.squarepath"
        case "invite_received", "invite_response": return "figure.pickleball"
        case "invite_cancelled": return "xmark.circle.fill"
        case "rivalry": return "flame.fill"
        case "streak":  return "circle.hexagongrid.fill"
        case "weekly_wrap": return "sparkles"
        case "milestone_unlocked": return "medal.fill"
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
