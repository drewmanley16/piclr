import Foundation

// MARK: - Session invites (RSVP)

struct Court: Identifiable, Decodable, Hashable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude
    }
}

struct NewCourt: Encodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let createdBy: UUID

    enum CodingKeys: String, CodingKey {
        case name, latitude, longitude
        case createdBy = "created_by"
    }
}

enum RSVPStatus: String, Codable, CaseIterable {
    case pending, yes, no, maybe

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .yes:     return "Yes"
        case .no:      return "No"
        case .maybe:   return "Maybe"
        }
    }
}

struct SessionInvite: Identifiable, Decodable, Hashable {
    let id: UUID
    let hostId: UUID
    let courtId: UUID
    let scheduledAt: String
    let note: String?
    let createdAt: String
    let cancelledAt: String?
    var host: ParticipantProfile?
    var court: Court?
    var recipients: [InviteRecipient]?

    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case courtId = "court_id"
        case scheduledAt = "scheduled_at"
        case note
        case createdAt = "created_at"
        case cancelledAt = "cancelled_at"
        case host, court, recipients
    }

    var scheduledAtDate: Date { FeedSession.parse(scheduledAt) }
    var createdAtDate: Date { FeedSession.parse(createdAt) }
    var isPast: Bool { scheduledAtDate < Date() }
    var isCancelled: Bool { cancelledAt != nil }

    func myResponse(userId: UUID) -> RSVPStatus? {
        recipients?.first { $0.userId == userId }.flatMap { RSVPStatus(rawValue: $0.status) }
    }

    var yesCount: Int { recipients?.filter { $0.status == "yes" }.count ?? 0 }
}

struct NewSessionInvite: Encodable {
    let hostId: UUID
    let courtId: UUID
    let scheduledAt: Date
    let note: String?

    enum CodingKeys: String, CodingKey {
        case hostId = "host_id"
        case courtId = "court_id"
        case scheduledAt = "scheduled_at"
        case note
    }
}

struct InviteRecipient: Identifiable, Decodable, Hashable {
    let id: UUID
    let inviteId: UUID
    let userId: UUID
    let status: String
    var user: ParticipantProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case inviteId = "invite_id"
        case userId = "user_id"
        case status, user
    }
}

struct NewInviteRecipient: Encodable {
    let inviteId: UUID
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case inviteId = "invite_id"
        case userId = "user_id"
    }
}

struct InviteRecipientUpdate: Encodable {
    let status: String
    let respondedAt: Date

    enum CodingKeys: String, CodingKey {
        case status
        case respondedAt = "responded_at"
    }
}

struct InviteCancellationUpdate: Encodable {
    let cancelledAt: String

    init(cancelledAt: Date) {
        // DateFormatting.iso matches ISO8601DateFormatter's default options
        // (.withInternetDateTime), so the wire format is unchanged.
        self.cancelledAt = DateFormatting.iso.string(from: cancelledAt)
    }

    enum CodingKeys: String, CodingKey {
        case cancelledAt = "cancelled_at"
    }
}
