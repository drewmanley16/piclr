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
                Text(session.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(session.durationMinutes) min · \(session.location ?? "—")")
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
                    Button {
                        showEditor = true
                    } label: {
                        Label("Edit Session", systemImage: "pencil")
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
        HStack(spacing: 12) {
            ProfileLink(userId: request.follower?.id, placeholder: request.follower) {
                HStack(spacing: 12) {
                    ProfileAvatar(profile: request.follower, size: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.follower?.displayName ?? "Player")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(request.follower.map { "@\($0.username)" } ?? "Wants to follow you")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            Spacer()

            Button {
                Haptics.tap()
                Task { await store.respondToFollowRequest(request, accept: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.success()
                Task { await store.respondToFollowRequest(request, accept: true) }
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }
}

struct RepostRequestRow: View {
    @EnvironmentObject private var store: AppStore
    var request: RepostRequest

    var body: some View {
        HStack(spacing: 12) {
            ProfileLink(userId: request.requester?.id) {
                HStack(spacing: 12) {
                    ProfileAvatar(participant: request.requester, size: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.requester?.displayName ?? "Player")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("wants to repost \(sessionLabel)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button {
                Haptics.tap()
                Task { await store.declineRepost(request) }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.success()
                Task { await store.approveRepost(request) }
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    private var sessionLabel: String {
        if let title = request.session?.title, !title.isEmpty { return "\"\(title)\"" }
        return "your session"
    }
}
