import SwiftUI

/// Which list to show — reached by tapping the Followers / Following counts.
enum FollowListKind {
    case followers
    case following

    var title: String {
        switch self {
        case .followers: return "Followers"
        case .following: return "Following"
        }
    }

    var emptyMessage: String {
        switch self {
        case .followers: return "No followers yet."
        case .following: return "Not following anyone yet."
        }
    }
}

/// A simple list of names with a follow-back indicator (Instagram-style).
/// Read-only for now — no follow/unfollow actions here.
struct FollowListView: View {
    @EnvironmentObject private var store: AppStore
    let kind: FollowListKind

    private var entries: [FollowListEntry] {
        kind == .followers ? store.followers : store.following
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if entries.isEmpty {
                    Text(kind.emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            OtherProfileView(userId: entry.userId, placeholder: entry.profile)
                        } label: {
                            FollowEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadFollowLists() }
        .refreshable { await store.loadFollowLists() }
    }
}

struct FollowEntryRow: View {
    var entry: FollowListEntry

    var body: some View {
        HStack(spacing: 14) {
            ProfileAvatar(profile: entry.profile, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.profile?.displayName ?? "Unknown")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let username = entry.profile?.username {
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            FollowActionButton(entry: entry)
        }
        .cardStyle()
    }
}

/// Right-side follow control (Instagram-style):
///   • Following  — you already follow them back (accepted). Static.
///   • Requested  — you've sent a follow request that's still pending. Static.
///   • Follow     — no edge yet → tap to send a follow request.
/// Renders nothing for users hidden by RLS (no profile to act on).
struct FollowActionButton: View {
    @EnvironmentObject private var store: AppStore
    var entry: FollowListEntry
    @State private var confirmUnfollow = false

    var body: some View {
        if entry.userId == store.currentProfile?.id {
            // Don't offer a follow control for yourself in someone's list.
            EmptyView()
        } else if entry.isFollowedByMe {
            Button {
                confirmUnfollow = true
            } label: {
                capsule("Following", filled: false, muted: false)
            }
            .buttonStyle(.plain)
            .disabled(store.isBusy)
            .confirmationDialog(
                "Are you sure you want to unfollow this person?",
                isPresented: $confirmUnfollow,
                titleVisibility: .visible
            ) {
                Button("Unfollow", role: .destructive) {
                    Task { await store.unfollow(userId: entry.userId) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else if let profile = entry.profile {
            if store.requestedFollowIds.contains(entry.userId) {
                capsule("Requested", filled: false, muted: true)
            } else {
                Button {
                    Task { await store.sendFollowRequest(to: profile) }
                } label: {
                    capsule("Follow", filled: true, muted: false)
                }
                .buttonStyle(.plain)
                .disabled(store.isBusy)
            }
        }
    }

    private func capsule(_ text: String, filled: Bool, muted: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(filled ? Theme.background : (muted ? Theme.textSecondary : Theme.textPrimary))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(filled ? Theme.accent : Theme.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: filled ? 0 : 1))
    }
}

/// Another user's followers/following list, reached from their profile. Loads
/// on demand (the store's own `followers`/`following` remain the signed-in
/// user's). Each row's follow-back button is relative to me.
struct UserFollowListView: View {
    @EnvironmentObject private var store: AppStore
    let userId: UUID
    let kind: FollowListKind

    @State private var entries: [FollowListEntry] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if entries.isEmpty {
                    Text(kind.emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            OtherProfileView(userId: entry.userId, placeholder: entry.profile)
                        } label: {
                            FollowEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        entries = await store.followList(for: userId, kind: kind)
        isLoading = false
    }
}
