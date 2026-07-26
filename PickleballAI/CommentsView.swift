import SwiftUI

struct CommentsView: View {
    let session: FeedSession

    var body: some View {
        // The screen lives inside the stack so its @mention taps resolve to this
        // stack's profile destination (see ProfileNavigationStack / openProfile).
        ProfileNavigationStack {
            CommentsScreen(session: session)
        }
    }
}

private struct ReplyTarget: Equatable {
    let rootCommentId: UUID
    let username: String
    let mentionAuthor: Bool
}

private struct CommentsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openProfile) private var openProfile
    @EnvironmentObject private var store: AppStore
    let session: FeedSession

    @State private var comments: [Comment] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var sending = false
    @State private var mentionSuggestions: [MentionCandidate] = []
    @State private var replyTarget: ReplyTarget?
    @State private var scrollTarget: UUID?
    /// Root comment ids whose replies are shown in full. Held here rather than in
    /// the row so posting a reply can open the thread it landed in.
    @State private var expandedThreads: Set<UUID> = []
    @FocusState private var composerFocused: Bool

    private var threads: [CommentThread] {
        store.commentThreads(from: comments)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isBusy
            && !sending
    }

    /// Everyone whose `@handle` should render as a tappable link: the session's
    /// players, everyone in the conversation, people you follow — and you, so a
    /// mention *of* you still links even though you can't tag yourself. Seeding
    /// yourself first dedupes you out of the loops below.
    private var mentionablePeople: [MentionCandidate] {
        var seen = Set<UUID>()
        var out: [MentionCandidate] = []
        if let me = store.currentProfile, seen.insert(me.id).inserted {
            out.append(MentionCandidate(me))
        }
        for activity in session.postActivities {
            for participant in activity.participants ?? [] {
                if let profile = participant.profile, seen.insert(profile.id).inserted {
                    out.append(MentionCandidate(profile))
                }
            }
        }
        for comment in comments {
            if let profile = comment.author, seen.insert(profile.id).inserted {
                out.append(MentionCandidate(profile))
            }
        }
        for entry in store.following {
            if let profile = entry.profile, seen.insert(profile.id).inserted {
                out.append(MentionCandidate(profile))
            }
        }
        return out
    }

    /// Autocomplete offers everyone but you — tagging yourself is never useful.
    private var mentionCandidates: [MentionCandidate] {
        let me = store.currentProfile?.id
        return mentionablePeople.filter { $0.id != me }
    }

    private var mentionResolver: [String: UUID] {
        Dictionary(
            mentionablePeople.map { ($0.username.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if loading {
                            SkeletonList(rows: 5)
                        } else if threads.isEmpty {
                            emptyState
                        } else {
                            ForEach(threads) { thread in
                                CommentThreadRow(
                                    thread: thread,
                                    sessionOwnerId: session.userId,
                                    resolver: mentionResolver,
                                    expanded: expansion(for: thread.id),
                                    onReply: beginReply,
                                    onDeleted: { Task { await load() } }
                                )
                                .id(thread.id)
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await load() }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: .bottom) }
                    scrollTarget = nil
                }
            }

            if !mentionSuggestions.isEmpty {
                mentionBar
            }
            composer
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Comments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "pmention", let id = UUID(uuidString: url.host() ?? "") else {
                return .systemAction
            }
            openProfile(id)
            return .handled
        })
        .task {
            await load()
            store.startCommentsRealtime(sessionId: session.id) { await load() }
        }
        .onDisappear { store.stopCommentsRealtime() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(Theme.textTertiary)
            Text("Start the conversation")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Share some encouragement or ask about the session.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
    }

    // MARK: Mention autocomplete

    private var mentionBar: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(mentionSuggestions) { candidate in
                    Button {
                        draft = CommentMentions.insert(candidate.username, into: draft)
                        mentionSuggestions = []
                        Haptics.tap()
                    } label: {
                        HStack(spacing: 10) {
                            ProfileAvatar(participant: candidate.profile, size: 30, unlinked: true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("@\(candidate.username)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 160)
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.hairline), alignment: .top)
    }

    private func updateMentionSuggestions() {
        guard let (_, prefix) = CommentMentions.activeQuery(in: draft) else {
            mentionSuggestions = []
            return
        }
        let matches = mentionCandidates.filter { candidate in
            prefix.isEmpty
                || candidate.username.lowercased().hasPrefix(prefix)
                || candidate.displayName.lowercased().contains(prefix)
        }
        mentionSuggestions = Array(matches.prefix(6))
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyTarget {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text("Replying to @\(replyTarget.username)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        cancelReply()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    replyTarget.map { "Reply to @\($0.username)…" } ?? "Add a comment…",
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        .strokeBorder(replyTarget == nil ? Theme.hairline : Theme.accent.opacity(0.45), lineWidth: 1)
                )
                .onChange(of: draft) { _, _ in updateMentionSuggestions() }

                Button {
                    Task { await send() }
                } label: {
                    Group {
                        if sending {
                            ProgressView().tint(Theme.background)
                        } else {
                            Image(systemName: replyTarget == nil ? "arrow.up" : "arrowshape.turn.up.left.fill")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .foregroundStyle(Theme.background)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Theme.accent : Theme.surfaceElevated, in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel(replyTarget == nil ? "Post comment" : "Post reply")
            }
            .padding(12)
        }
        .background(Theme.background)
        .overlay(Divider().overlay(Theme.hairline), alignment: .top)
    }

    private func beginReply(rootId: UUID, author: ParticipantProfile?, mentionAuthor: Bool) {
        guard let author else { return }
        replyTarget = ReplyTarget(
            rootCommentId: rootId,
            username: author.username,
            mentionAuthor: mentionAuthor
        )
        if mentionAuthor {
            let mention = "@\(author.username) "
            if !draft.lowercased().contains("@\(author.username.lowercased())") {
                draft = mention + draft
            }
        }
        mentionSuggestions = []
        composerFocused = true
        Haptics.tap()
    }

    private func cancelReply() {
        if let target = replyTarget, target.mentionAuthor {
            let mention = "@\(target.username) "
            if draft.hasPrefix(mention) { draft.removeFirst(mention.count) }
        }
        replyTarget = nil
        mentionSuggestions = []
        Haptics.tap()
    }

    private func expansion(for threadId: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedThreads.contains(threadId) },
            set: { isExpanded in
                if isExpanded {
                    expandedThreads.insert(threadId)
                } else {
                    expandedThreads.remove(threadId)
                }
            }
        )
    }

    private func load() async {
        comments = await store.fetchComments(sessionId: session.id)
        loading = false
    }

    /// The comment we just posted. Comments arrive oldest-first, so the last one
    /// at this level authored by me is the new one.
    private func newestOwnComment(parentId: UUID?) -> Comment? {
        let me = store.currentProfile?.id
        return comments.last { $0.parentId == parentId && $0.userId == me }
    }

    private func send() async {
        guard !sending else { return }
        let body = draft
        let target = replyTarget
        sending = true
        draft = ""
        replyTarget = nil
        mentionSuggestions = []
        if await store.addComment(
            sessionId: session.id,
            parentId: target?.rootCommentId,
            body: body
        ) {
            Haptics.success()
            // Open the thread before reloading: the await gives SwiftUI a render
            // pass, so the new reply is laid out by the time we scroll to it.
            if let rootId = target?.rootCommentId { expandedThreads.insert(rootId) }
            await load()
            scrollTarget = newestOwnComment(parentId: target?.rootCommentId)?.id
                ?? target?.rootCommentId
        } else {
            draft = body
            replyTarget = target
        }
        sending = false
    }
}

private struct CommentThreadRow: View {
    let thread: CommentThread
    let sessionOwnerId: UUID
    let resolver: [String: UUID]
    @Binding var expanded: Bool
    let onReply: (UUID, ParticipantProfile?, Bool) -> Void
    let onDeleted: () -> Void

    private var visibleReplies: [Comment] {
        expanded ? thread.replies : Array(thread.replies.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommentRow(
                comment: thread.comment,
                sessionOwnerId: sessionOwnerId,
                resolver: resolver,
                isReply: false,
                onReply: {
                    onReply(thread.comment.id, thread.comment.author, false)
                },
                onDeleted: onDeleted
            )

            if !thread.replies.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleReplies) { reply in
                        CommentRow(
                            comment: reply,
                            sessionOwnerId: sessionOwnerId,
                            resolver: resolver,
                            isReply: true,
                            onReply: {
                                onReply(thread.comment.id, reply.author, true)
                            },
                            onDeleted: onDeleted
                        )
                        .id(reply.id)
                    }

                    if thread.replies.count > 2 {
                        Button {
                            withAnimation(.snappy) { expanded.toggle() }
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(Theme.hairline)
                                    .frame(width: 24, height: 1)
                                Text(expanded ? "Hide replies" : "View \(thread.replies.count - 2) more replies")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(minHeight: 32)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 30)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: 2)
                        .padding(.leading, 15)
                }
            }
        }
    }
}

struct CommentRow: View {
    @EnvironmentObject private var store: AppStore
    let comment: Comment
    let sessionOwnerId: UUID
    var resolver: [String: UUID] = [:]
    var isReply = false
    var onReply: () -> Void
    var onDeleted: () -> Void

    @State private var confirmDelete = false
    @State private var reportTarget: ReportTarget?
    @State private var likeInFlight = false

    var body: some View {
        HStack(alignment: .top, spacing: isReply ? 10 : 12) {
            if comment.isDeleted {
                Image(systemName: "minus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: isReply ? 32 : 40, height: isReply ? 32 : 40)
                    .background(Theme.surfaceElevated, in: Circle())
            } else {
                ProfileLink(userId: comment.author?.id) {
                    ProfileAvatar(participant: comment.author, size: isReply ? 32 : 40, unlinked: true)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                header

                if comment.isDeleted {
                    Text("Comment deleted")
                        .font(.subheadline.italic())
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text(CommentMentions.attributed(comment.body, resolver: resolver, accent: Theme.accent))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)

                    actions
                }
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog("Delete this comment?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await store.deleteComment(comment) { onDeleted() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !comment.isDeleted {
                ProfileLink(userId: comment.author?.id) {
                    HStack(spacing: 6) {
                        Text(comment.authorName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        ProBadge(isPro: comment.author?.isPro ?? false)
                        if let username = comment.author?.username {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            Text(comment.date.relativeLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 4)
            if !comment.isDeleted && (canDelete || canReport) {
                Menu {
                    if canDelete {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete Comment", systemImage: "trash")
                        }
                    }
                    if canReport {
                        Button {
                            reportTarget = .comment(comment.id)
                        } label: {
                            Label("Report Comment", systemImage: "exclamationmark.bubble")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Comment actions")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 18) {
            Button {
                guard !likeInFlight else { return }
                Haptics.impact()
                Task {
                    likeInFlight = true
                    await store.toggleCommentLike(comment)
                    likeInFlight = false
                }
            } label: {
                let liked = store.likedCommentIds.contains(comment.id)
                HStack(spacing: 5) {
                    Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    if store.commentLikeCount(for: comment) > 0 {
                        Text("\(store.commentLikeCount(for: comment))")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(liked ? Theme.accent : Theme.textTertiary)
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .disabled(likeInFlight)
            .accessibilityLabel(store.likedCommentIds.contains(comment.id) ? "Unlike comment" : "Like comment")

            Button {
                onReply()
            } label: {
                Text("Reply")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply to @\(comment.author?.username ?? "player")")
        }
    }

    private var canDelete: Bool {
        guard let uid = store.currentProfile?.id else { return false }
        return comment.userId == uid || sessionOwnerId == uid
    }

    private var canReport: Bool {
        guard let uid = store.currentProfile?.id else { return false }
        return comment.userId != uid
    }
}
