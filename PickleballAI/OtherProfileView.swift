import SwiftUI

/// Data-only description of a profile navigation target. Lives at the app layer
/// (not the design system) so `ProfileAvatar`/`ProfileLink` stay decoupled from
/// feature screens. Identity is the user id; the optional `placeholder` rides
/// along for an instant header but doesn't affect equality/hashing.
struct ProfileRoute: Hashable {
    let id: UUID
    var placeholder: Profile?

    static func == (lhs: ProfileRoute, rhs: ProfileRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Data-only description of a session-detail navigation target, mirroring
/// `ProfileRoute`. Identity is the session id; the optional `placeholder` rides
/// along for an instant header/activity render but doesn't affect equality.
struct SessionRoute: Hashable {
    let id: UUID
    var placeholder: FeedSession?

    static func == (lhs: SessionRoute, rhs: SessionRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A `NavigationStack` pre-wired to open user profiles and session detail
/// screens: it registers both destinations exactly once and binds the
/// `openProfile`/`openSession` environment actions to its own path. Use this in
/// place of a bare `NavigationStack` on any screen where avatars/names or
/// sessions should be tappable. The mapping route → screen lives here and
/// nowhere else, so changing a destination is a one-line edit.
struct ProfileNavigationStack<Root: View>: View {
    /// Re-tapping the active tab increments this; when it changes we pop the
    /// stack to root, restoring the native tab-bar "tap active tab to go back"
    /// behavior that the custom `AppTabBar` otherwise loses. Defaults to a
    /// constant for the many call sites (sheets, etc.) that don't need it.
    var reselectSignal: Int = 0
    @ViewBuilder var root: Root
    /// Type-erased so this stack can also carry other value-based routes pushed
    /// inside it (e.g. a notification's `NotifDestination`), not just profiles.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: ProfileRoute.self) { route in
                    OtherProfileView(userId: route.id, placeholder: route.placeholder)
                }
                .navigationDestination(for: SessionRoute.self) { route in
                    SessionDetailView(sessionId: route.id, placeholder: route.placeholder)
                }
        }
        .onChange(of: reselectSignal) { _, _ in
            if !path.isEmpty { path = NavigationPath() }
        }
        .environment(\.openProfile, OpenProfileAction { id, placeholder in
            path.append(ProfileRoute(id: id, placeholder: placeholder))
        })
        .environment(\.openSession, OpenSessionAction { id, placeholder in
            path.append(SessionRoute(id: id, placeholder: placeholder))
        })
    }
}

/// Another user's profile, reached by tapping a name in a follower/following
/// list. Header and counts are always visible. Sessions and follower/
/// following lists are visible to everyone unless the account is private, in
/// which case they're gated behind an accepted follow (`PublicProfile.contentVisible`).
struct OtherProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    let userId: UUID
    /// Optional pre-known profile so the header can render instantly while the
    /// full snapshot loads.
    var placeholder: Profile?

    @State private var loaded: PublicProfile?
    @State private var isLoading = true
    @State private var confirmUnfollow = false
    @State private var confirmCancelRequest = false
    @State private var confirmBlock = false
    @State private var reportTarget: ReportTarget?
    @State private var showGear = false

    private var profile: Profile? { loaded?.profile ?? placeholder }
    private var relationship: FollowRelationship { loaded?.relationship ?? .none }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let loaded {
                    if loaded.contentVisible {
                        GearShowcaseRow(items: loaded.gear) { showGear = true }
                        sessionsSection(loaded.sessions)
                    } else {
                        privateCard
                    }
                } else if isLoading {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sessions").font(.headline).foregroundStyle(Theme.textPrimary)
                        FeedCardSkeleton()
                        FeedCardSkeleton()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(profile.map { "@\($0.username)" } ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if relationship != .isSelf {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            reportTarget = .user(userId)
                        } label: {
                            Label("Report Player", systemImage: "exclamationmark.bubble")
                        }
                        Button(role: .destructive) {
                            confirmBlock = true
                        } label: {
                            Label("Block Player", systemImage: "person.crop.circle.badge.xmark")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Player actions")
                }
            }
        }
        .task { await load() }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target)
        }
        .sheet(isPresented: $showGear) {
            GearSheet(mode: .viewer(
                name: profile?.displayName ?? "Player",
                items: loaded?.gear ?? []
            ))
        }
        .confirmationDialog("Block this player?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task {
                    if await store.blockUser(userId: userId) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer be able to find, view, or interact with each other.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                ProfileAvatar(profile: profile, size: 76, unlinked: true)

                if let loaded, loaded.contentVisible {
                    ProfileStat(label: "Sessions", value: "\(loaded.sessions.count)")
                    NavigationLink {
                        UserFollowListView(userId: userId, kind: .followers)
                    } label: {
                        ProfileStat(label: "Followers", value: "\(loaded.followerCount)")
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        UserFollowListView(userId: userId, kind: .following)
                    } label: {
                        ProfileStat(label: "Following", value: "\(loaded.followingCount)")
                    }
                    .buttonStyle(.plain)
                } else if let loaded {
                    // Private to you → counts show, but the lists stay hidden.
                    ProfileStat(label: "Followers", value: "\(loaded.followerCount)")
                    ProfileStat(label: "Following", value: "\(loaded.followingCount)")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile?.displayName ?? "Player")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    ProBadge(isPro: profile?.isPro ?? false, compact: false)
                }
                if let court = profile?.homeCourt, !court.isEmpty {
                    Text(court)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            followButton
        }
    }

    // MARK: Follow control

    @ViewBuilder
    private var followButton: some View {
        switch relationship {
        case .isSelf:
            EmptyView()
        case .following:
            Button {
                confirmUnfollow = true
            } label: {
                capsuleLabel("Following", filled: false)
            }
            .buttonStyle(.plain)
            .disabled(store.isBusy)
            .confirmationDialog(
                "Are you sure you want to unfollow this person?",
                isPresented: $confirmUnfollow,
                titleVisibility: .visible
            ) {
                Button("Unfollow", role: .destructive) {
                    Task {
                        await store.unfollow(userId: userId)
                        await load()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        case .requested:
            Button {
                confirmCancelRequest = true
            } label: {
                capsuleLabel("Requested", filled: false, muted: true)
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Cancel this follow request?",
                isPresented: $confirmCancelRequest,
                titleVisibility: .visible
            ) {
                Button("Cancel Request", role: .destructive) {
                    Task {
                        await store.cancelFollowRequest(userId: userId)
                        await load()
                    }
                }
                Button("Keep Request", role: .cancel) {}
            }
        case .none:
            Button {
                guard let profile else { return }
                Task {
                    await store.sendFollowRequest(to: profile)
                    loaded?.relationship = .requested
                }
            } label: {
                capsuleLabel("Follow", filled: true)
            }
            .buttonStyle(.plain)
            .disabled(store.isBusy || profile == nil)
        }
    }

    private func capsuleLabel(_ text: String, filled: Bool, muted: Bool = false) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? Theme.background : (muted ? Theme.textSecondary : Theme.textPrimary))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(filled ? Theme.accent : Theme.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: filled ? 0 : 1))
    }

    // MARK: Private account

    private var privateCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(Theme.textSecondary)
            Text("This account is private")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Follow this player to see their sessions.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .cardStyle()
    }

    // MARK: Sessions

    private func sessionsSection(_ sessions: [FeedSession]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions").font(.headline).foregroundStyle(Theme.textPrimary)
            if sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(sessions) { session in
                    FeedCard(session: session, context: .feed)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        loaded = await store.loadPublicProfile(userId: userId)
        isLoading = false
    }
}
