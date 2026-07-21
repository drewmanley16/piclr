import Foundation
import Supabase

// MARK: - Reposts

extension AppStore {
    /// Publishes an existing private workout credit as a repost. Tagged mutual
    /// friends are credited automatically; this action only changes feed
    /// visibility and never duplicates the canonical match data.
    @discardableResult
    func repostSession(_ session: FeedSession) async -> Bool {
        guard currentProfile?.id != nil,
              !session.isRepost,
              isTaggedInSession(session)
        else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.rpc(
                "repost_session",
                params: ["source_session_id": session.id.uuidString]
            )
                .execute()
            Analytics.capture(.repostRequested)
            guard let uid = currentProfile?.id else { return true }
            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    /// Removes only the public repost while preserving the automatic private
    /// workout credit and its contribution to the player's record.
    @discardableResult
    func unrepostSession(_ session: FeedSession) async -> Bool {
        guard let uid = currentProfile?.id,
              session.userId == uid,
              session.isRepost,
              session.posted
        else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.rpc(
                "unrepost_session",
                params: ["wrapper_session_id": session.id.uuidString]
            ).execute()
            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    /// Opting out of an automatic workout credit also removes the player's tag
    /// from the source session so an author edit cannot recreate the credit.
    @discardableResult
    func removeWorkoutCredit(_ session: FeedSession) async -> Bool {
        guard let uid = currentProfile?.id,
              session.userId == uid,
              let sourceSessionId = session.repostedFrom
        else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.rpc(
                "remove_self_from_session",
                params: ["target_session_id": sourceSessionId.uuidString]
            ).execute()
            await loadMySessions(userId: uid)
            await loadFeed()
            await loadNotifications(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    private func isTaggedInSession(_ session: FeedSession) -> Bool {
        guard let uid = currentProfile?.id else { return false }
        return session.isParticipant(uid)
    }
}
