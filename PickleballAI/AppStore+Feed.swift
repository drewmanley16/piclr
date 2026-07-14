import Foundation
import Supabase
import UIKit

extension AppStore {
    func loadFeed(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { feedReachedEnd = false } else if feedReachedEnd { return }
        do {
            let followingIds = try await acceptedFollowingIds(for: uid)
            let visibleIds = [uid] + followingIds
            let idFilter = Self.inFilter(for: visibleIds)
            let from = reset ? 0 : feed.count
            let page: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .eq("posted", value: true)
                .filter("user_id", operator: "in", value: idFilter)
                .order("created_at", ascending: false)
                .order("created_at", ascending: true, referencedTable: "preview_comments")
                .range(from: from, to: from + feedPageSize - 1)
                .limit(3, referencedTable: "preview_comments")
                .execute()
                .value
            feed = reset ? page : feed + page
            feedReachedEnd = page.count < feedPageSize
            await refreshLikedState(for: page, uid: uid)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadDiscover(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { discoverReachedEnd = false } else if discoverReachedEnd { return }
        do {
            let from = reset ? 0 : discoverFeed.count
            let page: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .eq("posted", value: true)
                .neq("user_id", value: uid.uuidString)
                .order("created_at", ascending: false)
                .order("created_at", ascending: true, referencedTable: "preview_comments")
                .range(from: from, to: from + feedPageSize - 1)
                .limit(3, referencedTable: "preview_comments")
                .execute()
                .value
            discoverFeed = reset ? page : discoverFeed + page
            discoverReachedEnd = page.count < feedPageSize
            await refreshLikedState(for: page, uid: uid)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadMySessions(userId: UUID) async {
        do {
            mySessions = try await supabase
                .from("sessions")
                .select(selectWithCounts)
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = friendly(error)
        }
    }

    func logSession(
        title: String,
        location: String,
        durationMinutes: Int,
        focus: String,
        takeaway: String,
        postToFeed: Bool
    ) async {
        guard let uid = currentProfile?.id else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let new = NewSession(
                userId: uid,
                title: title.isEmpty ? nil : title,
                location: location.isEmpty ? nil : location,
                durationMinutes: durationMinutes,
                focus: focus,
                takeaway: takeaway.isEmpty ? nil : takeaway,
                posted: postToFeed
            )
            try await supabase.from("sessions").insert(new).execute()
            await loadMySessions(userId: uid)
            await loadFeed()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func postSession(_ draft: SessionDraft) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let now = Date()
            let duration = max(1, Int(now.timeIntervalSince(draft.startedAt) / 60))
            let firstFocus = draft.activities.first(where: { $0.kind == .practice && !$0.focus.isEmpty })?.focus

            let session = NewSession(
                userId: uid,
                title: draft.title.isEmpty ? nil : draft.title,
                location: draft.location.isEmpty ? nil : draft.location,
                durationMinutes: duration,
                focus: firstFocus,
                takeaway: nil,
                posted: false,
                startedAt: Self.iso.string(from: draft.startedAt),
                endedAt: Self.iso.string(from: now)
            )
            try await supabase.from("sessions").insert(session).execute()

            for (index, activity) in draft.activities.enumerated() {
                let isMatch = activity.kind == .match
                let newActivity = NewSessionActivity(
                    sessionId: session.id,
                    kind: activity.kind.rawValue,
                    position: index,
                    focus: activity.focus.isEmpty ? nil : activity.focus,
                    reps: activity.reps.isEmpty ? nil : activity.reps,
                    notes: activity.notes.isEmpty ? nil : activity.notes,
                    teamScore: isMatch ? activity.teamScore : nil,
                    opponentScore: isMatch ? activity.opponentScore : nil,
                    won: isMatch ? activity.won : nil
                )
                try await supabase.from("session_activities").insert(newActivity).execute()

                let participants =
                    activity.partners.map { player in
                        NewActivityParticipant(activityId: newActivity.id, sessionId: session.id,
                                               profileId: player.profile?.id, guestName: player.profile == nil ? player.guestName : nil, role: "partner")
                    } +
                    activity.opponents.map { player in
                        NewActivityParticipant(activityId: newActivity.id, sessionId: session.id,
                                               profileId: player.profile?.id, guestName: player.profile == nil ? player.guestName : nil, role: "opponent")
                    }
                if !participants.isEmpty {
                    try await supabase.from("activity_participants").insert(participants).execute()
                }
            }

            if let photoData = draft.photoData,
               let photoURL = await uploadPostPhoto(photoData, sessionId: session.id, uid: uid) {
                try await supabase.from("sessions")
                    .update(["photo_url": photoURL])
                    .eq("id", value: session.id.uuidString)
                    .execute()
            }

            try await supabase.from("sessions")
                .update(["posted": draft.postToFeed])
                .eq("id", value: session.id.uuidString)
                .execute()

            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func toggleLike(_ session: FeedSession) async {
        guard let uid = currentProfile?.id else { return }
        let wasLiked = likedSessionIds.contains(session.id)
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
            }
        } catch {
            if wasLiked {
                likedSessionIds.insert(session.id)
            } else {
                likedSessionIds.remove(session.id)
            }
            errorMessage = friendly(error)
        }
        await loadFeed()
    }
}
