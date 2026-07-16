import SwiftUI

struct FriendCandidateRow: View {
    @EnvironmentObject private var store: AppStore
    var profile: Profile
    /// When true, tapping the name/avatar area pushes the player's profile
    /// (Instagram-style). Only enable within a NavigationStack.
    var navigable: Bool = false

    var body: some View {
        IdentityRow(
            avatarURL: profile.avatarURL,
            initials: profile.initials,
            name: profile.displayName,
            detail: "@\(profile.username)",
            userId: navigable ? profile.id : nil,
            placeholder: profile
        ) {
            followButton
        }
        .cardStyle()
    }

    private var followButton: some View {
        Button {
            Haptics.impact()
            Task { await store.sendFollowRequest(to: profile) }
        } label: {
            Image(systemName: store.requestedFollowIds.contains(profile.id) ? "checkmark" : "plus")
                .font(.body.weight(.bold))
                .foregroundStyle(store.requestedFollowIds.contains(profile.id) ? Theme.textTertiary : Theme.background)
                .frame(width: 40, height: 40)
                .background(store.requestedFollowIds.contains(profile.id) ? Theme.surfaceElevated : Theme.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(store.requestedFollowIds.contains(profile.id) || store.isBusy)
    }
}
