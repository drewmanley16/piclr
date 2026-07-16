import Foundation
import Supabase

// MARK: - Session invites (RSVP)

extension AppStore {
    private static let selectInvite = "*, host:profiles!session_invites_host_id_fkey(\(AppStore.selectProfileLite)), court:courts(*), recipients:invite_recipients(*, user:profiles!invite_recipients_user_id_fkey(\(AppStore.selectProfileLite)))"

    /// Mutual followers only — the pool of people you're allowed to tag on an
    /// invite (matches the `is_mutual_follow` RLS check on `invite_recipients`).
    var mutualFriends: [FollowListEntry] {
        followers.filter { $0.isFollowedByMe }
    }

    /// Upcoming, non-cancelled invites visible to the signed-in user (hosted by
    /// them or tagged in). RLS already scopes rows to what's visible.
    func loadActiveInvites(userId: UUID) async {
        do {
            let rows: [SessionInvite] = try await supabase
                .from("session_invites")
                .select(Self.selectInvite)
                .is("cancelled_at", value: nil)
                .gte("scheduled_at", value: DateFormatting.iso.string(from: Date()))
                .order("scheduled_at", ascending: true)
                .execute()
                .value
            guard currentProfile?.id == userId else { return }
            var hydrated: [SessionInvite] = []
            for var invite in rows {
                if let host = invite.host { invite.host = await media.hydrateParticipantProfile(host) }
                hydrated.append(invite)
            }
            activeInvites = hydrated
        } catch {
            reportError(error)
        }
    }

    /// Loads one invite for notification/deep-link detail, including cancelled
    /// or elapsed invites that no longer belong in the Upcoming list.
    func loadInvite(inviteId: UUID) async -> SessionInvite? {
        do {
            let rows: [SessionInvite] = try await supabase
                .from("session_invites")
                .select(Self.selectInvite)
                .eq("id", value: inviteId.uuidString)
                .limit(1)
                .execute()
                .value
            guard var invite = rows.first else { return nil }
            if let host = invite.host { invite.host = await media.hydrateParticipantProfile(host) }
            return invite
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Finds an existing court within ~50m of the given coordinate, or creates
    /// one. Dedupes repeat invites at the same place picked via MapKit search
    /// without needing a separate search-or-create registry UI.
    func findOrCreateCourt(name: String, latitude: Double, longitude: Double) async -> Court? {
        guard let uid = currentProfile?.id else { return nil }
        // ~50m in degrees of latitude; longitude tolerance widened slightly
        // since a degree of longitude shrinks away from the equator.
        let latDelta = 0.00045
        let lonDelta = 0.0006
        do {
            let nearby: [Court] = try await supabase
                .from("courts")
                .select()
                .gte("latitude", value: latitude - latDelta)
                .lte("latitude", value: latitude + latDelta)
                .gte("longitude", value: longitude - lonDelta)
                .lte("longitude", value: longitude + lonDelta)
                .limit(1)
                .execute()
                .value
            if let existing = nearby.first { return existing }

            let created: [Court] = try await supabase
                .from("courts")
                .insert(NewCourt(name: name, latitude: latitude, longitude: longitude, createdBy: uid))
                .select()
                .execute()
                .value
            return created.first
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Creates an invite and tags the given mutual-follower friends (RLS
    /// enforces the mutual-follow requirement per recipient).
    @discardableResult
    func createInvite(courtId: UUID, scheduledAt: Date, note: String?, recipientIds: [UUID]) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created: [SessionInvite] = try await supabase
                .from("session_invites")
                .insert(NewSessionInvite(hostId: uid, courtId: courtId, scheduledAt: scheduledAt, note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote))
                .select()
                .execute()
                .value
            guard let invite = created.first else { return false }
            if !recipientIds.isEmpty {
                try await supabase
                    .from("invite_recipients")
                    .insert(recipientIds.map { NewInviteRecipient(inviteId: invite.id, userId: $0) })
                    .execute()
            }
            await loadActiveInvites(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func respondToInvite(_ invite: SessionInvite, status: RSVPStatus) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase
                .from("invite_recipients")
                .update(InviteRecipientUpdate(status: status.rawValue, respondedAt: Date()))
                .eq("invite_id", value: invite.id.uuidString)
                .eq("user_id", value: uid.uuidString)
                .execute()
            await loadActiveInvites(userId: uid)
        } catch {
            reportError(error)
        }
    }

    /// Soft-cancels an invite. The database enforces host ownership and emits
    /// one cancellation notification for every invited recipient.
    @discardableResult
    func cancelInvite(_ invite: SessionInvite) async -> Bool {
        guard let uid = currentProfile?.id,
              invite.hostId == uid,
              !invite.isCancelled,
              !invite.isPast else { return false }
        do {
            try await supabase
                .from("session_invites")
                .update(InviteCancellationUpdate(cancelledAt: Date()))
                .eq("id", value: invite.id.uuidString)
                .eq("host_id", value: uid.uuidString)
                .is("cancelled_at", value: nil)
                .execute()
            activeInvites.removeAll { $0.id == invite.id }
            return true
        } catch {
            reportError(error)
            return false
        }
    }
}
