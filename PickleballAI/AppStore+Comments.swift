import Foundation
import Supabase

extension AppStore {
    func fetchComments(sessionId: UUID) async -> [Comment] {
        do {
            return try await supabase
                .from("comments")
                .select("*, author:profiles!comments_user_id_fkey(id,username,display_name,avatar_initials,avatar_url)")
                .eq("session_id", value: sessionId.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
        } catch {
            errorMessage = friendly(error)
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
            await loadFeed()
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }
}
