import SwiftUI

/// Which list to show — reached by tapping the Followers / Following counts.
enum FollowListKind: Equatable {
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
                        FollowEntryRow(
                            entry: entry,
                            allowsFollowerRemoval: kind == .followers
                        )
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
    @EnvironmentObject private var store: AppStore
    var entry: FollowListEntry
    var allowsFollowerRemoval = false
    @State private var confirmRemove = false
    @State private var confirmBlock = false

    var body: some View {
        HStack(spacing: 14) {
            ProfileLink(userId: entry.userId, placeholder: entry.profile) {
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
                }
            }

            Spacer()

            FollowActionButton(entry: entry)

            Menu {
                if allowsFollowerRemoval {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove Follower", systemImage: "person.badge.minus")
                    }
                }
                Button(role: .destructive) {
                    confirmBlock = true
                } label: {
                    Label("Block Player", systemImage: "person.crop.circle.badge.xmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Follower actions")
        }
        .cardStyle()
        .confirmationDialog("Remove this follower?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Follower", role: .destructive) {
                Task { await store.removeFollower(userId: entry.userId) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Block this player?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task { _ = await store.blockUser(userId: entry.userId) }
            }
            Button("Cancel", role: .cancel) {}
        }
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
    @State private var confirmCancelRequest = false

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
                Button {
                    confirmCancelRequest = true
                } label: {
                    capsule("Requested", filled: false, muted: true)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Cancel this follow request?",
                    isPresented: $confirmCancelRequest,
                    titleVisibility: .visible
                ) {
                    Button("Cancel Request", role: .destructive) {
                        Task { await store.cancelFollowRequest(userId: entry.userId) }
                    }
                    Button("Keep Request", role: .cancel) {}
                }
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
                        FollowEntryRow(entry: entry)
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
