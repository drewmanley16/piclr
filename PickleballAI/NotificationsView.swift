import SwiftUI

struct NotificationsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var loaded = false

    private var isEmpty: Bool {
        store.incomingFollowRequests.isEmpty
            && store.notifications.isEmpty
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !loaded && isEmpty {
                        SkeletonList(rows: 6)
                    } else if isEmpty {
                        emptyState
                    } else {
                        if !store.incomingFollowRequests.isEmpty {
                            section(title: "Follow Requests") {
                                ForEach(store.incomingFollowRequests) { FollowRequestRow(request: $0) }
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
                case .comments(let sessionId):
                    SessionDetailView(sessionId: sessionId, openComments: true)
                case .invite(let inviteId):
                    InviteDetailView(inviteId: inviteId)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await reload() }
            .task { await store.markNotificationsRead(); loaded = true }
        }
    }

    /// Where a tapped activity notification navigates: follows open the actor's
    /// profile, everything else opens the related session.
    private func destination(for n: AppNotification) -> NotifDestination? {
        switch n.type {
        case "follow":  return n.actor.map { .profile($0.id) }
        case "comment", "comment_reply", "comment_like", "mention":
            return n.session.map { .comments($0.id) }
        case "invite_received", "invite_response", "invite_cancelled": return n.invite.map { .invite($0.id) }
        default:        return n.session.map { .session($0.id) }
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
            Text("Follow requests and activity will show up here.")
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
        await store.loadNotifications(userId: uid)
    }
}

enum NotifDestination: Hashable {
    case profile(UUID)
    case session(UUID)
    case comments(UUID)
    case invite(UUID)
}

/// A target the app navigates to when the user taps a push notification.
enum DeepLink: Identifiable, Hashable {
    case session(UUID)
    case comments(UUID)
    case profile(UUID)
    case invite(UUID)

    var id: String {
        switch self {
        case .session(let id):  return "session-\(id)"
        case .comments(let id): return "comments-\(id)"
        case .profile(let id):  return "profile-\(id)"
        case .invite(let id):   return "invite-\(id)"
        }
    }
}

/// A single session opened from a notification. Fetches the post on demand
/// since it may not be in the currently-loaded feed. When `openComments` is
/// set, the comment thread is presented as soon as the post loads.
struct SessionDetailView: View {
    @EnvironmentObject private var store: AppStore
    let sessionId: UUID
    var openComments: Bool = false
    /// Optional pre-known session so the card can render instantly while the
    /// full snapshot (fresh like/comment counts) loads.
    var placeholder: FeedSession? = nil

    @State private var session: FeedSession?
    @State private var isLoading = true
    @State private var showComments = false

    init(sessionId: UUID, openComments: Bool = false, placeholder: FeedSession? = nil) {
        self.sessionId = sessionId
        self.openComments = openComments
        self.placeholder = placeholder
        _session = State(initialValue: placeholder)
    }

    var body: some View {
        ScrollView {
            if let session {
                FeedCard(session: session, openable: false)
                    .padding(16)
                guestInvites(for: session)
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
            if openComments && session != nil { showComments = true }
        }
        .sheet(isPresented: $showComments) {
            if let session {
                CommentsView(session: session)
            }
        }
    }

    /// Guest players in this session are real people who just played a real
    /// match but aren't on the app yet — the strongest moment to invite them.
    /// Deduplicated by name across the session's activities.
    private func guestInvites(for session: FeedSession) -> some View {
        let guests = session.sortedActivities
            .flatMap { $0.partners + $0.opponents }
            .filter(\.isGuest)
            .reduce(into: [String]()) { names, participant in
                let name = participant.displayName
                if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    names.append(name)
                }
            }

        return Group {
            if !guests.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PLAYED WITH")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(Array(guests.enumerated()), id: \.element) { index, name in
                            if index > 0 {
                                Divider().overlay(Theme.hairline).padding(.leading, 52)
                            }
                            HStack(spacing: 12) {
                                ProfileAvatar(guest: ActivityParticipant.initials(from: name), size: 40)
                                Text(name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                GuestInviteButton(guestName: name)
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .cardStyle(padding: 14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ProfileAvatar(participant: notification.actor, size: 40, unlinked: true)
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
