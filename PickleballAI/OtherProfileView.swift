import SwiftUI

/// Another user's profile, reached by tapping a name in a follower/following
/// list. Header (name, avatar, counts) is always visible. Their sessions are
/// shown only when the signed-in user follows them (accepted); otherwise an
/// Instagram-style "This profile is private" state with a follow control.
struct OtherProfileView: View {
    @EnvironmentObject private var store: AppStore

    let userId: UUID
    /// Optional pre-known profile so the header can render instantly while the
    /// full snapshot loads.
    var placeholder: Profile?

    @State private var loaded: PublicProfile?
    @State private var isLoading = true

    private var profile: Profile? { loaded?.profile ?? placeholder }
    private var relationship: FollowRelationship { loaded?.relationship ?? .none }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let loaded {
                    if loaded.relationship.canViewContent {
                        sessionsSection(loaded.sessions)
                    } else {
                        privateCard
                    }
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(profile.map { "@\($0.username)" } ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                ProfileAvatar(profile: profile, size: 76)

                if loaded?.relationship.canViewContent == true, let loaded {
                    ProfileStat(label: "Sessions", value: "\(loaded.sessions.count)")
                }
                ProfileStat(label: "Followers", value: "\(loaded?.followerCount ?? 0)")
                ProfileStat(label: "Following", value: "\(loaded?.followingCount ?? 0)")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayName ?? "Player")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
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
            capsuleLabel("Following", filled: false)
        case .requested:
            capsuleLabel("Requested", filled: false, muted: true)
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

    // MARK: Private state

    private var privateCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(Theme.textSecondary)
            Text("This profile is private")
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
                    PostingRow(session: session)
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
