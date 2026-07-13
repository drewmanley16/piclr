import SwiftUI
import Charts

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    @State private var activeSheet: ProfileSheet?
    @State private var metric: ActivityMetric = .duration
    @State private var range: ActivityRange = .threeMonths

    private var profile: Profile? { store.currentProfile }

    private var shareText: String {
        guard let profile else { return "Find me on pickleball.ai" }
        return "Add @\(profile.username) on pickleball.ai"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileRow
                    if completion < 1 { completionBanner }
                    activityCard
                    dashboard
                    if !store.incomingFollowRequests.isEmpty {
                        followRequestsSection
                    }
                    sessionsSection
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
                        HeaderIconButton(systemImage: "gearshape", accessibilityTitle: "Settings") {
                            showSettings = true
                        }
                    }
                }
                .background(Theme.background)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .stats: StatsSheet()
                case .gear: GearSheet()
                case .measures: MeasuresSheet()
                }
            }
        }
    }

    // MARK: Profile row

    private var profileRow: some View {
        HStack(spacing: 20) {
            ProfileAvatar(profile: profile, size: 76)

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

    // MARK: Completion banner

    private var completion: Double {
        guard let p = profile else { return 1 }
        let checks = [
            p.homeCourt,
            p.preferredSide,
            p.rating.map { "\($0)" },
            p.heightInches.map { "\($0)" },
            p.weightPounds.map { "\($0)" },
            p.shoeSize.map { "\($0)" }
        ]
        let filled = checks.filter { ($0 ?? "").isEmpty == false }.count
        return Double(filled) / Double(checks.count)
    }

    private var measuresIncomplete: Bool {
        profile?.heightInches == nil || profile?.weightPounds == nil || profile?.shoeSize == nil
    }

    private var completionBanner: some View {
        Button {
            if measuresIncomplete {
                activeSheet = .measures
            } else {
                showSettings = true
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your profile is \(Int(completion * 100))% finished")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Add player details and measures")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(Theme.accent)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // MARK: Activity chart

    private var buckets: [ActivityBucket] {
        ActivityBucket.weekly(sessions: store.mySessions, range: range)
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
                Menu {
                    ForEach(ActivityRange.allCases) { r in
                        Button(r.rawValue) { range = r }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(range.rawValue).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }

            Chart(buckets) { b in
                BarMark(
                    x: .value("Week", b.weekStart, unit: .weekOfYear),
                    y: .value(metric.rawValue, metric == .duration ? b.hours : Double(b.sessions))
                )
                .foregroundStyle(Theme.accent)
            }
            .frame(height: 170)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(Theme.textTertiary)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Dashboard").font(.headline).foregroundStyle(Theme.textPrimary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                DashboardTile(icon: "chart.line.uptrend.xyaxis", label: "Statistics") { activeSheet = .stats }
                DashboardTile(icon: "bag.fill", label: "Gear") { activeSheet = .gear }
                DashboardTile(icon: "figure.stand", label: "Measures") { activeSheet = .measures }
            }
        }
    }

    // MARK: Friend requests

    private var followRequestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow Requests").font(.headline).foregroundStyle(Theme.textPrimary)
            ForEach(store.incomingFollowRequests) { request in
                FollowRequestRow(request: request)
            }
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions").font(.headline).foregroundStyle(Theme.textPrimary)
            if store.mySessions.isEmpty {
                Text("No sessions yet. Log one from the Workout tab.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(store.mySessions) { session in
                    PostingRow(session: session)
                }
            }
        }
    }
}

// MARK: - Activity types

enum ActivityMetric: String, CaseIterable, Hashable {
    case duration = "Duration"
    case sessions = "Sessions"
}

enum ActivityRange: String, CaseIterable, Identifiable {
    case month = "Last month"
    case threeMonths = "Last 3 months"
    case sixMonths = "Last 6 months"
    case year = "Last year"

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .month: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .year: return 365
        }
    }
}

struct ActivityBucket: Identifiable {
    let id = UUID()
    let weekStart: Date
    var hours: Double
    var sessions: Int

    static func weekly(sessions: [FeedSession], range: ActivityRange) -> [ActivityBucket] {
        let cal = Calendar.current
        let now = Date()
        guard let start = cal.date(byAdding: .day, value: -range.days, to: now) else { return [] }
        var map: [Date: ActivityBucket] = [:]
        var cursor = cal.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        while cursor <= now {
            map[cursor] = ActivityBucket(weekStart: cursor, hours: 0, sessions: 0)
            cursor = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) ?? now.addingTimeInterval(1)
        }
        for s in sessions where s.date >= start {
            let wk = cal.dateInterval(of: .weekOfYear, for: s.date)?.start ?? start
            var b = map[wk] ?? ActivityBucket(weekStart: wk, hours: 0, sessions: 0)
            b.hours += Double(s.durationMinutes) / 60
            b.sessions += 1
            map[wk] = b
        }
        return map.values.sorted { $0.weekStart < $1.weekStart }
    }
}

// MARK: - Small components

struct ProfileStat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary)
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
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct PostingRow: View {
    var session: FeedSession

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.pickleball")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(session.durationMinutes) min · \(session.location ?? "—")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(session.date.relativeLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .cardStyle()
    }
}

struct FollowRequestRow: View {
    @EnvironmentObject private var store: AppStore
    var request: FollowRequest

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatar(profile: request.follower, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(request.follower?.displayName ?? "Player")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(request.follower.map { "@\($0.username)" } ?? "Wants to follow you")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                Task { await store.respondToFollowRequest(request, accept: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await store.respondToFollowRequest(request, accept: true) }
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }
}

enum ProfileSheet: String, Identifiable {
    case stats, gear, measures
    var id: String { rawValue }
}
