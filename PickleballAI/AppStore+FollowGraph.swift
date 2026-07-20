import Foundation
import Supabase

// MARK: - Follow graph

extension AppStore {
    /// Loads follow counts, incoming pending requests, and the set of people
    /// this user has already requested/follows (for discovery button state).
    func loadFollowState(userId: UUID) async {
        do {
            let followerTotal = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0
            let followingTotal = try await supabase
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

            // Incoming pending requests → resolve requester profiles.
            let incoming: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
            let requesters = try await profilesByID(for: incoming.map(\.followerId))
            guard currentProfile?.id == userId, !Task.isCancelled else { return }
            followerCount = followerTotal
            followingCount = followingTotal
            requestedFollowIds = Set(outgoing.map(\.followeeId))
            incomingFollowRequests = incoming.map { row in
                FollowRequest(
                    followerId: row.followerId,
                    followeeId: row.followeeId,
                    follower: requesters[row.followerId]
                )
            }
        } catch {
            reportError(error)
        }
    }

    /// Loads the accepted followers/following lists, each annotated with
    /// whether the signed-in user follows that person back.
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
            reportError(error)
        }
    }

    /// Loads another user's followers or following list. Each entry's
    /// `isFollowedByMe` reflects whether the *signed-in* user follows that
    /// person (accepted) — so the follow-back button is relative to me,
    /// Instagram-style. Returns the entries rather than mutating the store's
    /// own published lists.
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
            reportError(error)
            return []
        }
    }

    /// Sends a follow request: inserts a `pending` edge (me → profile).
    func sendFollowRequest(to profile: Profile) async {
        guard let uid = currentProfile?.id, uid != profile.id else { return }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let new = NewFollow(followerId: uid, followeeId: profile.id, status: "pending")
            try await supabase.from("follows").insert(new).execute()
            Analytics.capture(.followSent)
            requestedFollowIds.insert(profile.id)
            await loadFollowState(userId: uid)
        } catch {
            reportError(error)
        }
    }

    /// Respond to an incoming follow request. Accepting flips the edge to
    /// accepted; declining deletes it so it can be re-requested later.
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
                Analytics.capture(.followAccepted)
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
            reportError(error)
        }
    }

    /// Unfollow someone: deletes the signed-in user's outgoing edge (me → them),
    /// whether it was accepted or still pending. Their sessions drop out of the
    /// feed and their profile becomes private again.
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
            reportError(error)
        }
    }

    func cancelFollowRequest(userId: UUID) async {
        await unfollow(userId: userId)
    }

    func removeFollower(userId: UUID) async {
        guard let uid = currentProfile?.id, uid != userId else { return }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase
                .from("follows")
                .delete()
                .eq("follower_id", value: userId.uuidString)
                .eq("followee_id", value: uid.uuidString)
                .execute()
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
        } catch {
            reportError(error)
        }
    }

    // MARK: - Helpers

    /// People `userId` follows with an accepted edge (for feed visibility).
    func acceptedFollowingIds(for userId: UUID) async throws -> [UUID] {
        let edges: [FollowRow] = try await supabase
            .from("follows")
            .select("follower_id, followee_id, status, created_at")
            .eq("follower_id", value: userId.uuidString)
            .eq("status", value: "accepted")
            .execute()
            .value
        let ids = Set(edges.map(\.followeeId))
        if currentProfile?.id == userId {
            acceptedFollowingUserIDs = ids
        }
        return Array(ids)
    }

    /// Fetches profiles for the given ids in one query, keyed by id. Ids that
    /// aren't visible (RLS) are simply absent from the result.
    private func profilesByID(for ids: [UUID]) async throws -> [UUID: Profile] {
        let unique = Array(Set(ids)).map(\.uuidString)
        guard !unique.isEmpty else { return [:] }
        let profiles: [Profile] = try await supabase
            .from("profiles")
            .select()
            .in("id", values: unique)
            .execute()
            .value
        var hydrated: [UUID: Profile] = [:]
        for profile in await media.hydrateProfiles(profiles) {
            hydrated[profile.id] = profile
        }
        return hydrated
    }
}
