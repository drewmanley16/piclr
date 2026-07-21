import SwiftUI

enum SuggestedAthleteCardLayout {
    static let width: CGFloat = 148
    static let padding: CGFloat = 10
    static let avatarSize: CGFloat = 112
}

/// A single card in the Home feed's "Suggested Athletes" row: a large avatar
/// with the dismiss (X) overlaid on its corner, name, mutual-connection
/// reason, and a Follow button — mirrors the reference "Suggested Athletes"
/// card (big photo, minimal chrome) rather than a small centered avatar.
struct SuggestedAthleteCard: View {
    @EnvironmentObject private var store: AppStore
    var athlete: SuggestedAthlete

    private var isRequested: Bool { store.requestedFollowIds.contains(athlete.profile.id) }

    var body: some View {
        VStack(spacing: 8) {
            ProfileLink(userId: athlete.profile.id, placeholder: athlete.profile) {
                ZStack(alignment: .topTrailing) {
                    ProfileAvatar(profile: athlete.profile, size: SuggestedAthleteCardLayout.avatarSize, unlinked: true)
                        .frame(maxWidth: .infinity)
                    dismissButton
                }
                .contentShape(Rectangle())
            }

            VStack(spacing: 2) {
                Text(athlete.profile.username)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(athlete.reasonLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            followButton
        }
        .padding(SuggestedAthleteCardLayout.padding)
        .frame(width: SuggestedAthleteCardLayout.width)
        .cardStyle(padding: 0)
    }

    private var followButton: some View {
        Button {
            Haptics.impact()
            Task { await store.sendFollowRequest(to: athlete.profile) }
        } label: {
            Text(isRequested ? "Requested" : "Follow")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isRequested ? Theme.textTertiary : Theme.background)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(isRequested ? Theme.surfaceElevated : Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isRequested || store.isBusy)
    }

    private var dismissButton: some View {
        Button {
            Haptics.tap()
            Task { await store.dismissSuggestion(userId: athlete.profile.id) }
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 24)
                .background(Theme.background.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
