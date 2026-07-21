import Foundation
import Supabase

// MARK: - Notifications

extension AppStore {
    /// Follow requests that still need an action.
    var pendingNotificationCount: Int { incomingFollowRequests.count }

    var unreadNotificationCount: Int { notifications.filter { !$0.read }.count }

    /// Total count shown on the bell badge: actionable requests + unread activity.
    var badgeCount: Int { pendingNotificationCount + unreadNotificationCount }

    func loadNotifications(userId: UUID) async {
        do {
            let rows: [AppNotification] = try await supabase
                .from("notifications")
                .select("id,type,read,created_at,detail, actor:profiles!notifications_actor_id_fkey(\(Self.selectProfileLite)), session:sessions!notifications_session_id_fkey(id,title), comment:comments!notifications_comment_id_fkey(id,body), invite:session_invites!notifications_invite_id_fkey(id, court:courts(name))")
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
            var hydrated: [AppNotification] = []
            for var notification in rows {
                if let actor = notification.actor {
                    notification.actor = await media.hydrateParticipantProfile(actor)
                }
                hydrated.append(notification)
            }
            guard currentProfile?.id == userId, !Task.isCancelled else { return }
            notifications = hydrated
        } catch {
            reportError(error)
        }
    }

    /// Loads and ranks the crew leaderboard: most wins first, then win rate,
    /// then games played. Players with no matches sink to the bottom.
    func loadLeaderboard() async {
        do {
            let rows: [LeaderboardEntry] = try await supabase
                .rpc("crew_leaderboard")
                .execute()
                .value
            leaderboard = rows.sorted {
                if $0.wins != $1.wins { return $0.wins > $1.wins }
                if $0.winRate != $1.winRate { return $0.winRate > $1.winRate }
                return $0.matches > $1.matches
            }
        } catch {
            reportError(error)
        }
    }

    func markNotificationsRead() async {
        guard let uid = currentProfile?.id, unreadNotificationCount > 0 else { return }
        do {
            try await supabase.from("notifications")
                .update(["read": true])
                .eq("user_id", value: uid.uuidString)
                .eq("read", value: false)
                .execute()
            await loadNotifications(userId: uid)
        } catch {
            reportError(error)
        }
    }
}
