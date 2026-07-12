import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.feedItems) { item in
                    FeedCard(item: item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
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

struct FeedCard: View {
    var item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch item {
            case .match(let match):
                MatchFeedContent(match: match)
            case .session(let session):
                SessionFeedContent(session: session)
            }

            Divider().overlay(Theme.hairline)

            HStack(spacing: 22) {
                SocialAction(icon: "hand.thumbsup", count: item.likeCount)
                SocialAction(icon: "bubble.right", count: item.commentCount)
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
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                if let count {
                    Text("\(count)")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

struct MatchFeedContent: View {
    var match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(initials: match.teamOne.first?.avatarInitials ?? "PB")
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(match.winningTeamNames) won")
                        .font(.headline)
                    Text("\(match.summary) at \(match.location)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(match.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                ScoreBox(label: "Team 1", score: match.teamOneScore)
                ScoreBox(label: "Team 2", score: match.teamTwoScore)
                FocusChip(title: match.focus.rawValue)
            }

            Text(match.note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct SessionFeedContent: View {
    var session: PracticeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.pickleball")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentSoft, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Practice session logged")
                        .font(.headline)
                    Text("\(session.durationMinutes) min at \(session.location)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                FocusChip(title: "\(session.wins)-\(max(session.matchesPlayed - session.wins, 0))")
                FocusChip(title: session.focus.rawValue)
                FocusChip(title: "\(session.drills.count) drills")
            }

            Text(session.takeaway)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScoreBox: View {
    var label: String
    var score: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("\(score)")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(minWidth: 72, minHeight: 56)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
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
