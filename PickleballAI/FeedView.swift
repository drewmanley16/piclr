import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showFindFriends = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if store.feed.isEmpty {
                    EmptyFeedState {
                        showFindFriends = true
                    }
                        .padding(.top, 80)
                } else {
                    ForEach(store.feed) { session in
                        FeedCard(session: session)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable { await store.loadFeed() }
        .safeAreaInset(edge: .top) {
            AppHeader(title: "Home", showsChevron: true, onTitleTap: {}) {
                HeaderPill {
                    HeaderIconButton(systemImage: "magnifyingglass", accessibilityTitle: "Search") {}
                    HeaderIconButton(systemImage: "bell", accessibilityTitle: "Notifications") {}
                }
            }
            .background(Theme.background)
        }
        .sheet(isPresented: $showFindFriends) {
            FindFriendsSheet()
                .presentationDetents([.medium, .large])
        }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        AuthField(
                            placeholder: "Search username",
                            text: $searchQuery,
                            autocapitalize: false,
                            textContentType: .username
                        )
                        Button {
                            Task { await store.searchProfiles(query: searchQuery) }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.background)
                                .frame(width: 52, height: 52)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                        }
                        .disabled(searchQuery.normalizedUsername.count < 2)
                    }

                    if !store.searchResults.isEmpty {
                        ForEach(store.searchResults) { profile in
                            FriendCandidateRow(profile: profile)
                        }
                    }

                    ShareLink(
                        item: URL(string: "https://pickleball.ai/invite")!,
                        subject: Text("Join my pickleball crew"),
                        message: Text("Add me on pickleball.ai and log matches with the crew.")
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct FeedCard: View {
    @EnvironmentObject private var store: AppStore
    var session: FeedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(initials: session.author.initials)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.author.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("@\(session.author.username)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(session.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(session.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 8) {
                if let focus = session.focus, !focus.isEmpty {
                    FocusChip(title: focus)
                }
                FocusChip(title: "\(session.durationMinutes) min")
                if let location = session.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            if let takeaway = session.takeaway, !takeaway.isEmpty {
                Text(takeaway)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Divider().overlay(Theme.hairline)

            HStack(spacing: 22) {
                Button {
                    Task { await store.toggleLike(session) }
                } label: {
                    SocialLabel(icon: "hand.thumbsup", count: session.likeCount)
                }
                .buttonStyle(.plain)

                SocialAction(icon: "bubble.right", count: session.commentCount)
                SocialAction(icon: "square.and.arrow.up", count: nil)
                Spacer()
            }
        }
        .cardStyle()
    }
}

struct SocialAction: View {
    var icon: String
    var count: Int?

    var body: some View {
        Button {
        } label: {
            SocialLabel(icon: icon, count: count)
        }
        .buttonStyle(.plain)
    }
}

struct SocialLabel: View {
    var icon: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(minHeight: 44)
    }
}

struct FocusChip: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.accentSoft, in: Capsule())
            .foregroundStyle(Theme.accent)
    }
}
