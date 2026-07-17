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

            // Hevy-style summary strip: the session's substance in one scannable row.
            SessionSummaryStrip(session: session)

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

    // Activities as a clean itemized list (Hevy's exercise rows), score inline.
    @ViewBuilder
    private var activityList: some View {
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
            let record = ties > 0 ? "\(wins)–\(losses)–\(ties)" : "\(wins)–\(losses)"
            result.append(Stat(value: record, label: ties > 0 ? "W–L–T" : "Record", emphasized: wins > 0 && losses == 0 && ties == 0))
        } else if session.practiceCount > 0 {
            let drills = session.practiceCount
            result.append(Stat(value: "\(drills)", label: drills == 1 ? "Drill" : "Drills"))
        }
        return result
    }

    private var wins: Int { session.sortedActivities.filter { $0.matchResult == .win }.count }
    private var losses: Int { session.sortedActivities.filter { $0.matchResult == .loss }.count }
    private var ties: Int { session.sortedActivities.filter { $0.matchResult == .tie }.count }

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
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))

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
                        .foregroundStyle(activity.matchResult?.color ?? Theme.textPrimary)
                    if let result = activity.matchResult {
                        Text(result.badge)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(result == .tie ? Theme.textPrimary : Theme.background)
                            .frame(width: 22, height: 22)
                            .background(result.color, in: Circle())
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
