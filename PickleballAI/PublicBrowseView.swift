import SwiftUI

/// What a signed-out visitor sees instead of the phone-auth screen: a
/// read-only preview of real public activity, so the app can sell itself
/// before asking for a phone number. Reading is free; every interactive tap
/// (like, comment, a card itself, the persistent CTA) opens `AuthView` as a
/// full-screen cover — the "soft wall." Backed by the narrow
/// `public_feed_preview` RPC, not the authenticated feed paths.
struct PublicBrowseView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAuth = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if store.publicPreviewFeed.isEmpty {
                    if store.isPublicPreviewLoading {
                        ForEach(0..<3, id: \.self) { _ in FeedCardSkeleton() }
                    } else if let message = store.publicPreviewLoadError {
                        errorState(message: message)
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(store.publicPreviewFeed) { item in
                        PublicPreviewCard(item: item) { showAuth = true }
                            .onAppear { loadMoreIfNeeded(item) }
                    }
                    if !store.publicPreviewReachedEnd {
                        ProgressView()
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable { await store.loadPublicPreviewFeed() }
        .safeAreaInset(edge: .top) {
            AppHeader(title: "piclr", titleFont: Theme.wordmark(22)) {
                Button("Sign In") { showAuth = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .background(Theme.background)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                signUpBar
                // Same tab bar as signed-in, so the app doesn't visually change
                // shape after signing up. Home is always "selected" (guests
                // only ever see this one page); tapping Play or Profile opens
                // the sign-up sheet instead of switching content — that switch
                // happens in `guestTabSelection`'s setter, not `onReselect`
                // (which only fires for taps on the already-selected tab, i.e.
                // Home, where it should stay a no-op).
                AppTabBar(selection: guestTabSelection)
            }
            .background(Theme.background)
        }
        .task {
            if store.publicPreviewFeed.isEmpty { await store.loadPublicPreviewFeed() }
        }
        .fullScreenCover(isPresented: $showAuth) {
            AuthView()
        }
    }

    /// Always reports Home as selected; setting it to Play/Profile opens the
    /// sign-up sheet instead of actually switching (there's nothing behind
    /// those tabs to switch to pre-auth).
    private var guestTabSelection: Binding<Int> {
        Binding(
            get: { 0 },
            set: { newValue in if newValue != 0 { showAuth = true } }
        )
    }

    private var signUpBar: some View {
        Button { showAuth = true } label: {
            Text("Sign up free")
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.pickleball")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("Nothing to preview yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Public sessions from the community will show up here.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 80)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await store.loadPublicPreviewFeed() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 80)
    }

    private func loadMoreIfNeeded(_ item: PublicFeedPreviewItem) {
        guard item.id == store.publicPreviewFeed.last?.id, !store.publicPreviewReachedEnd else { return }
        Task { await store.loadPublicPreviewFeed(reset: false) }
    }
}

/// A read-only, non-navigable stand-in for `FeedCard` — no like/comment/
/// share/repost actions, no profile navigation. The whole card is one tap
/// target that opens the sign-up sheet.
private struct PublicPreviewCard: View {
    let item: PublicFeedPreviewItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProfileAvatar(url: item.authorAvatarURL, initials: item.authorAvatarInitials ?? "PB", size: 44, userId: nil, unlinked: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.authorDisplayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("@\(item.authorUsername) · \(item.date.relativeLabel)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }

                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                if let location = item.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                if !item.matches.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(item.matches.enumerated()), id: \.offset) { _, match in
                            if let score = match.scoreLine {
                                Text(score)
                                    .font(.caption.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(match.won == true ? Theme.win : Theme.loss)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Theme.surfaceElevated, in: Capsule())
                            }
                        }
                    }
                }

                HStack(spacing: 20) {
                    Label("\(item.likeCount)", systemImage: "hand.thumbsup")
                    Label("\(item.commentCount)", systemImage: "bubble.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.authorDisplayName)'s session. Sign up to see more.")
    }
}
