import SwiftUI
import Charts

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    @State private var showFindFriends = false
    @State private var showNotifications = false
    @State private var activeSheet: ProfileSheet?
    @State private var metric: ActivityMetric = .duration

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
                    if !store.incomingFollowRequests.isEmpty { followRequestsBanner }
                    if completion < 1 { completionBanner }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Dashboard").font(.headline).foregroundStyle(Theme.textPrimary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                DashboardTile(icon: "chart.line.uptrend.xyaxis", label: "Statistics") { activeSheet = .stats }
                DashboardTile(icon: "bag.fill", label: "Gear") { activeSheet = .gear }
                DashboardTile(icon: "figure.stand", label: "Measures") { activeSheet = .measures }
            }
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

// MARK: - Workout calendar

struct WorkoutCalendarCard: View {
    let sessions: [FeedSession]
    @State private var monthAnchor = Date()

    private let cal = Calendar.current

    private var workoutDays: Set<Date> {
        Set(sessions.map { cal.startOfDay(for: $0.date) })
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f.string(from: monthAnchor)
    }

    /// Day cells for the anchored month, with leading nils to align weekdays.
    private var cells: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstOfMonth = interval.start
        let daysInMonth = cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        let leading = (cal.component(.weekday, from: firstOfMonth) - cal.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        for d in 0..<daysInMonth {
            result.append(cal.date(byAdding: .day, value: d, to: firstOfMonth))
        }
        return result
    }

    private var weekdaySymbols: [String] {
        let symbols = DateFormatter().veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(monthTitle).font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").foregroundStyle(Theme.textSecondary)
                }
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                }
                .disabled(isCurrentMonth)
                .opacity(isCurrentMonth ? 0.4 : 1)
            }

            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(weekdaySymbols, id: \.self) { s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    DayCell(date: date, worked: date.map { workoutDays.contains(cal.startOfDay(for: $0)) } ?? false,
                            isToday: date.map { cal.isDateInToday($0) } ?? false)
                }
            }

            HStack(spacing: 14) {
                legend(color: Theme.accent, label: "Worked out")
                legend(color: Theme.surfaceElevated, label: "Rest day")
            }
            .padding(.top, 2)
        }
        .cardStyle()
    }

    private var isCurrentMonth: Bool {
        cal.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct DayCell: View {
    let date: Date?
    let worked: Bool
    let isToday: Bool

    var body: some View {
        Group {
            if let date {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.caption.weight(worked ? .bold : .regular))
                    .foregroundStyle(worked ? Theme.background : Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(worked ? Theme.accent : Theme.surfaceElevated, in: Circle())
                    .overlay(Circle().strokeBorder(isToday ? Theme.accent : .clear, lineWidth: 1.5))
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
        }
        .frame(maxWidth: .infinity)
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

struct RepostRequestRow: View {
    @EnvironmentObject private var store: AppStore
    var request: RepostRequest

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(initials: initials)

            VStack(alignment: .leading, spacing: 3) {
                Text(request.requester?.displayName ?? "Player")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("wants to repost \(sessionLabel)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await store.declineRepost(request) }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await store.approveRepost(request) }
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

    private var sessionLabel: String {
        if let title = request.session?.title, !title.isEmpty { return "\"\(title)\"" }
        return "your session"
    }

    private var initials: String {
        if let a = request.requester?.avatarInitials, !a.isEmpty { return a }
        let letters = (request.requester?.displayName ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

enum ProfileSheet: String, Identifiable {
    case stats, gear, measures
    var id: String { rawValue }
}
