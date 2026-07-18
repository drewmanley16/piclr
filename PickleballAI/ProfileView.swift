import SwiftUI
import Charts

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    @State private var showFindFriends = false
    @State private var showNotifications = false
    @State private var activeSheet: ProfileSheet?
    @State private var metric: ActivityMetric = .duration
    @AppStorage("dismissedProfileCompletion") private var dismissedCompletion = false

    private var profile: Profile? { store.currentProfile }

    private var shareText: String {
        guard let profile else { return "Find me on pickleball.ai" }
        return "Add @\(profile.username) on pickleball.ai"
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileRow
                    streakCard
                    if !store.incomingFollowRequests.isEmpty { followRequestsBanner }
                    if completion < 1 && !dismissedCompletion { completionBanner }
                    recordCard
                    rivalsCard
                    activityCard
                    WorkoutCalendarCard(sessions: store.mySessions)
                    dashboard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .top) {
                AppHeader(title: profile?.username ?? "Profile") {
                    HeaderPill {
                        ShareLink(item: shareText) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .accessibilityLabel("Share profile")
                        HeaderIconButton(systemImage: "person.crop.circle.badge.plus", accessibilityTitle: "Find friends") {
                            showFindFriends = true
                        }
                        HeaderIconButton(systemImage: "gearshape", accessibilityTitle: "Settings") {
                            showSettings = true
                        }
                    }
                }
                .background(Theme.background)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .sheet(isPresented: $showFindFriends) {
                FindFriendsSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showNotifications) { NotificationsView() }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .stats: StatsSheet()
                case .gear: GearSheet()
                case .measures: MeasuresSheet()
                case .rivals: RivalsSheet()
                case .leaderboard: LeaderboardSheet()
                }
            }
        }
    }

    // MARK: Profile row

    private var profileRow: some View {
        HStack(spacing: 20) {
            ProfileAvatar(profile: profile, size: 76, unlinked: true)

            ProfileStat(label: "Sessions", value: "\(store.mySessions.count)")

            NavigationLink {
                FollowListView(kind: .followers)
            } label: {
                ProfileStat(label: "Followers", value: "\(store.followerCount)")
            }
            .buttonStyle(.plain)

            NavigationLink {
                FollowListView(kind: .following)
            } label: {
                ProfileStat(label: "Following", value: "\(store.followingCount)")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Follow requests banner

    private var followRequestsBanner: some View {
        Button {
            showNotifications = true
        } label: {
            HStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Theme.accentSoft, in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(followRequestsTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Tap to review and accept")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private var followRequestsTitle: String {
        let count = store.incomingFollowRequests.count
        return count == 1 ? "1 follow request" : "\(count) follow requests"
    }

    // MARK: Completion banner

    /// Only the fields that actually shape the product (court, side, rating,
    /// photo) count toward "finished" — measures are optional extras and were
    /// nagging users forever over their shoe size.
    private var completion: Double {
        guard let p = profile else { return 1 }
        let checks = [
            p.homeCourt,
            p.preferredSide,
            p.rating.map { "\($0)" },
            p.avatarURL
        ]
        let filled = checks.filter { ($0 ?? "").isEmpty == false }.count
        return Double(filled) / Double(checks.count)
    }

    private var completionBanner: some View {
        HStack(spacing: 12) {
            Button {
                showSettings = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your profile is \(Int(completion * 100))% finished")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Add your court, rating, side, and photo")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(Theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.snappy) { dismissedCompletion = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .cardStyle()
    }

    // MARK: Streak

    /// Consistency streak hero. Celebratory when active; a gentle nudge at zero
    /// (no guilt) so lapsed/new users see how to start one.
    private var streakCard: some View {
        let s = stats
        let weeks = s.weeklyStreak
        let playedThisWeek = thisWeekCount > 0
        return HStack(spacing: 16) {
            Image(systemName: "flame.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(weeks > 0 ? Theme.accent : Theme.textTertiary)
                .frame(width: 52, height: 52)
                .background(weeks > 0 ? Theme.accentSoft : Theme.surfaceElevated, in: Circle())

            if weeks > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    (Text("\(weeks)").font(.title2.weight(.heavy)).foregroundStyle(Theme.accent)
                        + Text(" week streak").font(.headline).foregroundStyle(Theme.textPrimary))
                    Text(playedThisWeek
                         ? "Locked in this week · longest \(s.longestWeeklyStreak) wk"
                         : "Play this week to keep it going")
                        .font(.caption)
                        .foregroundStyle(playedThisWeek ? Theme.textSecondary : Theme.loss)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a streak").font(.headline).foregroundStyle(Theme.textPrimary)
                    Text("Log a session this week to begin.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
        .cardStyle()
    }

    private var thisWeekCount: Int {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return store.mySessions.filter { $0.date >= weekStart }.count
    }

    // MARK: Record

    private var stats: SessionStats { SessionStats(sessions: store.mySessions) }

    @ViewBuilder
    private var recordCard: some View {
        let s = stats
        if s.matches > 0 {
            Button { activeSheet = .stats } label: {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Record").font(.headline).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("Details")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }

                    HStack(spacing: 0) {
                        recordStat("\(s.wins)–\(s.losses)", "Win–Loss", accent: true)
                        Divider().frame(height: 30).overlay(Theme.hairline)
                        recordStat("\(s.winRate)%", "Win rate")
                        Divider().frame(height: 30).overlay(Theme.hairline)
                        recordStat(s.streakLabel, "Win streak")
                    }

                    if !s.partners.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("BEST PARTNERS")
                                .font(.caption2.weight(.semibold))
                                .tracking(1.2)
                                .foregroundStyle(Theme.textSecondary)
                            ForEach(s.partners.prefix(3)) { partner in
                                HStack(spacing: 10) {
                                    // Inside the tappable Record card, so opt out
                                    // of avatar navigation to avoid a nested tap.
                                    ProfileAvatar(person: partner.person, size: 32, unlinked: true)
                                    Text(partner.person.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(partner.recordLine)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(partner.wins >= partner.losses ? Theme.accent : Theme.textPrimary)
                                }
                            }
                        }
                    }
                }
                .cardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Rivals

    /// A real rivalry needs at least two meetings — one game is not a rivalry.
    private var topRivals: [Rivalry] {
        stats.rivalries.filter { $0.games >= 2 }
    }

    @ViewBuilder
    private var rivalsCard: some View {
        if let top = topRivals.first {
            Button { activeSheet = .rivals } label: {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Rivals", systemImage: "flame.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if topRivals.count > 1 {
                            Text("See all")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                    RivalRow(rivalry: top, emphasized: true, unlinked: true)
                }
                .cardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    private func recordStat(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(accent ? Theme.accent : Theme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Activity chart

    private var buckets: [ActivityBucket] {
        ActivityBucket.lastWeekDaily(sessions: store.mySessions)
    }

    private var thisWeekValue: (String, String) {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let mine = store.mySessions.filter { $0.date >= weekStart }
        switch metric {
        case .duration:
            let hrs = Double(mine.reduce(0) { $0 + $1.durationMinutes }) / 60
            return (String(format: "%.1f", hrs), "hours this week")
        case .sessions:
            return ("\(mine.count)", "sessions this week")
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(thisWeekValue.0).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                + Text("  \(thisWeekValue.1)").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Last 7 days")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            Chart(buckets) { b in
                BarMark(
                    x: .value("Day", b.day, unit: .day),
                    y: .value(metric.rawValue, metric == .duration ? b.hours : Double(b.sessions))
                )
                .foregroundStyle(Theme.accent)
                .cornerRadius(4)
            }
            .frame(height: 170)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(Theme.textTertiary)
                }
            }

            HStack(spacing: 8) {
                ForEach(ActivityMetric.allCases, id: \.self) { m in
                    Button { metric = m } label: {
                        Text(m.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(metric == m ? Theme.background : Theme.textSecondary)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(metric == m ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .cardStyle()
    }

    // MARK: Dashboard

    private var dashboard: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            DashboardTile(icon: "trophy.fill", label: "Leaderboard") { activeSheet = .leaderboard }
            DashboardTile(icon: "bag.fill", label: "Gear") { activeSheet = .gear }
            DashboardTile(icon: "figure.stand", label: "Measures") { activeSheet = .measures }
        }
    }

}

// MARK: - Activity types

enum ActivityMetric: String, CaseIterable, Hashable {
    case duration = "Duration"
    case sessions = "Sessions"
}

struct ActivityBucket: Identifiable {
    let id = UUID()
    let day: Date
    var hours: Double
    var sessions: Int

    /// One bucket per day for the last 7 days (oldest → today).
    static func lastWeekDaily(sessions: [FeedSession]) -> [ActivityBucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var map: [Date: ActivityBucket] = [:]
        for offset in 0..<7 {
            if let day = cal.date(byAdding: .day, value: -offset, to: today) {
                map[day] = ActivityBucket(day: day, hours: 0, sessions: 0)
            }
        }
        let weekAgo = cal.date(byAdding: .day, value: -6, to: today) ?? today
        for s in sessions where s.date >= weekAgo {
            let day = cal.startOfDay(for: s.date)
            guard map[day] != nil else { continue }
            map[day]!.hours += Double(s.durationMinutes) / 60
            map[day]!.sessions += 1
        }
        return map.values.sorted { $0.day < $1.day }
    }
}

// MARK: - Small components

struct ProfileStat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardTile: View {
    var icon: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

enum ProfileSheet: String, Identifiable {
    case stats, gear, measures, rivals, leaderboard
    var id: String { rawValue }
}
