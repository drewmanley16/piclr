import SwiftUI

/// Horizontal "Suggested Athletes" row inserted after the first Home feed
/// post: skeleton while loading, then ranked follow-suggestion cards with an
/// "Invite a friend" action reusing the same share flow as `FindFriendsSheet`.
struct SuggestedAthletesRow: View {
    @EnvironmentObject private var store: AppStore
    var isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if isLoading {
                        ForEach(0..<3, id: \.self) { _ in cardSkeleton }
                    } else {
                        ForEach(store.suggestedAthletes) { athlete in
                            SuggestedAthleteCard(athlete: athlete)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack {
            Text("Suggested Athletes")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            InviteShareLink(
                message: store.inviteShareMessage,
                subject: "Join me on piclr",
                source: "suggested_athletes"
            ) {
                Label("Invite a friend", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var cardSkeleton: some View {
        VStack(spacing: 8) {
            Circle().fill(Theme.surfaceElevated)
                .frame(width: SuggestedAthleteCardLayout.avatarSize, height: SuggestedAthleteCardLayout.avatarSize)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surfaceElevated).frame(width: 72, height: 12)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.surfaceElevated).frame(width: 50, height: 10)
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(Theme.surfaceElevated).frame(height: 36)
        }
        .padding(SuggestedAthleteCardLayout.padding)
        .frame(width: SuggestedAthleteCardLayout.width)
        .cardStyle(padding: 0)
        .shimmer()
        .redacted(reason: .placeholder)
    }
}
