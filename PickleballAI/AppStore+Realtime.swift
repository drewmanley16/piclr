import Foundation
import Supabase

// MARK: - Realtime

extension AppStore {
    /// Subscribe to `sessions` changes so new posts (yours or people you follow)
    /// surface in the feed live, without a manual refresh.
    func startRealtime(userId: UUID) {
        stopRealtime()
        let channel = supabase.channel("public:sessions")
        realtimeChannel = channel
        realtimeTask = Task { [weak self] in
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "sessions",
                select: ["id", "user_id", "posted"]
            )
            await channel.subscribe()
            for await change in changes {
                self?.handleSessionChange(change, userId: userId)
                if Task.isCancelled { break }
            }
        }

        // Live badge: reload notifications when a new one arrives for this user.
        let nChannel = supabase.channel("public:notifications:\(userId.uuidString)")
        notifChannel = nChannel
        notifTask = Task { [weak self] in
            let changes = nChannel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "notifications",
                filter: "user_id=eq.\(userId.uuidString)"
            )
            await nChannel.subscribe()
            for await _ in changes {
                await self?.loadNotifications(userId: userId)
                if Task.isCancelled { break }
            }
        }

        // Live follow graph: reload counts/lists when someone follows or
        // requests me (incoming), or accepts my request (outgoing). Two filters
        // on one channel — Realtime allows a single filter per subscription.
        let fChannel = supabase.channel("public:follows:\(userId.uuidString)")
        followsChannel = fChannel
        let incoming = fChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "follows",
            filter: "followee_id=eq.\(userId.uuidString)"
        )
        let outgoing = fChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "follows",
            filter: "follower_id=eq.\(userId.uuidString)"
        )
        followsInTask = Task { [weak self] in
            await fChannel.subscribe()
            for await _ in incoming {
                // Someone followed/requested me → my counts + request banner.
                await self?.reloadFollowGraph(userId: userId, refreshFeed: false)
                if Task.isCancelled { break }
            }
        }
        followsOutTask = Task { [weak self] in
            for await _ in outgoing {
                // A request I sent was accepted → I now follow them, so their
                // sessions belong in my feed.
                await self?.reloadFollowGraph(userId: userId, refreshFeed: true)
                if Task.isCancelled { break }
            }
        }

        // Live invites: reload when an invite or an RSVP to one changes.
        let iChannel = supabase.channel("public:session_invites:\(userId.uuidString)")
        invitesChannel = iChannel
        let inviteChanges = iChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "session_invites"
        )
        let inviteRecipientChanges = iChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "invite_recipients"
        )
        invitesTask = Task { [weak self] in
            await iChannel.subscribe()
            for await _ in inviteChanges {
                await self?.loadActiveInvites(userId: userId)
                if Task.isCancelled { break }
            }
        }
        inviteRecipientsTask = Task { [weak self] in
            for await _ in inviteRecipientChanges {
                await self?.loadActiveInvites(userId: userId)
                if Task.isCancelled { break }
            }
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
            feed.removeAll { $0.id == sessionID }
            discoverFeed.removeAll { $0.id == sessionID }
            mySessions.removeAll { $0.id == sessionID }
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
        let alreadyInMySessions = sessionID.map { id in mySessions.contains { $0.id == id } } ?? false
        let feedAuthorIsVisible = authorID == userId || acceptedFollowingUserIDs.contains(authorID)
        let refreshFeed = feedAuthorIsVisible && (posted || alreadyInFeed)
        let refreshMine = authorID == userId && (posted || alreadyInMySessions)
        let refreshDiscover = !discoverFeed.isEmpty && authorID != userId && (posted || alreadyInDiscover)
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
        if refreshFeed { await loadFeed() }
    }

    func stopRealtime() {
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        realtimeNeedsFeedRefresh = false
        realtimeNeedsMySessionsRefresh = false
        realtimeNeedsDiscoverRefresh = false
        realtimeTask?.cancel()
        realtimeTask = nil
        notifTask?.cancel()
        notifTask = nil
        followsInTask?.cancel()
        followsInTask = nil
        followsOutTask?.cancel()
        followsOutTask = nil
        invitesTask?.cancel()
        invitesTask = nil
        inviteRecipientsTask?.cancel()
        inviteRecipientsTask = nil
        if let channel = invitesChannel {
            invitesChannel = nil
            Task { await channel.unsubscribe() }
        }
        if let channel = realtimeChannel {
            realtimeChannel = nil
            Task { await channel.unsubscribe() }
        }
        if let channel = notifChannel {
            notifChannel = nil
            Task { await channel.unsubscribe() }
        }
        if let channel = followsChannel {
            followsChannel = nil
            Task { await channel.unsubscribe() }
        }
    }

    // MARK: - Comments realtime

    /// Subscribes to new comments on a session, invoking `onInsert` for each so
    /// the view can reload. Keeps Supabase realtime plumbing (channels, filters,
    /// subscribe lifecycle) out of the view layer. Pair with `stopCommentsRealtime()`.
    func startCommentsRealtime(sessionId: UUID, onInsert: @escaping () async -> Void) {
        stopCommentsRealtime()
        let channel = supabase.channel("comments:\(sessionId.uuidString)")
        commentsChannel = channel
        commentsTask = Task {
            let changes = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "comments",
                filter: "session_id=eq.\(sessionId.uuidString)"
            )
            await channel.subscribe()
            for await _ in changes {
                await onInsert()
            }
        }
    }

    func stopCommentsRealtime() {
        commentsTask?.cancel()
        commentsTask = nil
        if let channel = commentsChannel {
            commentsChannel = nil
            Task { await channel.unsubscribe() }
        }
    }
}
