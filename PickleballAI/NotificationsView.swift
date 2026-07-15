import SwiftUI

struct NotificationsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    private var isEmpty: Bool {
        store.incomingFollowRequests.isEmpty
            && store.incomingRepostRequests.isEmpty
            && store.notifications.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isEmpty {
                        emptyState
                    } else {
                        if !store.incomingFollowRequests.isEmpty {
                            section(title: "Follow Requests") {
                                ForEach(store.incomingFollowRequests) { FollowRequestRow(request: $0) }
                            }
                        }
                        if !store.incomingRepostRequests.isEmpty {
                            section(title: "Repost Requests") {
                                ForEach(store.incomingRepostRequests) { RepostRequestRow(request: $0) }
                            }
                        }
                        if !store.notifications.isEmpty {
                            section(title: "Activity") {
                                ForEach(store.notifications) { notification in
                                    if let dest = destination(for: notification) {
                                        NavigationLink(value: dest) {
                                            NotificationRow(notification: notification)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        NotificationRow(notification: notification)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: NotifDestination.self) { dest in
                switch dest {
                case .profile(let userId):
                    OtherProfileView(userId: userId, placeholder: nil)
                case .session(let sessionId):
                    SessionDetailView(sessionId: sessionId)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await reload() }
            .task { await store.markNotificationsRead() }
        }
    }

    /// Where a tapped activity notification navigates: follows open the actor's
    /// profile, everything else opens the related session.
    private func destination(for n: AppNotification) -> NotifDestination? {
        switch n.type {
        case "follow": return n.actor.map { .profile($0.id) }
        default:       return n.session.map { .session($0.id) }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            content()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.largeTitle)
                .foregroundStyle(Theme.textTertiary)
            Text("You're all caught up")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Follow and repost requests will show up here.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func reload() async {
        guard let uid = store.currentProfile?.id else { return }
        await store.loadFollowState(userId: uid)
        await store.loadRepostRequests(userId: uid)
        await store.loadNotifications(userId: uid)
    }
}

enum NotifDestination: Hashable {
    case profile(UUID)
    case session(UUID)
}

/// A single session opened from a notification. Fetches the post on demand
/// since it may not be in the currently-loaded feed.
struct SessionDetailView: View {
    @EnvironmentObject private var store: AppStore
    let sessionId: UUID

    @State private var session: FeedSession?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            if let session {
                FeedCard(session: session)
                    .padding(16)
            } else if isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.textTertiary)
                    Text("This post is no longer available")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            session = await store.loadSession(id: sessionId)
            isLoading = false
        }
    }
}

struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ProfileAvatar(participant: notification.actor, size: 40)
                Image(systemName: notification.icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 18, height: 18)
                    .background(Theme.accent, in: Circle())
                    .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(notification.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            if !notification.read {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
            }
        }
        .cardStyle()
    }
}
