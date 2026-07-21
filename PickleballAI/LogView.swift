import SwiftUI

// MARK: - Workout Tab

struct WorkoutView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLiveSession = false
    @State private var quickEditor: ActivityEditorRoute?
    @State private var showInviteComposer = false

    private var thisWeek: [FeedSession] {
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return store.mySessions.filter { $0.workoutDate >= weekStart }
    }

    var body: some View {
        ProfileNavigationStack {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.activeDraft != nil {
                    liveBanner
                } else {
                    weekStrip
                    startLiveButton
                    quickLog
                    planGameButton
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let upcoming = store.activeInvites.filter {
                        !$0.isCancelled && $0.scheduledAtDate > context.date
                    }
                    if !upcoming.isEmpty {
                        activeInvitesSection(upcoming)
                    }
                }
                recentSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable {
            if let uid = store.currentProfile?.id {
                await store.loadMySessions(userId: uid)
                await store.loadActiveInvites(userId: uid)
            }
        }
        .safeAreaInset(edge: .top) {
            AppHeader(title: "Play") {
                HeaderCircleButton(systemImage: "plus", accessibilityTitle: "Start session") {
                    startLive()
                }
            }
            .background(Theme.background)
        }
        .fullScreenCover(isPresented: $showLiveSession) {
            ActiveSessionView(isLive: true)
        }
        .sheet(isPresented: $showInviteComposer) {
            InviteComposerSheet()
        }
        .sheet(item: $quickEditor) { route in
            switch route {
            case .newMatch:
                ActivityEditorView(activity: DraftActivity(kind: .match)) { activity in
                    Task { await store.quickLog(activity) }
                }
            case .newPractice:
                ActivityEditorView(activity: DraftActivity(kind: .practice)) { activity in
                    Task { await store.quickLog(activity) }
                }
            case .edit:
                EmptyView()
            }
        }
    }

    private func startLive() {
        store.startLiveSession()
        showLiveSession = true
    }

    // MARK: Live session banner

    private var liveBanner: some View {
        Button { showLiveSession = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(Theme.accent).frame(width: 10, height: 10)
                    Text("Session in progress")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let start = store.activeDraft?.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { _ in
                            Text(elapsed(since: start))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Text(liveSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    Text("Tap to resume")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private var liveSubtitle: String {
        let count = store.activeDraft?.activities.count ?? 0
        if count == 0 { return "No games logged yet — tap to add matches and practice." }
        return count == 1 ? "1 activity logged" : "\(count) activities logged"
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: This week

    private var weekStrip: some View {
        let hours = Double(thisWeek.reduce(0) { $0 + $1.workoutDurationMinutes }) / 60
        let streak = SessionStats(
            sessions: store.mySessions,
            playerID: store.currentProfile?.id
        ).weeklyStreakLabel
        return HStack(spacing: 0) {
            weekStat("\(thisWeek.count)", "sessions")
            Divider().frame(height: 30).overlay(Theme.hairline)
            weekStat(String(format: "%.1f", hours), "hours")
            Divider().frame(height: 30).overlay(Theme.hairline)
            weekStat(streak, "streak")
        }
        .cardStyle()
    }

    private func weekStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Quick log

    private var quickLog: some View {
        HStack(spacing: 12) {
            QuickLogButton(title: "Log a Match", systemImage: "flag.checkered", filled: true) {
                quickEditor = .newMatch
            }
            QuickLogButton(title: "Log Practice", systemImage: "figure.cooldown", filled: false) {
                quickEditor = .newPractice
            }
        }
    }

    private var startLiveButton: some View {
        Button { startLive() } label: {
            HStack(spacing: 16) {
                Image(systemName: "play.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 56, height: 56)
                    .background(Theme.accent, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Start a live session")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Log matches and practice as you play")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var planGameButton: some View {
        Button { showInviteComposer = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.badge.plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)

                Text("Plan a game")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose players, a court, and a time")
    }

    // MARK: Active invites

    private func activeInvitesSection(_ invites: [SessionInvite]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upcoming invites")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(invites) { invite in
                InviteCard(invite: invite)
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if store.mySessions.isEmpty {
                Text("No sessions yet — log a match or start a session above.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.mySessions.prefix(10)) { session in
                    SessionSummaryRow(session: session)
                }
            }
        }
    }
}

struct QuickLogButton: View {
    let title: String
    let systemImage: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(filled ? Theme.background : Theme.accent)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(filled ? Theme.background : Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: 104, alignment: .topLeading)
            .background(filled ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SessionSummaryRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSession) private var openSession
    var session: FeedSession
    @State private var showEditor = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 46, height: 46)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.workoutDisplayTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openSession(session.id, placeholder: session) }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if workoutMatchCount > 0 {
                    let r = matchResults
                    Text("\(r.wins)–\(r.losses)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(r.wins >= r.losses ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            r.wins >= r.losses ? Theme.accentSoft : Theme.surfaceElevated,
                            in: Capsule()
                        )
                }
                Text(session.workoutDate.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            Menu {
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
                    Label(session.isRepost ? "Remove from Workout" : "Delete Session", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 40)
            }
            .accessibilityLabel("Session actions")
        }
        .cardStyle()
        .fullScreenCover(isPresented: $showEditor) {
            ActiveSessionView(existingSession: session)
        }
        .confirmationDialog(session.isRepost ? "Remove from Workout?" : "Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(session.isRepost ? "Remove from Workout" : "Delete Session", role: .destructive) {
                Task {
                    if session.isRepost {
                        _ = await store.removeWorkoutCredit(session)
                    } else {
                        _ = await store.deleteSession(session)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.isRepost
                 ? "This removes the credited games from your Workout history and record, and removes your tag from the original post."
                 : "Matches, practices, comments, and likes on this post will be removed.")
        }
    }

    private var icon: String {
        if workoutMatchCount > 0 && workoutPracticeCount == 0 { return "flag.checkered" }
        if workoutPracticeCount > 0 && workoutMatchCount == 0 { return "figure.cooldown" }
        return "figure.pickleball"
    }

    private var workoutActivities: [SessionActivity] {
        guard let playerID = store.currentProfile?.id else { return [] }
        return session.workoutActivities(for: playerID)
    }

    private var workoutMatchCount: Int { workoutActivities.filter(\.isMatch).count }
    private var workoutPracticeCount: Int { workoutActivities.count - workoutMatchCount }

    private var matchResults: (wins: Int, losses: Int) {
        var wins = 0, losses = 0
        for activity in workoutActivities {
            switch activity.matchResult {
            case .win:  wins += 1
            case .loss: losses += 1
            default:    break   // tie / not a match
            }
        }
        return (wins, losses)
    }

    private var subtitle: String {
        var parts: [String] = []
        if workoutMatchCount > 0 { parts.append("\(workoutMatchCount) match\(workoutMatchCount == 1 ? "" : "es")") }
        if workoutPracticeCount > 0 { parts.append("\(workoutPracticeCount) practice") }
        if session.workoutDurationMinutes > 1 { parts.append("\(session.workoutDurationMinutes) min") }
        if parts.isEmpty { parts.append("Session") }
        return parts.joined(separator: " · ")
    }
}
