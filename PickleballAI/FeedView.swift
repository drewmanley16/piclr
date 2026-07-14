import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showFindFriends = false
    @State private var showNotifications = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if store.feed.isEmpty {
                    EmptyFeedState {
                        showFindFriends = true
                    }
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
                    HeaderIconButton(systemImage: "magnifyingglass", accessibilityTitle: "Find friends") {
                        showFindFriends = true
                    }
                    Button { showNotifications = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            if store.badgeCount > 0 {
                                Text("\(min(store.badgeCount, 9))\(store.badgeCount > 9 ? "+" : "")")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.background)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Theme.accent, in: Capsule())
                                    .offset(x: 9, y: -8)
                            }
                        }
                    }
                    .accessibilityLabel("Notifications")
                }
            }
            .background(Theme.background)
        }
        .sheet(isPresented: $showFindFriends) {
            FindFriendsSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNotifications) {
            NotificationsView()
        }
    }
}

struct EmptyFeedState: View {
    var action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.pickleball")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("Bring your crew in")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Your feed shows sessions from you and accepted friends.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Label("Find Friends", systemImage: "person.crop.circle.badge.plus")
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

struct FindFriendsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var searchQuery = ""
    @State private var contactStatus: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        AuthField(
                            placeholder: "Search username",
                            text: $searchQuery,
                            autocapitalize: false,
                            textContentType: .username
                        )
                        Button {
                            Task { await store.searchProfiles(query: searchQuery) }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.background)
                                .frame(width: 52, height: 52)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                        }
                        .disabled(searchQuery.normalizedUsername.count < 2)
                    }

                    if !store.searchResults.isEmpty {
                        ForEach(store.searchResults) { profile in
                            FriendCandidateRow(profile: profile, navigable: true)
                        }
                    }

                    contactsSection

                    ShareLink(
                        item: URL(string: "https://pickleball.ai/invite")!,
                        subject: Text("Join my pickleball crew"),
                        message: Text("Add me on pickleball.ai and log matches with the crew.")
                    ) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Find Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var contactsSection: some View {
        Button {
            Task { await syncContacts() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find friends from your contacts")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Contacts are matched once and not stored.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)

        if let contactStatus {
            Text(contactStatus)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }

        if !store.contactMatches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("From contacts")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                ForEach(store.contactMatches) { match in
                    FriendCandidateRow(profile: match.profile, navigable: true)
                }
            }
        }
    }

    private func syncContacts() async {
        contactStatus = "Checking contacts permission..."
        do {
            let granted = try await ContactsImporter.requestAccess()
            guard granted else {
                contactStatus = "Contacts access was not granted. Search or share an invite instead."
                return
            }
            let phones = try ContactsImporter.fetchPhones()
            guard !phones.isEmpty else {
                contactStatus = "No phone numbers found in contacts."
                return
            }
            contactStatus = "Looking for players in your contacts..."
            await store.matchContacts(phones: phones)
            if store.errorMessage != nil {
                contactStatus = nil
                return
            }
            contactStatus = store.contactMatches.isEmpty ? "No matching players found yet." : nil
        } catch {
            contactStatus = error.localizedDescription
        }
    }
}

struct FeedCard: View {
    @EnvironmentObject private var store: AppStore
    var session: FeedSession
    @State private var showComments = false

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

            if session.isRepost {
                Label("Reposted", systemImage: "arrow.2.squarepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
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

            if !session.sortedActivities.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.sortedActivities) { activity in
                        ActivityLine(activity: activity)
                    }
                }
                .padding(.vertical, 2)
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

                Button { showComments = true } label: {
                    SocialLabel(icon: "bubble.right", count: session.commentCount)
                }
                .buttonStyle(.plain)

                SocialAction(icon: "square.and.arrow.up", count: nil)

                if canRepost {
                    Button {
                        Task { await store.requestRepost(session) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.2.squarepath").font(.body.weight(.semibold))
                            Text(requested ? "Requested" : "Repost").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(requested ? Theme.textTertiary : Theme.accent)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(requested)
                }

                Spacer()
            }
        }
        .cardStyle()
        .sheet(isPresented: $showComments) {
            CommentsView(session: session)
        }
    }

    private var canRepost: Bool {
        guard let me = store.currentProfile?.id else { return false }
        return session.userId != me && session.isParticipant(me)
    }

    private var requested: Bool { store.requestedRepostSessionIds.contains(session.id) }
}

struct ActivityLine: View {
    var activity: SessionActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activity.isMatch ? "flag.checkered" : "figure.cooldown")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if activity.isMatch, let won = activity.won {
                        Text(won ? "W" : "L")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(won ? Theme.background : Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(won ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var detail: String? {
        if activity.isMatch {
            var parts: [String] = []
            let partners = activity.partners.map { $0.handle ?? $0.displayName }
            let opps = activity.opponents.map { $0.handle ?? $0.displayName }
            if !partners.isEmpty { parts.append("with " + partners.joined(separator: ", ")) }
            if !opps.isEmpty { parts.append("vs " + opps.joined(separator: ", ")) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            let bits = [activity.reps, activity.notes].compactMap { $0 }.filter { !$0.isEmpty }
            return bits.isEmpty ? nil : bits.joined(separator: " — ")
        }
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
