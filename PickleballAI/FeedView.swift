import SwiftUI

enum FeedMode {
    case following, discover
    var title: String { self == .following ? "Home" : "Discover" }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showFindFriends = false
    @State private var showNotifications = false
    @State private var showLeaderboard = false
    @State private var feedMode: FeedMode = .following

    private var currentFeed: [FeedSession] {
        feedMode == .following ? store.feed : store.discoverFeed
    }
    private var reachedEnd: Bool {
        feedMode == .following ? store.feedReachedEnd : store.discoverReachedEnd
    }

    var body: some View {
        ProfileNavigationStack {
        ScrollView {
            LazyVStack(spacing: 12) {
                if currentFeed.isEmpty {
                    if feedMode == .following && store.isInitialFeedLoading {
                        ForEach(0..<3, id: \.self) { _ in FeedCardSkeleton() }
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(currentFeed) { session in
                        FeedCard(session: session)
                            .onAppear { loadMoreIfNeeded(session) }
                    }
                    if !reachedEnd {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable { await refresh() }
        .task(id: feedMode) {
            if feedMode == .discover && store.discoverFeed.isEmpty { await store.loadDiscover() }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 12) {
            AppHeader(title: "Feed") {
                HeaderPill {
                    HeaderIconButton(systemImage: "trophy", accessibilityTitle: "Leaderboard") {
                        showLeaderboard = true
                    }
                    HeaderIconButton(systemImage: "magnifyingglass", accessibilityTitle: "Find friends") {
                        showFindFriends = true
                    }
                    Button { showNotifications = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            if store.badgeCount > 0 {
                                Text("\(min(store.badgeCount, 9))\(store.badgeCount > 9 ? "+" : "")")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.background)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Theme.accent, in: Capsule())
                                    .offset(x: 9, y: -8)
                            }
                        }
                    }
                    .accessibilityLabel("Notifications")
                }
            }

            SegmentedControl(
                options: [(.following, "Following"), (.discover, "Discover")],
                selection: $feedMode
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            }
            .background(Theme.background)
        }
        .sheet(isPresented: $showFindFriends) {
            FindFriendsSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNotifications) {
            NotificationsView()
        }
        .sheet(isPresented: $showLeaderboard) {
            LeaderboardSheet()
        }
        .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if feedMode == .following {
            EmptyFeedState { showFindFriends = true }
                .padding(.top, 80)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "binoculars")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
                Text("Nothing to discover yet")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("New public sessions from the community will show up here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 80)
        }
    }

    private func loadMoreIfNeeded(_ session: FeedSession) {
        guard session.id == currentFeed.last?.id, !reachedEnd else { return }
        Task {
            if feedMode == .following {
                await store.loadFeed(reset: false)
            } else {
                await store.loadDiscover(reset: false)
            }
        }
    }

    private func refresh() async {
        if feedMode == .following {
            await store.loadFeed()
        } else {
            await store.loadDiscover()
        }
        Haptics.tap()
    }
}

struct EmptyFeedState: View {
    var action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.pickleball")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("Bring your crew in")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Your feed shows sessions from you and accepted friends.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Label("Find Friends", systemImage: "person.crop.circle.badge.plus")
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

struct FindFriendsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var searchQuery = ""
    @State private var contactStatus: String?

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AuthField(
                        placeholder: "Search name or @username",
                        text: $searchQuery,
                        autocapitalize: false,
                        textContentType: .username
                    )
                    .task(id: searchQuery) {
                        await store.searchProfilesAfterTyping(query: searchQuery)
                    }

                    if !store.searchResults.isEmpty {
                        ForEach(store.searchResults) { profile in
                            FriendCandidateRow(profile: profile, navigable: true)
                        }
                    }

                    contactsSection

                    InviteShareLink(
                        message: store.inviteShareMessage,
                        subject: "Join me on pickleball.ai",
                        source: "find_friends"
                    ) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Find Friends")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                store.searchResults = []
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var contactsSection: some View {
        Button {
            Task { await syncContacts() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find friends from your contacts")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Contacts are matched once and not stored.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)

        if let contactStatus {
            Text(contactStatus)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }

        if !store.contactMatches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("From contacts")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                ForEach(store.contactMatches) { match in
                    FriendCandidateRow(profile: match.profile, navigable: true)
                }
            }
        }
    }

    private func syncContacts() async {
        contactStatus = "Checking contacts permission..."
        do {
            let granted = try await ContactsImporter.requestAccess()
            guard granted else {
                contactStatus = "Contacts access was not granted. Search or share an invite instead."
                return
            }
            let phones = try ContactsImporter.fetchPhones()
            guard !phones.isEmpty else {
                contactStatus = "No phone numbers found in contacts."
                return
            }
            contactStatus = "Looking for players in your contacts..."
            await store.matchContacts(phones: phones)
            if store.errorMessage != nil {
                contactStatus = nil
                return
            }
            contactStatus = store.contactMatches.isEmpty ? "No matching players found yet." : nil
        } catch {
            contactStatus = error.localizedDescription
        }
    }
}
