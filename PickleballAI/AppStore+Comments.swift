import Foundation
import Supabase

// MARK: - Comments

extension AppStore {
    func fetchComments(sessionId: UUID) async -> [Comment] {
        do {
            let rows: [Comment] = try await supabase
                .from("comments")
                .select("*, likes:comment_likes(count), author:profiles!comments_user_id_fkey(\(Self.selectProfileLite))")
                .eq("session_id", value: sessionId.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
            var hydrated: [Comment] = []
            for comment in rows {
                hydrated.append(await media.hydrateComment(comment))
            }
            if let uid = currentProfile?.id {
                // A like still being written owns its row's state until it lands.
                let ids = rows.map(\.id).filter { !commentLikeWritesInFlight.contains($0) }
                if let liked = try? await likedCommentIds(for: uid, commentIds: ids) {
                    likedCommentIds.subtract(ids)
                    likedCommentIds.formUnion(liked)
                    for id in ids { optimisticCommentLikeCounts[id] = nil }
                }
            }
            return hydrated
        } catch {
            reportError(error)
            return []
        }
    }

    @discardableResult
    func addComment(sessionId: UUID, parentId: UUID? = nil, body: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await supabase.from("comments")
                .insert(NewComment(sessionId: sessionId, userId: uid, parentId: parentId, body: trimmed))
                .execute()
            Analytics.capture(parentId == nil ? .commentPosted : .replyPosted)
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
            likedCommentIds.remove(comment.id)
            optimisticCommentLikeCounts[comment.id] = nil
            await refreshSessionAcrossFeeds(id: comment.sessionId)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func commentThreads(from comments: [Comment]) -> [CommentThread] {
        let replies = Dictionary(grouping: comments.filter { $0.parentId != nil && !$0.isDeleted }) {
            $0.parentId!
        }
        return comments
            .filter { $0.parentId == nil }
            .compactMap { comment in
                let children = replies[comment.id, default: []].sorted { $0.date < $1.date }
                guard !comment.isDeleted || !children.isEmpty else { return nil }
                return CommentThread(comment: comment, replies: children)
            }
    }

    func toggleCommentLike(_ comment: Comment) async {
        guard let uid = currentProfile?.id, !comment.isDeleted else { return }
        commentLikeWritesInFlight.insert(comment.id)
        defer { commentLikeWritesInFlight.remove(comment.id) }
        let wasLiked = likedCommentIds.contains(comment.id)
        optimisticCommentLikeCounts[comment.id] = max(
            0,
            commentLikeCount(for: comment) + (wasLiked ? -1 : 1)
        )
        if wasLiked {
            likedCommentIds.remove(comment.id)
        } else {
            likedCommentIds.insert(comment.id)
        }

        do {
            if wasLiked {
                try await supabase
                    .from("comment_likes")
                    .delete()
                    .eq("user_id", value: uid.uuidString)
                    .eq("comment_id", value: comment.id.uuidString)
                    .execute()
            } else {
                try await supabase
                    .from("comment_likes")
                    .insert(NewCommentLike(commentId: comment.id, userId: uid))
                    .execute()
                Analytics.capture(.commentLiked)
            }
        } catch {
            if wasLiked {
                likedCommentIds.insert(comment.id)
            } else {
                likedCommentIds.remove(comment.id)
            }
            optimisticCommentLikeCounts[comment.id] = nil
            reportError(error)
        }
    }

    func commentLikeCount(for comment: Comment) -> Int {
        optimisticCommentLikeCounts[comment.id] ?? comment.likeCount
    }

    private func likedCommentIds(for userId: UUID, commentIds: [UUID]) async throws -> Set<UUID> {
        let unique = Array(Set(commentIds)).map(\.uuidString)
        guard !unique.isEmpty else { return [] }
        let rows: [CommentLikeRow] = try await supabase
            .from("comment_likes")
            .select("comment_id")
            .eq("user_id", value: userId.uuidString)
            .in("comment_id", values: unique)
            .execute()
            .value
        return Set(rows.map(\.commentId))
    }
}
