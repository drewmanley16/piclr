import Foundation
import Supabase

// MARK: - Comments

extension AppStore {
    func fetchComments(sessionId: UUID) async -> [Comment] {
        do {
            let rows: [Comment] = try await supabase
                .from("comments")
                .select("*, author:profiles!comments_user_id_fkey(\(Self.selectProfileLite))")
                .eq("session_id", value: sessionId.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
            var hydrated: [Comment] = []
            for comment in rows {
                hydrated.append(await hydrateComment(comment))
            }
            return hydrated
        } catch {
            reportError(error)
            return []
        }
    }

    @discardableResult
    func addComment(sessionId: UUID, body: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await supabase.from("comments")
                .insert(NewComment(sessionId: sessionId, userId: uid, body: trimmed))
                .execute()
            await refreshSessionAcrossFeeds(id: sessionId)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    @discardableResult
    func deleteComment(_ comment: Comment) async -> Bool {
        do {
            try await supabase.from("comments")
                .delete()
                .eq("id", value: comment.id.uuidString)
                .execute()
            await refreshSessionAcrossFeeds(id: comment.sessionId)
            return true
        } catch {
            reportError(error)
            return false
        }
    }
}
