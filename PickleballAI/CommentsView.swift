import SwiftUI
import Supabase

struct CommentsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let session: FeedSession

    @State private var comments: [Comment] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var channel: RealtimeChannelV2?

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isBusy
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if loading {
                                ProgressView().tint(Theme.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            } else if comments.isEmpty {
                                Text("No comments yet — start the conversation.")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            } else {
                                ForEach(comments) { comment in
                                    CommentRow(comment: comment).id(comment.id)
                                }
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: comments) { _, _ in
                        if let last = comments.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }

                composer
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                await load()
                subscribe()
            }
            .onDisappear { unsubscribe() }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))

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
        if await store.addComment(sessionId: session.id, body: body) {
            await load()
        } else {
            draft = body // restore on failure
        }
    }

    private func subscribe() {
        let ch = supabase.channel("comments:\(session.id.uuidString)")
        channel = ch
        Task {
            let changes = ch.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "comments",
                filter: "session_id=eq.\(session.id.uuidString)"
            )
            await ch.subscribe()
            for await _ in changes {
                await load()
            }
        }
    }

    private func unsubscribe() {
        if let ch = channel {
            channel = nil
            Task { await ch.unsubscribe() }
        }
    }
}

struct CommentRow: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(initials: comment.authorInitials)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let username = comment.author?.username {
                        Text("@\(username)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(comment.date.relativeLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(comment.body)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
        }
    }
}
