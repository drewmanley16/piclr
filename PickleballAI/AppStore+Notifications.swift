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
    /// `period` narrows the match window server-side — `.month`/`.season` are
    /// Pro-only filters on top of the free `.all` view (see `LeaderboardSheet`).
    func loadLeaderboard(period: LeaderboardPeriod = .all) async {
        do {
            let rows: [LeaderboardEntry] = try await supabase
                .rpc("crew_leaderboard", params: ["p_period": period.rawValue])
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

    /// This user's unlocked milestone IDs, for the Milestones shelf.
    func loadMilestoneUnlocks() async {
        guard let uid = currentProfile?.id else { return }
        do {
            struct Row: Decodable {
                let milestoneId: String
                enum CodingKeys: String, CodingKey { case milestoneId = "milestone_id" }
            }
            let rows: [Row] = try await supabase
                .from("milestone_unlocks")
                .select("milestone_id")
                .eq("profile_id", value: uid.uuidString)
                .execute()
                .value
            milestoneUnlocks = Set(rows.map(\.milestoneId))
            await reconcileMilestoneUnlocks(playerID: uid)
        } catch {
            reportError(error)
        }
    }

    /// Records any threshold this player's stats already satisfy but that never
    /// made it into `milestone_unlocks` — thresholds crossed before the shelf
    /// existed, or an `unlock_milestone` call that failed. The post-session diff
    /// in `unlockNewlyCrossedMilestones` can't recover either case: once a
    /// threshold is satisfied it lands in *both* sides of every later diff, so a
    /// badge missed once is missed forever without this sweep.
    ///
    /// Writes the rows directly rather than through `unlock_milestone`, so a
    /// player backfilling ten old badges at once doesn't get ten notifications
    /// for matches they played weeks ago. The live diff still owns the
    /// celebratory path for thresholds crossed in the moment.
    private func reconcileMilestoneUnlocks(playerID: UUID) async {
        let satisfied = Milestone.satisfiedIDs(for: SessionStats(sessions: mySessions, playerID: playerID))
        let missing = satisfied.subtracting(milestoneUnlocks)
        guard !missing.isEmpty else { return }
        struct UnlockInsert: Encodable {
            let profileId: UUID
            let milestoneId: String
            enum CodingKeys: String, CodingKey {
                case profileId = "profile_id"
                case milestoneId = "milestone_id"
            }
        }
        do {
            try await supabase
                .from("milestone_unlocks")
                .upsert(missing.map { UnlockInsert(profileId: playerID, milestoneId: $0) },
                        onConflict: "profile_id,milestone_id")
                .execute()
            milestoneUnlocks.formUnion(missing)
        } catch {
            // Non-fatal: the shelf still renders what did load, and the next
            // load retries the sweep.
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
