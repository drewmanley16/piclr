import SwiftUI

struct FeedCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSession) private var openSession
    var session: FeedSession
    /// False when this card is already the content of a session detail screen,
    /// so tapping it doesn't push another copy of itself onto the stack.
    var openable: Bool = true
    /// True on the session detail screen, where activity notes render in full.
    /// On a preview card they're clamped, and the trailing "…" is what invites
    /// the tap through to here — so this is deliberately not `!openable`, which
    /// only says whether tapping does anything.
    var expanded: Bool = false
    /// Which surface this card stands on. `.workout` frames scores from the
    /// viewer's side and treats a repost as credited games they can drop from
    /// their record, rather than a post they published.
    var context: Context = .feed

    enum Context {
        /// The public feed: the author's own framing, reposts are publications.
        case feed
        /// The viewer's own workout history (Recent).
        case workout
    }
    @State private var showComments = false
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var confirmBlock = false
    @State private var confirmRemoveTag = false
    @State private var reportTarget: ReportTarget?
    @State private var shareItem: ShareImage?
    @State private var repostInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Automatic tagged-workout credits are reposts by data shape only —
            // the user never published them, so they get no "reposted" banner.
            if session.isRepost && session.posted {
                Label("\(session.author.displayName) reposted", systemImage: "arrow.2.squarepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            headerRow

            VStack(alignment: .leading, spacing: 12) {
                titleBlock

                activityList

                photoSection

                if let takeaway = session.postTakeaway, !takeaway.isEmpty {
                    Text(takeaway)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard openable else { return }
                openSession(session.id, placeholder: session)
            }

            Divider().overlay(Theme.hairline)

            actionRow

            inlineComments
        }
        .cardStyle(bordered: false)
        .sheet(isPresented: $showComments) {
            CommentsView(session: session)
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target)
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(payload: item)
        }
        .fullScreenCover(isPresented: $showEditor) {
            ActiveSessionView(existingSession: session)
        }
        .confirmationDialog(destructivePrompt, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(destructiveTitle, role: .destructive) {
                Task {
                    if removesWorkoutCredit {
                        _ = await store.removeWorkoutCredit(session)
                    } else if session.isRepost {
                        _ = await store.unrepostSession(session)
                    } else {
                        _ = await store.deleteSession(session)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if removesWorkoutCredit {
                Text("This removes the credited games from your Workout history and record, and removes your tag from the original post.")
            } else if session.isRepost {
                Text("The games stay in your private Workout history and record.")
            }
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

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            ProfileLink(userId: session.postAuthor.id, placeholder: session.postAuthor) {
                HStack(spacing: 12) {
                    ProfileAvatar(profile: session.postAuthor, size: 44, unlinked: true)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(session.postAuthor.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            ProBadge(isPro: session.postAuthor.isPro)
                        }
                        Text("@\(session.postAuthor.username) · \(session.postDate.relativeLabel)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
            Menu {
                if isOwner {
                    if !session.isRepost {
                        Button {
                            showEditor = true
                        } label: {
                            Label("Edit Session", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(destructiveTitle, systemImage: "trash")
                    }
                } else {
                    Button {
                        reportTarget = .session(session.id)
                    } label: {
                        Label("Report Session", systemImage: "exclamationmark.bubble")
                    }
                    if isTagged && !session.isRepost {
                        Button(role: .destructive) {
                            confirmRemoveTag = true
                        } label: {
                            Label("Remove Me from Session", systemImage: "person.badge.minus")
                        }
                    }
                    Button(role: .destructive) {
                        confirmBlock = true
                    } label: {
                        Label(
                            session.isRepost ? "Block Reposter" : "Block Player",
                            systemImage: "person.crop.circle.badge.xmark"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Session actions")
        }
    }

    // MARK: Title

    // Title + a quiet context line (focus / location · duration). Watch
    // biometrics ride the trailing edge of the title as compact icon chips,
    // so they read as a light stat rather than a space-hungry stat bar.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let weeks = session.postStreakWeek, weeks >= 2 {
                StreakBadge(weeks: weeks)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.postDisplayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if session.hasPostWorkoutMetrics {
                    Spacer(minLength: 8)
                    InlineHealthMetrics(session: session)
                        .fixedSize()
                }
            }
            if let subtitle = metaSubtitleText {
                subtitle
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel(metaSubtitleAccessibilityLabel ?? "")
            }
        }
    }

    // MARK: Activities

    // A single match leads with its score; multi-activity sessions lead with a
    // compact record and keep the same head-to-head language for every match.
    @ViewBuilder
    private var activityList: some View {
        if isMultiActivity {
            SessionMatchList(
                activities: displayActivities,
                author: displayAuthor,
                noteLineLimit: expanded ? nil : 1
            )
        } else if let solo = displayActivities.first {
            MatchScorecard(activity: solo, author: displayAuthor, noteLineLimit: expanded ? nil : 2)
                .padding(.vertical, 4)
        }
    }

    // MARK: Photo

    @ViewBuilder
    private var photoSection: some View {
        if let photo = session.postPhotoURL, let url = URL(string: photo) {
            RemoteImage(url: url)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        } else if session.postPhotoPath != nil {
            Rectangle()
                .fill(Theme.surfaceElevated)
                .overlay { ProgressView().tint(Theme.textTertiary) }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        }
    }

    // MARK: Actions

    // Stable left cluster (like · comment · share) so tap targets never move
    // card-to-card; the conditional Repost lives quietly on the trailing edge.
    private var actionRow: some View {
        HStack(spacing: 20) {
            let liked = store.likedSessionIds.contains(session.id)
            Button {
                Haptics.impact()
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
            .accessibilityLabel("Comments")

            Button {
                if let image = renderShareImage(for: session) {
                    Haptics.tap()
                    shareItem = ShareImage(image: image, caption: session.shareSummary)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share session")

            Spacer()

            if showRepostAction {
                Button {
                    Haptics.impact()
                    repostInFlight = true
                    Task {
                        _ = await store.repostSession(session)
                        repostInFlight = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.2.squarepath").font(.footnote.weight(.bold))
                        Text(alreadyReposted ? "Reposted" : "Repost").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(alreadyReposted ? Theme.textTertiary : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(alreadyReposted || repostInFlight)
                .accessibilityLabel(alreadyReposted ? "Reposted" : "Repost")
            }
        }
    }

    // MARK: Inline comments

    @ViewBuilder
    private var inlineComments: some View {
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

    /// Focus · location · duration · record — one context line for every card,
    /// so nothing migrates between lines card-to-card. A multi-game session
    /// trails with its record (the only thing its list of box scores can't say
    /// for itself); a single match doesn't need one, since its scorecard is the
    /// record. The duration is prefixed with a clock glyph so it can't be
    /// misread as a relative timestamp (e.g. "Austin, TX · 1m" reading like
    /// "1 minute ago" under the post's "2d ago" header timestamp).
    private var metaSubtitleText: Text? {
        var line: Text?
        func append(_ next: Text) {
            line = line.map { $0 + Text(" · ") + next } ?? next
        }

        for part in metaContextParts { append(Text(part)) }
        append(Text(Image(systemName: "clock")) + Text(" " + session.postCompactDuration))
        if isMultiActivity {
            let record = SessionRecord(activities: displayActivities)
            if record.hasMatches {
                append(Text(record.text).fontWeight(.bold).foregroundColor(record.color))
            }
        }
        return line
    }

    private var metaSubtitleAccessibilityLabel: String? {
        var parts = metaContextParts
        parts.append("\(session.postCompactDuration) played")
        if isMultiActivity {
            let record = SessionRecord(activities: displayActivities)
            if record.hasMatches { parts.append(record.accessibilityText) }
        }
        return parts.joined(separator: ", ")
    }

    private var metaContextParts: [String] {
        [session.postLocation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    /// In `.workout` a repost is credited games, so removing it drops the tag and
    /// the record entry. `unrepostSession` would be a no-op here anyway: it bails
    /// on `posted == false`, which is exactly what automatic credits are.
    private var removesWorkoutCredit: Bool { context == .workout && session.isRepost }

    private var destructiveTitle: String {
        if removesWorkoutCredit { return "Remove from Workout" }
        return session.isRepost ? "Remove Repost" : "Delete Session"
    }

    private var destructivePrompt: String {
        if removesWorkoutCredit { return "Remove from Workout?" }
        return session.isRepost ? "Remove this repost?" : "Delete this session?"
    }

    /// Whose side scores are framed from: the viewer in `.workout`, nobody (the
    /// author's own framing) in `.feed`.
    private var perspective: Profile? {
        context == .workout ? store.currentProfile : nil
    }

    /// A repost projected onto `perspective` drops any match they weren't tagged
    /// in, so the count can differ from the author's — derive layout from these.
    private var displayActivities: [SessionActivity] {
        guard let perspective else { return session.postActivities }
        return session.workoutActivities(for: perspective.id)
    }

    /// `SessionMatchList` / `MatchScorecard` accent this profile's side, and the
    /// projection reframes scores around the viewer, so the two must agree.
    private var displayAuthor: Profile { perspective ?? session.postAuthor }

    private var isMultiActivity: Bool { displayActivities.count >= 2 }

    private var isOwner: Bool { store.currentProfile?.id == session.userId }
    private var isTagged: Bool {
        guard let uid = store.currentProfile?.id else { return false }
        return session.isParticipant(uid)
    }

    private var showRepostAction: Bool {
        guard let me = store.currentProfile?.id else { return false }
        let isMutualFriend = store.mutualFriends.contains { $0.userId == session.userId }
        return !session.isRepost
            && session.userId != me
            && session.isParticipant(me)
            && isMutualFriend
    }

    private var alreadyReposted: Bool {
        store.mySessions.contains { $0.repostedFrom == session.id && $0.posted }
    }
}

/// Compact watch biometrics that trail the session title: a heart-rate chip
/// (avg, or avg–max range) and an active-calorie chip. Quiet + monochrome so
/// the lime score stays the hero. The wide `HealthMetricStrip` below is kept
/// for the standalone share card, where the extra room is welcome.
struct InlineHealthMetrics: View {
    let session: FeedSession

    var body: some View {
        HStack(spacing: 10) {
            if let avg = session.postAverageHeartRateBPM {
                chip("heart.fill", "\(avg)", unit: "avg", tint: .red)
            }
            if let cal = session.postActiveCaloriesKcal {
                chip("flame.fill", "\(cal)", unit: "cal", tint: .orange)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func chip(_ symbol: String, _ value: String, unit: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(value)
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let avg = session.postAverageHeartRateBPM { parts.append("Average heart rate \(avg) bpm") }
        if let cal = session.postActiveCaloriesKcal { parts.append("\(cal) active calories") }
        return parts.joined(separator: ", ")
    }
}

struct HealthMetricStrip: View {
    let session: FeedSession

    var body: some View {
        HStack(spacing: 0) {
            metric(value: session.postAverageHeartRateBPM, label: "AVG HR", suffix: "bpm")
            metric(value: session.postMaximumHeartRateBPM, label: "MAX HR", suffix: "bpm")
            metric(value: session.postActiveCaloriesKcal, label: "ACTIVE", suffix: "cal")
        }
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func metric(value: Int?, label: String, suffix: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { "\($0) \(suffix)" } ?? "-")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
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

/// A session's aggregate result. It lives outside `SessionMatchList` because
/// the card's context line renders the record while the list renders the games
/// the record summarizes.
struct SessionRecord {
    let matchCount: Int
    let wins: Int
    let losses: Int
    let ties: Int

    init(activities: [SessionActivity]) {
        matchCount = activities.count
        wins = activities.filter { $0.matchResult == .win }.count
        losses = activities.filter { $0.matchResult == .loss }.count
        ties = activities.filter { $0.matchResult == .tie }.count
    }

    /// Unscored matches still count, so a session of them reads "0–0" rather
    /// than dropping its record line entirely.
    var hasMatches: Bool { matchCount > 0 }
    var text: String { ties > 0 ? "\(wins)–\(losses)–\(ties)" : "\(wins)–\(losses)" }

    var color: Color {
        if wins > losses { return Theme.win }
        if losses > wins { return Theme.loss }
        return Theme.textPrimary
    }

    /// "0–2" is read aloud as a date otherwise.
    var accessibilityText: String {
        let base = "\(wins) won, \(losses) lost"
        return ties > 0 ? base + ", \(ties) tied" : base
    }
}

/// A multi-game session: every match uses the same head-to-head presentation as
/// a single-match post, with the aggregate record carried by the card's context
/// line above.
struct SessionMatchList: View {
    let activities: [SessionActivity]
    let author: Profile
    /// nil renders notes in full; a preview clamps them to keep the list of box
    /// scores reading as a list rather than a block of text.
    var noteLineLimit: Int?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                if index > 0 {
                    Divider().overlay(Theme.hairline)
                }
                MatchScorecard(activity: activity, author: author, noteLineLimit: noteLineLimit)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single scored game rendered as a two-row box score. Each team gets its own
/// row (facepile · names · score) and the poster's row communicates their result:
/// lime for a win, clay for a loss, and neutral for a tie.
struct MatchScorecard: View {
    let activity: SessionActivity
    let author: Profile
    /// nil shows the note in full (session detail); a preview clamps it, and the
    /// trailing "…" is what invites the tap through to the full text.
    var noteLineLimit: Int?

    private let avatarSize: CGFloat = 28

    var body: some View {
        MatchScorecardLayout(
            teamAvatars: teamAvatars,
            teamNames: teamNames,
            teamScore: activity.teamScore,
            teamAccent: posterAccent,
            opponentAvatars: opponentAvatars,
            opponentNames: opponentNames,
            opponentScore: activity.opponentScore,
            note: activity.note,
            noteLineLimit: noteLineLimit
        )
    }

    private var posterAccent: Color? {
        switch activity.matchResult {
        case .win: Theme.win
        case .loss: Theme.loss
        case .tie, .none: nil
        }
    }

    private var teamAvatars: [ProfileAvatar] {
        let ownerAvatar = ProfileAvatar(profile: author, size: avatarSize)
        guard activity.resolvedMatchFormat == .doubles else { return [ownerAvatar] }
        let partnerAvatar = activity.partners.first.map {
            $0.avatarView(size: avatarSize)
        } ?? ProfileAvatar(preview: "P", size: avatarSize)
        return [ownerAvatar, partnerAvatar]
    }

    private var opponentAvatars: [ProfileAvatar] {
        opponentSlots.enumerated().map { index, opponent in
            opponent.map { $0.avatarView(size: avatarSize) }
                ?? ProfileAvatar(
                    preview: activity.resolvedMatchFormat == .singles ? "O" : "O\(index + 1)",
                    size: avatarSize
                )
        }
    }

    private var teamNames: String {
        guard activity.resolvedMatchFormat == .doubles else { return authorShortName }
        let partnerName = activity.partners.first?.shortName ?? "Partner"
        return "\(authorShortName), \(partnerName)"
    }

    private var opponentNames: String {
        opponentSlots.enumerated().map { index, opponent in
            opponent?.shortName
                ?? (activity.resolvedMatchFormat == .singles ? "Opponent" : "Opponent \(index + 1)")
        }.joined(separator: ", ")
    }

    private var opponentSlots: [ActivityParticipant?] {
        let slotCount = activity.resolvedMatchFormat == .singles ? 1 : 2
        let selected = activity.opponents.prefix(slotCount).map(Optional.some)
        return selected + Array(repeating: nil, count: slotCount - selected.count)
    }

    private var authorShortName: String {
        author.displayName.split(separator: " ").first.map(String.init) ?? author.displayName
    }
}

/// Shared presentation for posted and in-progress matches, so the session
/// builder previews the exact scorecard that will appear in the feed.
struct MatchScorecardLayout: View {
    let teamAvatars: [ProfileAvatar]
    let teamNames: String
    let teamScore: Int?
    let teamAccent: Color?
    let opponentAvatars: [ProfileAvatar]
    let opponentNames: String
    let opponentScore: Int?
    let note: String?
    var noteLineLimit: Int?

    private let railHeight: CGFloat = 24
    /// Indents the note past the result rail + its spacing, so it hangs under
    /// the names rather than under the rail.
    private let noteInset: CGFloat = 13

    var body: some View {
        VStack(spacing: 4) {
            // The poster's own team is the accented row — their names + score
            // communicate their result (green for a win, clay for a loss,
            // neutral for a tie). Both rosters keep equal visual prominence.
            teamRow(
                avatars: teamAvatars,
                names: teamNames,
                score: teamScore,
                accent: teamAccent
            )
            teamRow(
                avatars: opponentAvatars,
                names: opponentNames,
                score: opponentScore,
                accent: nil
            )

            // Instantiated only when there is a note, so a noteless scorecard
            // gets no extra subview and no VStack spacing around it.
            if let note {
                ActivityNote(text: note, lineLimit: noteLineLimit)
                    .padding(.leading, noteInset)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func teamRow(avatars: [ProfileAvatar], names: String, score: Int?, accent: Color?) -> some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(accent ?? .clear)
                .frame(width: 3, height: railHeight)

            if !avatars.isEmpty {
                FacePile(avatars: avatars)
            }

            Text(names)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(score.map(String.init) ?? "-")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(accent ?? Theme.textPrimary)
        }
    }
}

struct FacePile: View {
    let avatars: [ProfileAvatar]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(avatars.indices, id: \.self) { index in
                avatars[index].overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
            }
        }
    }
}

extension ActivityParticipant {
    func avatarView(size: CGFloat) -> ProfileAvatar {
        profile != nil
            ? ProfileAvatar(participant: profile, size: size)
            : ProfileAvatar(guest: Self.initials(from: displayName), size: size)
    }

    var shortName: String { displayName.split(separator: " ").first.map(String.init) ?? displayName }

    static func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// The free-text note a player attached to one game or drill. One presentation
/// for both activity kinds: a quiet line under the row, clamped on a preview
/// card and rendered in full on the session detail screen.
struct ActivityNote: View {
    let text: String
    var lineLimit: Int?

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small "N week streak" pill for a post that extended the poster's weekly
/// play streak. Uses the same `circle.hexagongrid.fill` streak mark as the
/// profile header for consistency. Milestone weeks (multiples of 4) get a filled
/// accent treatment; ordinary weeks get a subtle tinted chip. Frozen at post
/// time (see `sessions.streak_week`).
struct StreakBadge: View {
    let weeks: Int

    private var isMilestone: Bool { weeks % 4 == 0 }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.hexagongrid.fill")
            Text("\(weeks) week streak")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(isMilestone ? Theme.background : Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(isMilestone ? Theme.accent : Theme.accent.opacity(0.15))
        )
        .accessibilityLabel("\(weeks) week play streak")
    }
}
