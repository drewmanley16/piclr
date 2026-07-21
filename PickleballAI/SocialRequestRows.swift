import SwiftUI

struct PostingRow: View {
    @EnvironmentObject private var store: AppStore
    var session: FeedSession
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var reportTarget: ReportTarget?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.pickleball")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.postDisplayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(session.postDurationMinutes) min · \(session.postLocation ?? "—")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(session.date.relativeLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

            Menu {
                if isOwner {
                    if !session.isRepost {
                        Button {
                            showEditor = true
                        } label: {
                            Label("Edit Session", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                } else {
                    Button {
                        reportTarget = .session(session.id)
                    } label: {
                        Label("Report Session", systemImage: "exclamationmark.bubble")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Session actions")
        }
        .cardStyle()
        .fullScreenCover(isPresented: $showEditor) {
            ActiveSessionView(existingSession: session)
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                Task { _ = await store.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var isOwner: Bool { store.currentProfile?.id == session.userId }
}

struct FollowRequestRow: View {
    @EnvironmentObject private var store: AppStore
    var request: FollowRequest

    var body: some View {
        IdentityRow(
            avatarURL: request.follower?.avatarURL,
            initials: request.follower?.initials ?? "PB",
            avatarSize: 44,
            name: request.follower?.displayName ?? "Player",
            detail: request.follower.map { "@\($0.username)" } ?? "Wants to follow you",
            userId: request.follower?.id,
            placeholder: request.follower
        ) {
            AcceptDeclineButtons {
                Task { await store.respondToFollowRequest(request, accept: false) }
            } onAccept: {
                Task { await store.respondToFollowRequest(request, accept: true) }
            }
        }
        .cardStyle()
    }
}
