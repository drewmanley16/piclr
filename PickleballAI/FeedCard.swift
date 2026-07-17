import SwiftUI

struct FeedCard: View {
    @EnvironmentObject private var store: AppStore
    var session: FeedSession
    @State private var showComments = false
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var confirmBlock = false
    @State private var confirmRemoveTag = false
    @State private var reportTarget: ReportTarget?
    @State private var shareItem: ShareImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.isRepost {
                Label("Reposted", systemImage: "arrow.2.squarepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            headerRow

            titleBlock

            activityList

            photoSection

            if let takeaway = session.takeaway, !takeaway.isEmpty {
                Text(takeaway)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
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

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            ProfileLink(userId: session.author.id, placeholder: session.author) {
                HStack(spacing: 12) {
                    ProfileAvatar(profile: session.author, size: 44, unlinked: true)
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
    }

    // MARK: Title

    // Title + a quiet context line (focus / location — never duration; that
    // lives in the stat strip, so it can't be mistaken for a timestamp).
    private var titleBlock: some View {
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
    }

    // MARK: Activities

    // A single match leads with its score; multi-activity sessions lead with a
    // compact record and keep the same head-to-head language for every match.
    @ViewBuilder
    private var activityList: some View {
        if isMultiActivity {
            SessionMatchList(
                activities: session.sortedActivities,
                durationText: session.compactDuration,
                author: session.author
            )
        } else if let solo = session.sortedActivities.first {
            if solo.isMatch {
                MatchHeadToHead(activity: solo, author: session.author)
            } else {
                DrillRow(activity: solo)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: Photo

    @ViewBuilder
    private var photoSection: some View {
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

            if canRepost {
                Button {
                    Haptics.impact()
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
    /// there is no aggregate multi-activity summary.
    private var metaSubtitle: String? {
        var parts = [session.focus, session.location]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !isMultiActivity { parts.append(session.compactDuration) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var isMultiActivity: Bool { session.sortedActivities.count >= 2 }

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
                            MatchHeadToHead(activity: activity, author: author)
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

/// The W/L/T result pip shared by list rows and single-match heroes.
struct ResultBadge: View {
    let result: MatchResult
    var diameter: CGFloat = 22

    var body: some View {
        Text(result.badge)
            .font(.system(size: diameter * 0.52, weight: .heavy))
            .foregroundStyle(result == .tie ? Theme.textPrimary : Theme.background)
            .frame(width: diameter, height: diameter)
            .background(result.color, in: Circle())
    }
}

/// The shared feed presentation for a scored match: the poster's team and the
/// opponents face off across a centered score and result badge.
struct MatchHeadToHead: View {
    let activity: SessionActivity
    let author: Profile

    private let avatarSize: CGFloat = 34
    private let scoreSideWidth: CGFloat = 46

    var body: some View {
        Group {
            if activity.opponents.isEmpty {
                scoreColumn
            } else {
                matchup
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var matchup: some View {
        HStack(alignment: .center, spacing: 10) {
            side(avatars: teamAvatars, names: teamNames, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            scoreColumn
                .fixedSize()
            side(avatars: opponentAvatars, names: opponentNames, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scoreColumn: some View {
        VStack(spacing: 6) {
            if activity.scoreLine != nil {
                scoreView
            }
            if let result = activity.matchResult {
                ResultBadge(result: result, diameter: 24)
            }
        }
    }

    /// Equal-width score fields keep the dash on the same center axis as W/L.
    private var scoreView: some View {
        let color = activity.matchResult?.color ?? Theme.textPrimary
        let parts = (activity.scoreLine ?? "").components(separatedBy: "–")
        return HStack(spacing: 5) {
            if parts.count == 2 {
                Text(parts[0])
                    .lineLimit(1)
                    .frame(width: scoreSideWidth, alignment: .trailing)
                Capsule().fill(color).frame(width: 12, height: 4)
                Text(parts[1])
                    .lineLimit(1)
                    .frame(width: scoreSideWidth, alignment: .leading)
            } else {
                Text(activity.scoreLine ?? "")
            }
        }
        .font(.system(size: 30, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(color)
    }

    private func side(avatars: [ProfileAvatar], names: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            FacePile(avatars: avatars)
            Text(names)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
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
