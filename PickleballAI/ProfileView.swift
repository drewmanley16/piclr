import SwiftUI
import Charts
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showSettings = false
    @State private var showFindFriends = false
    @State private var showNotifications = false
    @State private var activeSheet: ProfileSheet?
    @State private var metric: ActivityMetric = .duration
    @State private var range: HistoryRange = .week
    @State private var showCustomRange = false
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @State private var isUpdatingProfilePhoto = false
    @State private var profilePhotoError: String?
    @AppStorage("dismissedProfileCompletion") private var dismissedCompletion = false

    private var profile: Profile? { store.currentProfile }

    private var shareText: String {
        guard let profile else { return "Find me on pickleball.ai" }
        return "Add @\(profile.username) on pickleball.ai\n\n\(store.myProfileLink.absoluteString)"
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileRow
                    if !store.incomingFollowRequests.isEmpty { followRequestsBanner }
                    if subscriptions.showsLockedFeatures { proBanner }
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
                AppHeader(title: profile?.username ?? "Profile", titleFont: .title2.weight(.bold)) {
                    HeaderPill {
                        streakBadge
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
            .alert("Couldn't update photo", isPresented: profilePhotoErrorBinding) {
                Button("OK", role: .cancel) { profilePhotoError = nil }
            } message: {
                Text(profilePhotoError ?? "Please try again.")
            }
            .onChange(of: selectedProfilePhoto) { _, item in
                guard let item else { return }
                Haptics.tap()
                Task { await updateProfilePhoto(from: item) }
            }
        }
    }

    // MARK: Profile row

    private var profileRow: some View {
        let showsProStatus = subscriptions.showsProStatus
        return HStack(spacing: 20) {
            PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                ZStack {
                    ProfileAvatar(profile: profile, size: 76, unlinked: true)
                        .opacity(isUpdatingProfilePhoto ? 0.48 : 1)

                    if isUpdatingProfilePhoto {
                        ProgressView()
                            .tint(Theme.accent)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showsProStatus {
                        ProStatusBadge().offset(y: 5)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isUpdatingProfilePhoto)
            .accessibilityLabel(isUpdatingProfilePhoto ? "Updating profile photo" : "Change profile photo")
            .accessibilityHint("Opens your photo library")

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

    private var profilePhotoErrorBinding: Binding<Bool> {
        Binding(
            get: { profilePhotoError != nil },
            set: { isPresented in
                if !isPresented { profilePhotoError = nil }
            }
        )
    }

    private func updateProfilePhoto(from item: PhotosPickerItem) async {
        isUpdatingProfilePhoto = true
        defer {
            isUpdatingProfilePhoto = false
            selectedProfilePhoto = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                profilePhotoError = "That photo couldn't be read. Choose another image and try again."
                Haptics.warning()
                return
            }

            guard await store.uploadProfilePhoto(data) else {
                profilePhotoError = store.errorMessage ?? "The photo couldn't be uploaded. Please try again."
                store.errorMessage = nil
                Haptics.warning()
                return
            }

            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            profilePhotoError = "That photo couldn't be read. Choose another image and try again."
            Haptics.warning()
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

    // MARK: Pro upsell

    private var proBanner: some View {
        Button {
            subscriptions.presentPaywall(.general)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bolt.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("pickleball.ai")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("PRO")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                    Text("AI recaps, rivalry insights, and more")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
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

    /// Consistency-streak indicator that sits inside the header pill alongside the
    /// action icons. Only appears once there's an active streak (no clutter at zero).
    @ViewBuilder
    private var streakBadge: some View {
        let weeks = stats.weeklyStreak
        if weeks > 0 {
            HStack(spacing: 3) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.body.weight(.bold))
                Text("\(weeks)")
                    .font(.headline.weight(.heavy))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.accent)
            .fixedSize()
            .accessibilityLabel("\(weeks) week streak")
        }
    }

    // MARK: Record

    private var stats: SessionStats { SessionStats(sessions: store.mySessions, playerID: store.currentProfile?.id) }

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
                    RivalRow(rivalry: top, emphasized: true, unlinked: true, showsInvite: false)
                }
                .cardStyle()
            }
            .buttonStyle(.plain)
            // The card only renders once a real rivalry exists (games >= 2), so
            // its first appearance is the natural "user has a rival" milestone.
            // Guarded to fire exactly once per user per device.
            .onAppear { Analytics.captureOnce(.firstRivalSeen, flag: .firstRivalSeen) }
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
        ActivityBucket.series(for: range, sessions: store.mySessions)
    }

    /// Headline total for the selected range: hours or sessions across its span.
    private var rangeValue: (String, String) {
        let (start, end) = range.interval
        let endExclusive = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
        let mine = store.mySessions.filter { $0.date >= start && $0.date < endExclusive }
        switch metric {
        case .duration:
            let hrs = Double(mine.reduce(0) { $0 + $1.durationMinutes }) / 60
            return (String(format: "%.1f", hrs), "hours")
        case .sessions:
            return ("\(mine.count)", mine.count == 1 ? "session" : "sessions")
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(rangeValue.0).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                + Text("  \(rangeValue.1)").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(range.caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            rangeSelector

            Chart(buckets) { b in
                BarMark(
                    x: .value("Period", b.day, unit: chartUnit),
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
                AxisMarks { _ in
                    AxisValueLabel(format: xAxisFormat).foregroundStyle(Theme.textTertiary)
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
        .sheet(isPresented: $showCustomRange) {
            CustomRangeSheet(start: $customStart, end: $customEnd) {
                range = .custom(start: customStart, end: customEnd)
            }
        }
    }

    private var chartUnit: Calendar.Component {
        switch range.granularity {
        case .month: return .month
        case .weekOfYear: return .weekOfYear
        default: return .day
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch range.granularity {
        case .month:      return .dateTime.month(.narrow)
        case .weekOfYear: return .dateTime.month(.abbreviated).day()
        default:          return .dateTime.weekday(.narrow)
        }
    }

    /// Range chips. Hidden entirely when monetization is off (App Store build),
    /// so the chart quietly stays on the free week view there. When on, Pro ranges
    /// show a lock for non-Pro users and open the paywall on tap.
    @ViewBuilder
    private var rangeSelector: some View {
        if subscriptions.monetizationEnabled {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HistoryRange.presets) { preset in
                        rangeChip(label: preset.shortLabel, locked: preset.isPro && !subscriptions.isPro,
                                  selected: range == preset) {
                            if preset.isPro && !subscriptions.isPro {
                                subscriptions.presentPaywall(.unlimitedHistory)
                            } else {
                                withAnimation(.snappy(duration: 0.2)) { range = preset }
                            }
                        }
                    }
                    rangeChip(label: "Custom", locked: !subscriptions.isPro, selected: isCustom) {
                        if !subscriptions.isPro {
                            subscriptions.presentPaywall(.unlimitedHistory)
                        } else {
                            showCustomRange = true
                        }
                    }
                }
            }
        }
    }

    private var isCustom: Bool {
        if case .custom = range { return true }
        return false
    }

    private func rangeChip(label: String, locked: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Theme.background : (locked ? Theme.textTertiary : Theme.textSecondary))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(selected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
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

/// A selectable window for the activity chart. Only `.week` is free; everything
/// longer (and the custom range) is a Pro feature.
enum HistoryRange: Hashable, Identifiable {
    case week, twoWeeks, month, threeMonths, year
    case custom(start: Date, end: Date)

    var id: String { shortLabel }

    /// The fixed presets shown as chips (custom is added via its own control).
    static let presets: [HistoryRange] = [.week, .twoWeeks, .month, .threeMonths, .year]

    var shortLabel: String {
        switch self {
        case .week:        return "1W"
        case .twoWeeks:    return "2W"
        case .month:       return "1M"
        case .threeMonths: return "3M"
        case .year:        return "1Y"
        case .custom:      return "Custom"
        }
    }

    /// Header caption for the chart ("Last 7 days", "Last 3 months", …).
    var caption: String {
        switch self {
        case .week:        return "Last 7 days"
        case .twoWeeks:    return "Last 2 weeks"
        case .month:       return "Last 30 days"
        case .threeMonths: return "Last 3 months"
        case .year:        return "Last 12 months"
        case .custom:      return "Custom range"
        }
    }

    /// Only the week view is free; the rest require Pro.
    var isPro: Bool {
        if case .week = self { return false }
        return true
    }

    /// Inclusive [start, end] the window covers, ending today (or the custom end).
    var interval: (start: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func daysBack(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today) ?? today }
        switch self {
        case .week:        return (daysBack(6), today)
        case .twoWeeks:    return (daysBack(13), today)
        case .month:       return (daysBack(29), today)
        case .threeMonths: return (cal.date(byAdding: .month, value: -3, to: today) ?? today, today)
        case .year:        return (cal.date(byAdding: .year, value: -1, to: today) ?? today, today)
        case .custom(let s, let e):
            return (cal.startOfDay(for: min(s, e)), cal.startOfDay(for: max(s, e)))
        }
    }

    /// Bucket granularity that keeps the bar count readable for the span.
    var granularity: Calendar.Component {
        switch self {
        case .week, .twoWeeks, .month: return .day
        case .threeMonths:             return .weekOfYear
        case .year:                    return .month
        case .custom(let s, let e):
            let days = Calendar.current.dateComponents([.day], from: min(s, e), to: max(s, e)).day ?? 0
            if days <= 31 { return .day }
            if days <= 120 { return .weekOfYear }
            return .month
        }
    }
}

struct ActivityBucket: Identifiable {
    let id = UUID()
    let day: Date
    var hours: Double
    var sessions: Int

    /// Buckets for an arbitrary range, one per unit of the range's granularity
    /// (day / week / month), oldest → newest, with empty buckets filled in so the
    /// chart baseline stays continuous.
    static func series(for range: HistoryRange, sessions: [FeedSession]) -> [ActivityBucket] {
        let cal = Calendar.current
        let unit = range.granularity
        let (start, end) = range.interval
        let startBucket = bucketStart(start, unit: unit, cal: cal)

        // Seed every empty bucket across the span.
        var map: [Date: ActivityBucket] = [:]
        var order: [Date] = []
        var cursor = startBucket
        while cursor <= end {
            if map[cursor] == nil { map[cursor] = ActivityBucket(day: cursor, hours: 0, sessions: 0); order.append(cursor) }
            guard let next = cal.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = next
        }

        for s in sessions {
            let d = s.date
            // Clip to the range itself, not the (earlier) aligned first bucket,
            // so the chart total always matches the headline number.
            guard d >= start, d <= cal.date(byAdding: .day, value: 1, to: end) ?? end else { continue }
            let key = bucketStart(d, unit: unit, cal: cal)
            guard map[key] != nil else { continue }
            map[key]!.hours += Double(s.durationMinutes) / 60
            map[key]!.sessions += 1
        }
        return order.compactMap { map[$0] }
    }

    /// One bucket per day for the last 7 days — kept for callers that want the
    /// free default without constructing a range.
    static func lastWeekDaily(sessions: [FeedSession]) -> [ActivityBucket] {
        series(for: .week, sessions: sessions)
    }

    private static func bucketStart(_ date: Date, unit: Calendar.Component, cal: Calendar) -> Date {
        switch unit {
        case .day:
            return cal.startOfDay(for: date)
        case .weekOfYear:
            return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
        case .month:
            return cal.dateInterval(of: .month, for: date)?.start ?? cal.startOfDay(for: date)
        default:
            return cal.startOfDay(for: date)
        }
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

/// Pro custom date-range picker for the activity chart.
struct CustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var start: Date
    @Binding var end: Date
    var onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Range") {
                    DatePicker("Start", selection: $start, in: ...end, displayedComponents: .date)
                    DatePicker("End", selection: $end, in: start...Date(), displayedComponents: .date)
                }
                Section {
                    Button {
                        onApply()
                        dismiss()
                    } label: {
                        Text("Apply")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .listRowBackground(Theme.accent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .tint(Theme.accent)
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

enum ProfileSheet: String, Identifiable {
    case stats, gear, measures, rivals, leaderboard
    var id: String { rawValue }
}
