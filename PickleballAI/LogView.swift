import SwiftUI

// MARK: - Workout Tab

struct WorkoutView: View {
    @EnvironmentObject private var store: AppStore
    /// Bumped by RootView when the Play tab is re-tapped; pops the stack to root.
    var reselectSignal: Int = 0
    @State private var showLiveSession = false
    @State private var quickEditor: ActivityEditorRoute?
    @State private var showInviteComposer = false
    @State private var showHealthMetricsConsent = false
    @AppStorage(HealthMetricsSharing.defaultsKey) private var shareHealthMetrics = false
    @State private var quickLogDuration = AppStore.defaultQuickLogDurationMinutes

    var body: some View {
        ProfileNavigationStack(reselectSignal: reselectSignal) {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.activeDraft != nil {
                    liveBanner
                } else {
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
        .appErrorAlert("Couldn't log that", store: store)
        .refreshable {
            if let uid = store.currentProfile?.id {
                await store.loadMySessions(userId: uid)
                await store.loadActiveInvites(userId: uid)
            }
        }
        .safeAreaInset(edge: .top) {
            AppHeader(title: "Play") {
                HeaderCircleMenu(systemImage: "plus", accessibilityTitle: "Log or start a session") {
                    Button {
                        startLive()
                    } label: {
                        Label("Start live session", systemImage: "play.fill")
                    }
                    Button {
                        quickEditor = .newMatch
                    } label: {
                        Label("Log a match", systemImage: "flag.checkered")
                    }
                    Button {
                        quickEditor = .newPractice
                    } label: {
                        Label("Log practice", systemImage: "figure.cooldown")
                    }
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
                ActivityEditorView(
                    activity: DraftActivity(kind: .match),
                    duration: $quickLogDuration
                ) { await quickLog($0) }
            case .newPractice:
                ActivityEditorView(
                    activity: DraftActivity(kind: .practice),
                    duration: $quickLogDuration
                ) { await quickLog($0) }
            case .edit:
                EmptyView()
            }
        }
        .alert("Share Apple Watch metrics?", isPresented: $showHealthMetricsConsent) {
            Button("Share & Start") {
                shareHealthMetrics = true
                beginLiveSession(trackOnWatch: true)
            }
            Button("Start Without Metrics") {
                beginLiveSession(trackOnWatch: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Average heart rate, maximum heart rate, and active calories will appear publicly on sessions you post.")
        }
    }

    /// Posts a one-tap log. Reports the outcome so the editor stays open on
    /// failure — this posts straight to the backend, with no draft to fall back
    /// on, so a silent dismissal would just lose what the user entered.
    private func quickLog(_ activity: DraftActivity) async -> Bool {
        let posted = await store.quickLog(activity, durationMinutes: quickLogDuration)
        if posted { Haptics.success() }
        return posted
    }

    private func startLive() {
        if shareHealthMetrics {
            beginLiveSession(trackOnWatch: true)
        } else {
            showHealthMetricsConsent = true
        }
    }

    private func beginLiveSession(trackOnWatch: Bool) {
        store.startLiveSession(trackOnWatch: trackOnWatch)
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
        if count == 0 { return "No games logged yet. Tap to add matches and practice." }
        return count == 1 ? "1 activity logged" : "\(count) activities logged"
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
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
            if store.isInitialMySessionsLoading && store.mySessions.isEmpty {
                // Only while empty, so a pull-to-refresh doesn't replace the
                // sessions already on screen with ghosts.
                ForEach(0..<2, id: \.self) { _ in FeedCardSkeleton() }
            } else if store.mySessions.isEmpty {
                Text("No sessions yet. Log a match or start a session above.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.mySessions.prefix(10)) { session in
                    // Recent is this user's own workout history, so reposts must
                    // show their result rather than the original author's.
                    FeedCard(session: session, context: .workout)
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
