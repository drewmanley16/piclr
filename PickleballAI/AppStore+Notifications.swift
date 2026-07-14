import Foundation
import Supabase

extension AppStore {
    func loadNotifications(userId: UUID) async {
        do {
            notifications = try await supabase
                .from("notifications")
                .select("id,type,read,created_at, actor:profiles!notifications_actor_id_fkey(id,username,display_name,avatar_initials,avatar_url), session:sessions!notifications_session_id_fkey(id,title), comment:comments!notifications_comment_id_fkey(id,body)")
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
        }
    }

    func requestRepost(_ session: FeedSession) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.from("repost_requests")
                .insert(NewRepostRequest(sessionId: session.id, requesterId: uid))
                .execute()
            requestedRepostSessionIds.insert(session.id)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadRepostRequests(userId: UUID) async {
        do {
            let rows: [RepostRequest] = try await supabase
                .from("repost_requests")
                .select("*, requester:profiles!requester_id(id,username,display_name,avatar_initials,avatar_url), session:sessions!session_id(id,user_id,title)")
                .eq("status", value: "pending")
                .execute()
                .value
            incomingRepostRequests = rows.filter { $0.session?.userId == userId }

            // Track your own outstanding requests so the button reads "Requested".
            let mine: [RepostRequest] = try await supabase
                .from("repost_requests")
                .select("id,session_id,requester_id,status")
                .eq("requester_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .execute()
                .value
            requestedRepostSessionIds = Set(mine.map(\.sessionId))
        } catch {
            errorMessage = friendly(error)
        }
    }

    func approveRepost(_ request: RepostRequest) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.rpc("approve_repost", params: ["request_id": request.id.uuidString]).execute()
            await loadRepostRequests(userId: uid)
            await loadFeed()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func declineRepost(_ request: RepostRequest) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.from("repost_requests")
                .update(["status": "declined"])
                .eq("id", value: request.id.uuidString)
                .execute()
            await loadRepostRequests(userId: uid)
        } catch {
            errorMessage = friendly(error)
        }
    }
}
