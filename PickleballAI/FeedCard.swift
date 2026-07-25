import SwiftUI

struct FeedCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSession) private var openSession
    var session: FeedSession
    /// False when this card is already the content of a session detail screen,
    /// so tapping it doesn't push another copy of itself onto the stack.
    var openable: Bool = true
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
            if session.isRepost {
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
        .confirmationDialog(session.isRepost ? "Remove this repost?" : "Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(session.isRepost ? "Remove Repost" : "Delete Session", role: .destructive) {
                Task {
                    if session.isRepost {
                        _ = await store.unrepostSession(session)
                    } else {
                        _ = await store.deleteSession(session)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if session.isRepost {
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
                        Text(session.postAuthor.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
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
                        Label(session.isRepost ? "Remove Repost" : "Delete Session", systemImage: "trash")
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
                    .font(.caption)
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
                activities: session.postActivities,
                durationText: session.postCompactDuration,
                author: session.postAuthor
            )
        } else if let solo = session.postActivities.first {
            if solo.isMatch {
                MatchScorecard(activity: solo, author: session.postAuthor)
                    .padding(.vertical, 4)
            } else {
                DrillRow(activity: solo)
                    .padding(.vertical, 4)
            }
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

    /// Focus · location · duration — duration folds into the quiet context when
    /// there is no aggregate multi-activity summary. The duration is prefixed
    /// with a clock glyph so it can't be misread as a relative timestamp
    /// (e.g. "Austin, TX · 1m" reading like "1 minute ago" under the post's
    /// "2d ago" header timestamp).
    private var metaSubtitleText: Text? {
        let parts = [session.postFocus, session.postLocation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let leading = parts.isEmpty ? nil : Text(parts.joined(separator: " · "))
        guard !isMultiActivity else { return leading }

        let durationText = Text(Image(systemName: "clock")) + Text(" " + session.postCompactDuration)
        if let leading {
            return leading + Text(" · ") + durationText
        }
        return durationText
    }

    private var metaSubtitleAccessibilityLabel: String? {
        let parts = [session.postFocus, session.postLocation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !isMultiActivity else {
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        let playedLabel = "\(session.postCompactDuration) played"
        return (parts + [playedLabel]).joined(separator: ", ")
    }

    private var isMultiActivity: Bool { session.postActivities.count >= 2 }

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
            Text(value.map { "\($0) \(suffix)" } ?? "—")
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

/// A multi-game session: one quiet summary line over a list where every match
/// uses the same head-to-head presentation as a single-match post.
struct SessionMatchList: View {
    let activities: [SessionActivity]
    let durationText: String
    let author: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryLine
            VStack(spacing: 0) {
                ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                    if index > 0 {
                        Divider().overlay(Theme.hairline)
                    }
                    Group {
                        if activity.isMatch {
                            MatchScorecard(activity: activity, author: author)
                        } else {
                            DrillRow(activity: activity)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryLine: some View {
        Group {
            if matches.isEmpty {
                Text(countsLine).foregroundColor(Theme.textSecondary)
            } else {
                Text(record).fontWeight(.bold).foregroundColor(recordColor)
                    + Text(" · \(countsLine)").foregroundColor(Theme.textSecondary)
            }
        }
        .font(.subheadline)
        .monospacedDigit()
    }

    private var matches: [SessionActivity] { activities.filter(\.isMatch) }
    private var wins: Int { matches.filter { $0.matchResult == .win }.count }
    private var losses: Int { matches.filter { $0.matchResult == .loss }.count }
    private var ties: Int { matches.filter { $0.matchResult == .tie }.count }
    private var record: String { ties > 0 ? "\(wins)–\(losses)–\(ties)" : "\(wins)–\(losses)" }

    private var recordColor: Color {
        if wins > losses { return Theme.win }
        if losses > wins { return Theme.loss }
        return Theme.textPrimary
    }

    private var countsLine: String {
        var parts: [String] = []
        let matchCount = matches.count
        if matchCount > 0 { parts.append("\(matchCount) game\(matchCount == 1 ? "" : "s")") }
        let drillCount = activities.count - matchCount
        if drillCount > 0 { parts.append("\(drillCount) drill\(drillCount == 1 ? "" : "s")") }
        parts.append(durationText)
        return parts.joined(separator: " · ")
    }
}

/// A single scored game rendered as a two-row box score. Each team gets its own
/// row (facepile · names · score) and the poster's row communicates their result:
/// lime for a win, clay for a loss, and neutral for a tie.
struct MatchScorecard: View {
    let activity: SessionActivity
    let author: Profile

    private let avatarSize: CGFloat = 28
    private let railHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 4) {
            // The poster's own team is the accented row — their names + score
            // communicate their result (green for a win, clay for a loss,
            // neutral for a tie) — with the opponents always rendered muted.
            teamRow(
                avatars: teamAvatars,
                names: teamNames,
                score: activity.teamScore,
                accent: posterAccent
            )
            teamRow(
                avatars: opponentAvatars,
                names: opponentNames.isEmpty ? "Opponent" : opponentNames,
                score: activity.opponentScore,
                accent: nil
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var posterAccent: Color? {
        switch activity.matchResult {
        case .win: Theme.win
        case .loss: Theme.loss
        case .tie, .none: nil
        }
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
                .font(.subheadline.weight(accent != nil ? .semibold : .regular))
                .foregroundStyle(accent != nil ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(score.map(String.init) ?? "—")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(accent ?? Theme.textSecondary)
        }
    }

    private var teamAvatars: [ProfileAvatar] {
        [ProfileAvatar(profile: author, size: avatarSize)]
            + activity.partners.map { $0.avatarView(size: avatarSize) }
    }
    private var opponentAvatars: [ProfileAvatar] {
        activity.opponents.map { $0.avatarView(size: avatarSize) }
    }
    private var teamNames: String {
        ([authorShortName] + activity.partners.map(\.shortName)).joined(separator: ", ")
    }
    private var opponentNames: String {
        activity.opponents.map(\.shortName).joined(separator: ", ")
    }
    private var authorShortName: String {
        author.displayName.split(separator: " ").first.map(String.init) ?? author.displayName
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

/// A drill/practice entry has no score or opponent, so it stays a quiet row.
struct DrillRow: View {
    let activity: SessionActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.pickleball")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
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
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        let bits = [activity.reps, activity.notes].compactMap { $0 }.filter { !$0.isEmpty }
        return bits.isEmpty ? nil : bits.joined(separator: " — ")
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
