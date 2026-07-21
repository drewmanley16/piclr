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

private struct CommentsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openProfile) private var openProfile
    @EnvironmentObject private var store: AppStore
    let session: FeedSession

    @State private var comments: [Comment] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var mentionSuggestions: [MentionCandidate] = []

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isBusy
    }

    /// People taggable from this thread: the session's players + who you follow.
    private var mentionCandidates: [MentionCandidate] {
        var seen = Set<UUID>()
        var out: [MentionCandidate] = []
        for activity in session.postActivities {
            for participant in activity.participants ?? [] {
                if let profile = participant.profile, seen.insert(profile.id).inserted {
                    out.append(MentionCandidate(profile))
                }
            }
        }
        for entry in store.following {
            if let profile = entry.profile, seen.insert(profile.id).inserted {
                out.append(MentionCandidate(profile))
            }
        }
        let me = store.currentProfile?.id
        return out.filter { $0.id != me }
    }

    /// username → id for rendering: candidates plus everyone who has commented,
    /// so mentions of thread participants always resolve to a tappable link.
    private var mentionResolver: [String: UUID] {
        var map: [String: UUID] = [:]
        for candidate in mentionCandidates { map[candidate.username.lowercased()] = candidate.id }
        for comment in comments {
            if let author = comment.author { map[author.username.lowercased()] = author.id }
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if loading {
                            SkeletonList(rows: 5)
                        } else if comments.isEmpty {
                            Text("No comments yet — start the conversation.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            ForEach(comments) { comment in
                                CommentRow(
                                    comment: comment,
                                    sessionOwnerId: session.userId,
                                    resolver: mentionResolver,
                                    onDeleted: { Task { await load() } }
                                )
                                .id(comment.id)
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await load() }
                .onChange(of: comments) { _, _ in
                    if let last = comments.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
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
        // Taps on a rendered @mention (pmention://<uuid>) open that profile.
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
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .onChange(of: draft) { _, _ in updateMentionSuggestions() }

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Theme.accent : Theme.surfaceElevated, in: Circle())
            }
            .disabled(!canSend)
        }
        .padding(12)
        .background(Theme.background)
    }

    private func load() async {
        comments = await store.fetchComments(sessionId: session.id)
        loading = false
    }

    private func send() async {
        let body = draft
        draft = ""
        mentionSuggestions = []
        if await store.addComment(sessionId: session.id, body: body) {
            Haptics.success()
            await load()
        } else {
            draft = body // restore on failure
        }
    }
}

struct CommentRow: View {
    @EnvironmentObject private var store: AppStore
    let comment: Comment
    let sessionOwnerId: UUID
    var resolver: [String: UUID] = [:]
    var onDeleted: () -> Void

    @State private var confirmDelete = false
    @State private var reportTarget: ReportTarget?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileLink(userId: comment.author?.id) {
                ProfileAvatar(participant: comment.author, size: 40, unlinked: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ProfileLink(userId: comment.author?.id) {
                        HStack(spacing: 6) {
                            Text(comment.authorName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            if let username = comment.author?.username {
                                Text("@\(username)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    Text(comment.date.relativeLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 4)
                    if canDelete || canReport {
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
                Text(CommentMentions.attributed(comment.body, resolver: resolver, accent: Theme.accent))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
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

    private var canDelete: Bool {
        guard let uid = store.currentProfile?.id else { return false }
        return comment.userId == uid || sessionOwnerId == uid
    }

    private var canReport: Bool {
        guard let uid = store.currentProfile?.id else { return false }
        return comment.userId != uid
    }
}
