import Foundation
import Supabase

extension AppStore {
    func startRealtime(userId: UUID) {
        stopRealtime()
        let channel = supabase.channel("public:sessions")
        realtimeChannel = channel
        realtimeTask = Task { [weak self] in
            let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "sessions")
            await channel.subscribe()
            for await _ in changes {
                await self?.refreshFeeds(userId: userId)
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
    }

    func refreshFeeds(userId: UUID) async {
        await loadFeed()
        await loadMySessions(userId: userId)
        if !discoverFeed.isEmpty { await loadDiscover() }
    }

    func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        notifTask?.cancel()
        notifTask = nil
        followsInTask?.cancel()
        followsInTask = nil
        followsOutTask?.cancel()
        followsOutTask = nil
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
}
