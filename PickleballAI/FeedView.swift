import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if store.feed.isEmpty {
                    EmptyFeedState()
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
    }
}

struct EmptyFeedState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.pickleball")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("No posts yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Log a session or follow players to fill your feed.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
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
