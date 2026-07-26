import Foundation
import Supabase

// MARK: - Feed reads + likes

extension AppStore {
    /// Following feed: your posts + posts from people you follow (accepted).
    /// Paginated — pass reset: false to append the next page.
    func loadFeed(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { feedReachedEnd = false } else if feedReachedEnd { return }
        if isFeedRequestInFlight {
            if reset { pendingFeedRefresh = true }
            return
        }

        isFeedRequestInFlight = true
        let requestBeganAt = Date()
        defer {
            isFeedRequestInFlight = false
            if pendingFeedRefresh {
                pendingFeedRefresh = false
                Task { [weak self] in await self?.loadFeed() }
            }
        }

        do {
            let followingIds = try await acceptedFollowingIds(for: uid)
            let visibleIds = [uid] + followingIds
            let idFilter = Self.inFilter(for: visibleIds)
            let from = reset ? 0 : feed.count
            let page: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .is("comments.deleted_at", value: nil)
                .is("preview_comments.deleted_at", value: nil)
                .is("preview_comments.parent_id", value: nil)
                .eq("posted", value: true)
                .filter("user_id", operator: "in", value: idFilter)
                .order("created_at", ascending: false)
                .order("created_at", ascending: true, referencedTable: "preview_comments")
                .range(from: from, to: from + feedPageSize - 1)
                .limit(3, referencedTable: "preview_comments")
                .execute()
                .value
            guard currentProfile?.id == uid, !Task.isCancelled else { return }

            // Text and activity data can render immediately. Private-media URL
            // signing and liked-state lookup are enhancements, not prerequisites
            // for showing the feed.
            if reset {
                feed = page
            } else {
                let existingIDs = Set(feed.map(\.id))
                feed.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
            }
            feedReachedEnd = page.count < feedPageSize
            isInitialFeedLoading = false
            debugFeedMetric("feed query returned \(page.count) rows", since: requestBeganAt)
            if let initialFeedLoadStartedAt {
                debugFeedMetric("cold start to first feed rows", since: initialFeedLoadStartedAt)
                self.initialFeedLoadStartedAt = nil
            }

            async let hydrated: [FeedSession] = media.hydrateSessions(page)
            async let liked: Set<UUID>? = try? likedSessionIds(for: uid, sessionIds: page.map(\.id))
            let (hydratedPage, likedPage) = await (hydrated, liked)
            guard currentProfile?.id == uid, !Task.isCancelled else { return }

            let hydratedByID = Dictionary(uniqueKeysWithValues: hydratedPage.map { ($0.id, $0) })
            feed = feed.map { hydratedByID[$0.id] ?? $0 }
            if let likedPage {
                likedSessionIds.subtract(page.map(\.id))
                likedSessionIds.formUnion(likedPage)
            }
            debugFeedMetric("feed media hydrated", since: requestBeganAt)
        } catch {
            isInitialFeedLoading = false
            initialFeedLoadStartedAt = nil
            reportError(error)
        }
    }

    /// Discover feed: recent public posts from people you do not already follow.
    func loadDiscover(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { discoverReachedEnd = false } else if discoverReachedEnd { return }
        if isDiscoverRequestInFlight {
            if reset { pendingDiscoverRefresh = true }
            return
        }

        isDiscoverRequestInFlight = true
        defer {
            isDiscoverRequestInFlight = false
            if pendingDiscoverRefresh {
                pendingDiscoverRefresh = false
                Task { [weak self] in await self?.loadDiscover() }
            }
        }

        do {
            let followingIds = try await acceptedFollowingIds(for: uid)
            let excludedAuthorFilter = Self.inFilter(for: [uid] + followingIds)
            let from = reset ? 0 : discoverFeed.count
            let page: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .is("comments.deleted_at", value: nil)
                .is("preview_comments.deleted_at", value: nil)
                .is("preview_comments.parent_id", value: nil)
                .eq("posted", value: true)
                .filter("user_id", operator: "not.in", value: excludedAuthorFilter)
                .order("created_at", ascending: false)
                .order("created_at", ascending: true, referencedTable: "preview_comments")
                .range(from: from, to: from + feedPageSize - 1)
                .limit(3, referencedTable: "preview_comments")
                .execute()
                .value
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            if reset {
                discoverFeed = page
            } else {
                let existingIDs = Set(discoverFeed.map(\.id))
                discoverFeed.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
            }
            discoverReachedEnd = page.count < feedPageSize
            async let hydrated: [FeedSession] = media.hydrateSessions(page)
            async let liked: Set<UUID>? = try? likedSessionIds(for: uid, sessionIds: page.map(\.id))
            let (hydratedPage, likedPage) = await (hydrated, liked)
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            let hydratedByID = Dictionary(uniqueKeysWithValues: hydratedPage.map { ($0.id, $0) })
            discoverFeed = discoverFeed.map { hydratedByID[$0.id] ?? $0 }
            if let likedPage {
                likedSessionIds.subtract(page.map(\.id))
                likedSessionIds.formUnion(likedPage)
            }
        } catch {
            reportError(error)
        }
    }

    private func refreshLikedState(for sessions: [FeedSession], uid: UUID) async {
        guard !sessions.isEmpty else { return }
        if let liked = try? await likedSessionIds(for: uid, sessionIds: sessions.map(\.id)) {
            likedSessionIds.formUnion(liked)
        }
    }

    func loadMySessions(userId: UUID) async {
        defer { isInitialMySessionsLoading = false }
        do {
            let sessions: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectWithCounts)
                .is("comments.deleted_at", value: nil)
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            mySessions = await media.hydrateSessions(sessions)
            mySessions.sort { $0.workoutDate > $1.workoutDate }
        } catch {
            reportError(error)
        }
    }

    /// Fetches a single session by id (for opening a post from a notification).
    func loadSession(id: UUID) async -> FeedSession? {
        do {
            let rows: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .is("comments.deleted_at", value: nil)
                .is("preview_comments.deleted_at", value: nil)
                .is("preview_comments.parent_id", value: nil)
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value
            let hydrated = await media.hydrateSessions(rows)
            if let uid = currentProfile?.id { await refreshLikedState(for: hydrated, uid: uid) }
            return hydrated.first
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Refetch one session and swap the fresh copy into every feed array that
    /// holds it. Used after a comment add/delete so the count stays in sync
    /// across Home, Discover, and the profile grid without a full feed reload
    /// (which would collapse pagination back to the first page).
    func refreshSessionAcrossFeeds(id: UUID) async {
        guard let updated = await loadSession(id: id) else { return }
        feed = feed.map { $0.id == id ? updated : $0 }
        discoverFeed = discoverFeed.map { $0.id == id ? updated : $0 }
        mySessions = mySessions.map { $0.id == id ? updated : $0 }
    }

    func refresh() async {
        guard let uid = currentProfile?.id else { return }
        await loadFollowState(userId: uid)
        await loadFollowLists(userId: uid)
        await loadFeed()
        await loadMySessions(userId: uid)
        await loadGear(userId: uid)
    }

    // MARK: - Likes

    func toggleLike(_ session: FeedSession) async {
        guard let uid = currentProfile?.id else { return }
        let wasLiked = likedSessionIds.contains(session.id)
        optimisticLikeCounts[session.id] = max(0, likeCount(for: session) + (wasLiked ? -1 : 1))
        if wasLiked {
            likedSessionIds.remove(session.id)
        } else {
            likedSessionIds.insert(session.id)
        }

        do {
            if wasLiked {
                try await supabase
                    .from("likes")
                    .delete()
                    .eq("user_id", value: uid.uuidString)
                    .eq("session_id", value: session.id.uuidString)
                    .execute()
            } else {
                try await supabase
                    .from("likes")
                    .insert(NewLike(userId: uid, sessionId: session.id))
                    .execute()
                Analytics.capture(.sessionLiked)
            }
        } catch {
            if wasLiked {
                likedSessionIds.insert(session.id)
            } else {
                likedSessionIds.remove(session.id)
            }
            optimisticLikeCounts[session.id] = nil
            reportError(error)
            return
        }
        // Keep the optimistic count as the source of truth rather than reloading
        // only `feed`: `likeCount(for:)` reads this overlay for every array, so
        // copies of the session in `discoverFeed`/`mySessions` stay in sync too
        // (clearing it here would revert those to their stale decoded counts).
    }

    func likeCount(for session: FeedSession) -> Int {
        optimisticLikeCounts[session.id] ?? session.likeCount
    }

    private func likedSessionIds(for userId: UUID, sessionIds: [UUID]) async throws -> Set<UUID> {
        let unique = Array(Set(sessionIds)).map(\.uuidString)
        guard !unique.isEmpty else { return [] }
        let rows: [LikeRow] = try await supabase
            .from("likes")
            .select("session_id")
            .eq("user_id", value: userId.uuidString)
            .in("session_id", values: unique)
            .execute()
            .value
        return Set(rows.map(\.sessionId))
    }
}
