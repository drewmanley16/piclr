import SwiftUI

enum FeedMode {
    case following, discover
    var title: String { self == .following ? "Home" : "Discover" }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showFindFriends = false
    @State private var showNotifications = false
    @State private var feedMode: FeedMode = .following
    @State private var showFeedMenu = false

    private var currentFeed: [FeedSession] {
        feedMode == .following ? store.feed : store.discoverFeed
    }
    private var reachedEnd: Bool {
        feedMode == .following ? store.feedReachedEnd : store.discoverReachedEnd
    }

    var body: some View {
        ProfileNavigationStack {
        ScrollView {
            LazyVStack(spacing: 12) {
                if currentFeed.isEmpty {
                    if feedMode == .following && store.isInitialFeedLoading {
                        ProgressView("Loading feed…")
                            .tint(Theme.accent)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(currentFeed) { session in
                        FeedCard(session: session)
                            .onAppear { loadMoreIfNeeded(session) }
                    }
                    if !reachedEnd {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable { await refresh() }
        .confirmationDialog("Feed", isPresented: $showFeedMenu, titleVisibility: .visible) {
            Button("Following") { feedMode = .following }
            Button("Discover") { feedMode = .discover }
        }
        .task(id: feedMode) {
            if feedMode == .discover && store.discoverFeed.isEmpty { await store.loadDiscover() }
        }
        .safeAreaInset(edge: .top) {
            AppHeader(title: feedMode.title, showsChevron: true, onTitleTap: { showFeedMenu = true }) {
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
        .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if feedMode == .following {
            EmptyFeedState { showFindFriends = true }
                .padding(.top, 80)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "binoculars")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
                Text("Nothing to discover yet")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("New public sessions from the community will show up here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 80)
        }
    }

    private func loadMoreIfNeeded(_ session: FeedSession) {
        guard session.id == currentFeed.last?.id, !reachedEnd else { return }
        Task {
            if feedMode == .following {
                await store.loadFeed(reset: false)
            } else {
                await store.loadDiscover(reset: false)
            }
        }
    }

    private func refresh() async {
        if feedMode == .following {
            await store.loadFeed()
        } else {
            await store.loadDiscover()
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
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AuthField(
                        placeholder: "Search name or @username",
                        text: $searchQuery,
                        autocapitalize: false,
                        textContentType: .username
                    )
                    .task(id: searchQuery) {
                        await store.searchProfilesAfterTyping(query: searchQuery)
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
            .onDisappear {
                store.searchResults = []
            }
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
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var confirmBlock = false
    @State private var confirmRemoveTag = false
    @State private var reportTarget: ReportTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.isRepost {
                Label("Reposted", systemImage: "arrow.2.squarepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 12) {
                ProfileLink(userId: session.author.id, placeholder: session.author) {
                    HStack(spacing: 12) {
                        ProfileAvatar(profile: session.author, size: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.author.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("@\(session.author.username) · \(session.date.relativeLabel)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Spacer()
                Menu {
                    if isOwner {
                        Button {
                            showEditor = true
                        } label: {
                            Label("Edit Session", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete Session", systemImage: "trash")
                        }
                    } else {
                        Button {
                            reportTarget = .session(session.id)
                        } label: {
                            Label("Report Session", systemImage: "exclamationmark.bubble")
                        }
                        if isTagged {
                            Button(role: .destructive) {
                                confirmRemoveTag = true
                            } label: {
                                Label("Remove Me from Session", systemImage: "person.badge.minus")
                            }
                        }
                        Button(role: .destructive) {
                            confirmBlock = true
                        } label: {
                            Label("Block Player", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Session actions")
            }

            // Title + a quiet context line (focus / location — never duration; that
            // lives in the stat strip, so it can't be mistaken for a timestamp).
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle = metaSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            // Hevy-style summary strip: the session's substance in one scannable row.
            SessionSummaryStrip(session: session)

            // Activities as a clean itemized list (Hevy's exercise rows), score inline.
            if !session.sortedActivities.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(session.sortedActivities.enumerated()), id: \.element.id) { index, activity in
                        if index > 0 {
                            Divider().overlay(Theme.hairline)
                        }
                        ActivityRow(activity: activity)
                            .padding(.vertical, 10)
                    }
                }
            }

            if let photo = session.photoUrl, let url = URL(string: photo) {
                RemoteImage(url: url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            } else if session.photoPath != nil {
                Rectangle()
                    .fill(Theme.surfaceElevated)
                    .overlay { ProgressView().tint(Theme.textTertiary) }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }

            if let takeaway = session.takeaway, !takeaway.isEmpty {
                Text(takeaway)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Divider().overlay(Theme.hairline)

            // Stable left cluster (like · comment · share) so tap targets never move
            // card-to-card; the conditional Repost lives quietly on the trailing edge.
            HStack(spacing: 20) {
                let liked = store.likedSessionIds.contains(session.id)
                Button {
                    Task { await store.toggleLike(session) }
                } label: {
                    SocialLabel(
                        icon: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                        count: store.likeCount(for: session),
                        isHighlighted: liked
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liked ? "Unlike" : "Like")

                Button { showComments = true } label: {
                    SocialLabel(icon: "bubble.right", count: session.commentCount)
                }
                .buttonStyle(.plain)

                ShareLink(item: session.shareSummary) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minHeight: 44)
                }

                Spacer()

                if canRepost {
                    Button {
                        Task { await store.requestRepost(session) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.2.squarepath").font(.footnote.weight(.bold))
                            Text(requested ? "Requested" : "Repost").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(requested ? Theme.textTertiary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(requested)
                    .accessibilityLabel(requested ? "Repost requested" : "Repost")
                }
            }

            if !session.inlineComments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.inlineComments) { comment in
                        InlineCommentRow(comment: comment)
                    }

                    if session.commentCount > session.inlineComments.count {
                        Button {
                            showComments = true
                        } label: {
                            Text("View all \(session.commentCount) comments")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(minHeight: 28, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .cardStyle(bordered: false)
        .sheet(isPresented: $showComments) {
            CommentsView(session: session)
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target)
        }
        .fullScreenCover(isPresented: $showEditor) {
            ActiveSessionView(existingSession: session)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                Task { _ = await store.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Block this player?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task { _ = await store.blockUser(userId: session.userId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer be able to find, view, or interact with each other.")
        }
        .confirmationDialog(
            "Remove yourself from this session?",
            isPresented: $confirmRemoveTag,
            titleVisibility: .visible
        ) {
            Button("Remove Me", role: .destructive) {
                Task { _ = await store.removeSelfFromSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your player tag will be removed from every match in this session.")
        }
    }

    /// Focus · location — the quiet context under the title. Duration is deliberately
    /// excluded (it's a labeled stat) so nothing reads like a second timestamp.
    private var metaSubtitle: String? {
        let parts = [session.focus, session.location]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var isOwner: Bool { store.currentProfile?.id == session.userId }
    private var isTagged: Bool {
        guard let uid = store.currentProfile?.id else { return false }
        return session.isParticipant(uid)
    }

    private var canRepost: Bool {
        guard let me = store.currentProfile?.id else { return false }
        return session.userId != me && session.isParticipant(me)
    }

    private var requested: Bool { store.requestedRepostSessionIds.contains(session.id) }
}

struct InlineCommentRow: View {
    let comment: Comment

    var body: some View {
        (
            Text(comment.authorName)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            + Text("  \(comment.body)")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
        )
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hevy-style summary strip: the session's substance (duration, matches, record)
/// as evenly-weighted stat columns, so a glance tells you what happened.
struct SessionSummaryStrip: View {
    let session: FeedSession

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 1, height: 26)
                }
                VStack(spacing: 3) {
                    Text(stat.value)
                        .font(.system(size: 17, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(stat.emphasized ? Theme.accent : Theme.textPrimary)
                    Text(stat.label)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
    }

    private struct Stat { let value: String; let label: String; var emphasized = false }

    private var stats: [Stat] {
        var result: [Stat] = [Stat(value: durationText, label: "Duration")]
        let matches = session.matchCount
        if matches > 0 {
            result.append(Stat(value: "\(matches)", label: matches == 1 ? "Match" : "Matches"))
            result.append(Stat(value: "\(wins)–\(losses)", label: "Record", emphasized: wins > 0 && losses == 0))
        } else if session.practiceCount > 0 {
            let drills = session.practiceCount
            result.append(Stat(value: "\(drills)", label: drills == 1 ? "Drill" : "Drills"))
        }
        return result
    }

    private var wins: Int { session.sortedActivities.filter { $0.isMatch && $0.won == true }.count }
    private var losses: Int { session.sortedActivities.filter { $0.isMatch && $0.won == false }.count }

    private var durationText: String {
        let m = session.durationMinutes
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

/// A single activity in the itemized list (Hevy's exercise row). Leading tile,
/// title + who-played, and — for matches — the score with a compact W/L badge.
struct ActivityRow: View {
    let activity: SessionActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.isMatch ? "flag.checkered" : "figure.pickleball")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.isMatch ? "Match" : activity.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if activity.isMatch, let score = activity.scoreLine {
                HStack(spacing: 8) {
                    Text(score)
                        .font(.callout.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    if let won = activity.won {
                        Text(won ? "W" : "L")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.background)
                            .frame(width: 22, height: 22)
                            .background(won ? Theme.win : Theme.loss, in: Circle())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
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
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(isHighlighted ? Theme.accent : Theme.textSecondary)
        .frame(minHeight: 44)
        .animation(.easeInOut(duration: 0.16), value: isHighlighted)
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
