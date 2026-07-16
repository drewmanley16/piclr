import Foundation
import Supabase

// MARK: - Reposts

extension AppStore {
    /// Ask the session's author for permission to repost (copy) it. Only allowed
    /// if you're tagged in the session (enforced by RLS).
    func requestRepost(_ session: FeedSession) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.from("repost_requests")
                .insert(NewRepostRequest(sessionId: session.id, requesterId: uid))
                .execute()
            requestedRepostSessionIds.insert(session.id)
        } catch {
            reportError(error)
        }
    }

    /// Incoming repost requests for sessions the signed-in user authored.
    func loadRepostRequests(userId: UUID) async {
        do {
            let rows: [RepostRequest] = try await supabase
                .from("repost_requests")
                .select("*, requester:profiles!requester_id(\(Self.selectProfileLite)), session:sessions!session_id(id,user_id,title)")
                .eq("status", value: "pending")
                .execute()
                .value
            var hydrated: [RepostRequest] = []
            for var request in rows where request.session?.userId == userId {
                if let requester = request.requester {
                    request.requester = await media.hydrateParticipantProfile(requester)
                }
                hydrated.append(request)
            }
            incomingRepostRequests = hydrated

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
            reportError(error)
        }
    }

    func approveRepost(_ request: RepostRequest) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.rpc("approve_repost", params: ["request_id": request.id.uuidString]).execute()
            await loadRepostRequests(userId: uid)
            await loadFeed()
        } catch {
            reportError(error)
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
            reportError(error)
        }
    }
}
