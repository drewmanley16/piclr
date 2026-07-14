import Foundation
import Supabase

extension AppStore {
    func reloadFollowGraph(userId: UUID, refreshFeed: Bool) async {
        await loadFollowState(userId: userId)
        await loadFollowLists(userId: userId)
        if refreshFeed { await loadFeed() }
    }

    func loadFollowState(userId: UUID) async {
        do {
            followerCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0
            followingCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("follower_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0

            // Outgoing edges (pending or accepted) → discovery "requested" state.
            let outgoing: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("follower_id", value: userId.uuidString)
                .execute()
                .value
            requestedFollowIds = Set(outgoing.map(\.followeeId))

            // Incoming pending requests → resolve requester profiles.
            let incoming: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
            let followers = try await profilesByID(for: incoming.map(\.followerId))
            incomingFollowRequests = incoming.map { row in
                FollowRequest(
                    followerId: row.followerId,
                    followeeId: row.followeeId,
                    follower: followers[row.followerId]
                )
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadFollowLists() async {
        guard let uid = currentProfile?.id else { return }
        await loadFollowLists(userId: uid)
    }

    func loadFollowLists(userId: UUID) async {
        do {
            let followerEdges: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .value
            let followingEdges: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("follower_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .value

            let followerIds = followerEdges.map(\.followerId)
            let followingIds = followingEdges.map(\.followeeId)
            let iFollow = Set(followingIds)
            let byId = try await profilesByID(for: followerIds + followingIds)

            followers = followerIds.map { id in
                FollowListEntry(userId: id, profile: byId[id], isFollowedByMe: iFollow.contains(id))
            }
            following = followingIds.map { id in
                FollowListEntry(userId: id, profile: byId[id], isFollowedByMe: true)
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func followList(for userId: UUID, kind: FollowListKind) async -> [FollowListEntry] {
        guard let me = currentProfile?.id else { return [] }
        do {
            let column = kind == .followers ? "followee_id" : "follower_id"
            let edges: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq(column, value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .value
            let otherIds = edges.map { kind == .followers ? $0.followerId : $0.followeeId }
            let byId = try await profilesByID(for: otherIds)
            let myFollowing = Set(try await acceptedFollowingIds(for: me))
            return otherIds.map { id in
                FollowListEntry(userId: id, profile: byId[id], isFollowedByMe: myFollowing.contains(id))
            }
        } catch {
            errorMessage = friendly(error)
            return []
        }
    }

    func matchContacts(phones: [String]) async {
        let uniquePhones = Array(Set(phones)).sorted()
        guard !uniquePhones.isEmpty else {
            contactMatches = []
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            var matches: [ContactMatch] = []
            for batch in uniquePhones.chunked(into: 500) {
                let response: MatchContactsResponse = try await supabase.functions
                    .invoke(
                        "match-contacts",
                        options: FunctionInvokeOptions(body: MatchContactsRequest(phones: batch))
                    )
                matches.append(contentsOf: response.matches)
            }
            let ownId = currentProfile?.id
            var seenProfileIds: Set<UUID> = []
            contactMatches = matches.filter { match in
                guard match.profile.id != ownId, !seenProfileIds.contains(match.profile.id) else {
                    return false
                }
                seenProfileIds.insert(match.profile.id)
                return true
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func searchProfiles(query: String) async {
        let usernameQuery = query.normalizedUsername
        let displayNameQuery = Self.displayNameSearchTerm(from: query)
        var filters: [String] = []
        if usernameQuery.count >= 2 {
            filters.append("username.ilike.*\(usernameQuery)*")
        }
        if displayNameQuery.count >= 2 {
            filters.append("display_name.ilike.*\(displayNameQuery)*")
        }
        guard !filters.isEmpty else {
            searchResults = []
            return
        }
        do {
            let results: [Profile] = try await supabase
                .from("profiles")
                .select()
                .or(filters.joined(separator: ","))
                .limit(10)
                .execute()
                .value
            let ownId = currentProfile?.id
            searchResults = results.filter { $0.id != ownId && $0.hasCompletedOnboarding }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func searchProfilesAfterTyping(query: String) async {
        guard query.trimmed.count >= 2 else {
            await searchProfiles(query: query)
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        await searchProfiles(query: query)
    }

    func sendFollowRequest(to profile: Profile) async {
        guard let uid = currentProfile?.id, uid != profile.id else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let new = NewFollow(followerId: uid, followeeId: profile.id, status: "pending")
            try await supabase.from("follows").insert(new).execute()
            requestedFollowIds.insert(profile.id)
            await loadFollowState(userId: uid)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func respondToFollowRequest(_ request: FollowRequest, accept: Bool) async {
        guard let uid = currentProfile?.id, request.followeeId == uid else { return }
        do {
            if accept {
                try await supabase
                    .from("follows")
                    .update(["status": "accepted"])
                    .eq("follower_id", value: request.followerId.uuidString)
                    .eq("followee_id", value: uid.uuidString)
                    .execute()
            } else {
                try await supabase
                    .from("follows")
                    .delete()
                    .eq("follower_id", value: request.followerId.uuidString)
                    .eq("followee_id", value: uid.uuidString)
                    .execute()
            }
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
            await loadFeed()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func unfollow(userId: UUID) async {
        guard let uid = currentProfile?.id, uid != userId else { return }
        do {
            try await supabase
                .from("follows")
                .delete()
                .eq("follower_id", value: uid.uuidString)
                .eq("followee_id", value: userId.uuidString)
                .execute()
            requestedFollowIds.remove(userId)
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
            await loadFeed()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadPublicProfile(userId: UUID) async -> PublicProfile? {
        guard let me = currentProfile?.id else { return nil }
        do {
            let rows: [Profile] = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            guard let profile = rows.first else { return nil }

            let relationship: FollowRelationship
            if userId == me {
                relationship = .isSelf
            } else {
                let edges: [FollowRow] = try await supabase
                    .from("follows")
                    .select("follower_id, followee_id, status, created_at")
                    .eq("follower_id", value: me.uuidString)
                    .eq("followee_id", value: userId.uuidString)
                    .limit(1)
                    .execute()
                    .value
                switch edges.first?.status {
                case "accepted": relationship = .following
                case "pending": relationship = .requested
                default: relationship = .none
                }
            }

            let followerCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0
            let followingCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("follower_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0

            var sessions: [FeedSession] = []
            if relationship.canViewContent {
                sessions = try await supabase
                    .from("sessions")
                    .select(selectWithCounts)
                    .eq("user_id", value: userId.uuidString)
                    .eq("posted", value: true)
                    .order("created_at", ascending: false)
                    .limit(50)
                    .execute()
                    .value
            }

            return PublicProfile(
                profile: profile,
                relationship: relationship,
                followerCount: followerCount,
                followingCount: followingCount,
                sessions: sessions
            )
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }
}
