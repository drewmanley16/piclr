import Foundation
import Supabase

// MARK: - Realtime

extension AppStore {
    /// Subscribe to `sessions` changes so new posts (yours or people you follow)
    /// surface in the feed live, without a manual refresh.
    func startRealtime(userId: UUID) {
        stopRealtime()
        sessionsRealtime.start(channelName: "public:sessions") { channel in
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "sessions",
                select: ["id", "user_id", "posted"]
            )
            return [{ [weak self] in
                await channel.subscribe()
                for await change in changes {
                    self?.handleSessionChange(change, userId: userId)
                    if Task.isCancelled { break }
                }
            }]
        }

        // Live badge: reload notifications when a new one arrives for this user.
        notificationsRealtime.start(channelName: "public:notifications:\(userId.uuidString)") { channel in
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "notifications",
                filter: "user_id=eq.\(userId.uuidString)"
            )
            return [{ [weak self] in
                await channel.subscribe()
                for await _ in changes {
                    await self?.loadNotifications(userId: userId)
                    if Task.isCancelled { break }
                }
            }]
        }

        // Live follow graph: reload counts/lists when someone follows or
        // requests me (incoming), or accepts my request (outgoing). Two filters
        // on one channel — Realtime allows a single filter per subscription.
        followsRealtime.start(channelName: "public:follows:\(userId.uuidString)") { channel in
            let incoming = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "follows",
                filter: "followee_id=eq.\(userId.uuidString)"
            )
            let outgoing = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "follows",
                filter: "follower_id=eq.\(userId.uuidString)"
            )
            return [
                { [weak self] in
                    await channel.subscribe()
                    for await _ in incoming {
                        // Someone followed/requested me → my counts + request banner.
                        await self?.reloadFollowGraph(userId: userId, refreshFeed: false)
                        if Task.isCancelled { break }
                    }
                },
                { [weak self] in
                    for await _ in outgoing {
                        // A request I sent was accepted → I now follow them, so their
                        // sessions belong in my feed.
                        await self?.reloadFollowGraph(userId: userId, refreshFeed: true)
                        if Task.isCancelled { break }
                    }
                }
            ]
        }

        // Live invites: reload when an invite or an RSVP to one changes.
        invitesRealtime.start(channelName: "public:session_invites:\(userId.uuidString)") { channel in
            let inviteChanges = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "session_invites"
            )
            let inviteRecipientChanges = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "invite_recipients"
            )
            return [
                { [weak self] in
                    await channel.subscribe()
                    for await _ in inviteChanges {
                        await self?.loadActiveInvites(userId: userId)
                        if Task.isCancelled { break }
                    }
                },
                { [weak self] in
                    for await _ in inviteRecipientChanges {
                        await self?.loadActiveInvites(userId: userId)
                        if Task.isCancelled { break }
                    }
                }
            ]
        }
    }

    private func handleSessionChange(_ change: AnyAction, userId: UUID) {
        let record: JSONObject
        let isDelete: Bool
        switch change {
        case .insert(let action):
            record = action.record
            isDelete = false
        case .update(let action):
            record = action.record
            isDelete = false
        case .delete(let action):
            record = action.oldRecord
            isDelete = true
        }

        let sessionID = record["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        if isDelete, let sessionID {
            feed.removeAll { $0.id == sessionID || $0.repostedFrom == sessionID }
            discoverFeed.removeAll { $0.id == sessionID || $0.repostedFrom == sessionID }
            mySessions.removeAll { $0.id == sessionID || $0.repostedFrom == sessionID }
            return
        }

        guard let authorID = record["user_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            // Older Realtime payloads may omit selected columns. Coalesce one
            // conservative refresh instead of reloading three datasets per event.
            scheduleRealtimeRefresh(feed: true, mySessions: false, discover: !discoverFeed.isEmpty, userId: userId)
            return
        }

        let posted = record["posted"]?.boolValue ?? true
        let alreadyInFeed = sessionID.map { id in feed.contains { $0.id == id } } ?? false
        let alreadyInDiscover = sessionID.map { id in discoverFeed.contains { $0.id == id } } ?? false
        let sourceIsInFeed = sessionID.map { id in feed.contains { $0.repostedFrom == id } } ?? false
        let sourceIsInDiscover = sessionID.map { id in discoverFeed.contains { $0.repostedFrom == id } } ?? false
        let sourceIsInMySessions = sessionID.map { id in mySessions.contains { $0.repostedFrom == id } } ?? false
        let feedAuthorIsVisible = authorID == userId || acceptedFollowingUserIDs.contains(authorID)
        let refreshFeed = sourceIsInFeed || (feedAuthorIsVisible && (posted || alreadyInFeed))
        // Private workout credits are unposted wrappers owned by the tagged
        // friend. Refresh every own-session change so an automatic credit
        // appears without requiring a pull-to-refresh.
        let refreshMine = sourceIsInMySessions || authorID == userId
        let refreshDiscover = !discoverFeed.isEmpty
            && (sourceIsInDiscover || (authorID != userId && (posted || alreadyInDiscover)))
        scheduleRealtimeRefresh(
            feed: refreshFeed,
            mySessions: refreshMine,
            discover: refreshDiscover,
            userId: userId
        )
    }

    private func scheduleRealtimeRefresh(
        feed: Bool,
        mySessions: Bool,
        discover: Bool,
        userId: UUID
    ) {
        guard feed || mySessions || discover else { return }
        realtimeNeedsFeedRefresh = realtimeNeedsFeedRefresh || feed
        realtimeNeedsMySessionsRefresh = realtimeNeedsMySessionsRefresh || mySessions
        realtimeNeedsDiscoverRefresh = realtimeNeedsDiscoverRefresh || discover
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, self.currentProfile?.id == userId else { return }
            let refreshFeed = self.realtimeNeedsFeedRefresh
            let refreshMine = self.realtimeNeedsMySessionsRefresh
            let refreshDiscover = self.realtimeNeedsDiscoverRefresh
            self.realtimeNeedsFeedRefresh = false
            self.realtimeNeedsMySessionsRefresh = false
            self.realtimeNeedsDiscoverRefresh = false
            async let feedLoad: Void = refreshFeed ? self.loadFeed() : ()
            async let mySessionsLoad: Void = refreshMine ? self.loadMySessions(userId: userId) : ()
            async let discoverLoad: Void = refreshDiscover ? self.loadDiscover() : ()
            _ = await (feedLoad, mySessionsLoad, discoverLoad)
        }
    }

    private func reloadFollowGraph(userId: UUID, refreshFeed: Bool) async {
        await loadFollowState(userId: userId)
        await loadFollowLists(userId: userId)
        if refreshFeed {
            await loadFeed()
            if !discoverFeed.isEmpty { await loadDiscover() }
        }
    }

    func stopRealtime() {
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        commentsRefreshDebounceTask?.cancel()
        commentsRefreshDebounceTask = nil
        commentsRefreshPending = false
        realtimeNeedsFeedRefresh = false
        realtimeNeedsMySessionsRefresh = false
        realtimeNeedsDiscoverRefresh = false
        sessionsRealtime.stop()
        notificationsRealtime.stop()
        followsRealtime.stop()
        invitesRealtime.stop()
        commentsRealtime.stop()
    }

    // MARK: - Comments realtime

    /// Subscribes to thread and reaction changes for one session. Comment hard
    /// deletes remain pull-to-refresh events because Supabase cannot safely apply
    /// RLS filters to deleted rows; inserts, tombstone updates, and new likes are live.
    func startCommentsRealtime(sessionId: UUID, onChange: @escaping () async -> Void) {
        commentsRealtime.start(channelName: "comments:\(sessionId.uuidString)") { channel in
            let commentInserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "comments",
                filter: "session_id=eq.\(sessionId.uuidString)"
            )
            let commentUpdates = channel.postgresChange(
                UpdateAction.self,
                schema: "public",
                table: "comments",
                filter: "session_id=eq.\(sessionId.uuidString)"
            )
            let likeInserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "comment_likes",
                filter: "session_id=eq.\(sessionId.uuidString)"
            )
            return [
                { [weak self] in
                    await channel.subscribe()
                    for await _ in commentInserts {
                        self?.scheduleCommentsRefresh(onChange)
                        if Task.isCancelled { break }
                    }
                },
                { [weak self] in
                    for await _ in commentUpdates {
                        self?.scheduleCommentsRefresh(onChange)
                        if Task.isCancelled { break }
                    }
                },
                { [weak self] in
                    for await _ in likeInserts {
                        self?.scheduleCommentsRefresh(onChange)
                        if Task.isCancelled { break }
                    }
                }
            ]
        }
    }

    /// Coalesces the three comment/like streams into serial reloads. Events that
    /// arrive during the delay join the pending reload; events during a reload
    /// schedule one follow-up without cancelling the request already in flight.
    private func scheduleCommentsRefresh(_ onChange: @escaping () async -> Void) {
        commentsRefreshPending = true
        guard commentsRefreshDebounceTask == nil else { return }

        commentsRefreshDebounceTask = Task { [weak self] in
            while let self, self.commentsRefreshPending {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                self.commentsRefreshPending = false
                await onChange()
            }
            self?.commentsRefreshPending = false
            self?.commentsRefreshDebounceTask = nil
        }
    }

    func stopCommentsRealtime() {
        commentsRefreshDebounceTask?.cancel()
        commentsRefreshDebounceTask = nil
        commentsRefreshPending = false
        commentsRealtime.stop()
    }
}
