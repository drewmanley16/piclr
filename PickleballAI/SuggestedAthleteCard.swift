import SwiftUI

enum SuggestedAthleteCardLayout {
    static let width: CGFloat = 108
    static let padding: CGFloat = 10
}

/// A single card in the Home feed's "Suggested Athletes" row: avatar, name,
/// mutual-connection reason, a Follow button, and a dismiss (X).
struct SuggestedAthleteCard: View {
    @EnvironmentObject private var store: AppStore
    var athlete: SuggestedAthlete

    private var isRequested: Bool { store.requestedFollowIds.contains(athlete.profile.id) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                ProfileLink(userId: athlete.profile.id, placeholder: athlete.profile) {
                    VStack(spacing: 2) {
                        ProfileAvatar(profile: athlete.profile, size: 84, unlinked: true)
                        Text(athlete.profile.username)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(athlete.reasonLabel)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                followButton
            }

            dismissButton
        }
        .padding(SuggestedAthleteCardLayout.padding)
        .padding(.top, 6)
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
                .frame(maxWidth: .infinity, minHeight: 40)
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
                .frame(width: 28, height: 28)
                .background(Theme.surfaceElevated, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
    }
}
