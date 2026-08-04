import SwiftUI
import Charts
import PhotosUI

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var subscriptions: SubscriptionStore
    /// Bumped by RootView when the Profile tab is re-tapped; pops to root.
    var reselectSignal: Int = 0
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
        guard let profile else { return "Find me on piclr" }
        return "Add @\(profile.username) on piclr\n\n\(store.myProfileLink.absoluteString)"
    }

    var body: some View {
        ProfileNavigationStack(reselectSignal: reselectSignal) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileRow
                    if !store.incomingFollowRequests.isEmpty { followRequestsBanner }
                    // Once real locked numbers render in the Insights card, it's the
                    // better ad — the standalone banner alongside it is redundant noise.
                    if subscriptions.showsLockedFeatures && !playInsights.isReady { proBanner }
                    if completion < 1 && !dismissedCompletion { completionBanner }
                    GearShowcaseRow(
                        items: store.gear,
                        isHidden: profile?.gearVisible == false
                    ) { activeSheet = .gear }
                    recordCard
                    rivalsCard
                    insightsCard
                    weeklyWrapCard
                    milestonesCard
                    activityCard
                    WorkoutCalendarCard(sessions: store.mySessions)
                    dashboard
                    goalsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await refresh() }
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
                case .weight: WeightSheet()
                case .rivals: RivalsSheet()
                case .insights: InsightsSheet()
                case .weeklyWrap: WeeklyWrapSheet()
                case .goals: GoalsSheet(sessionsThisWeek: sessionsThisWeek, weeklyStreak: stats.weeklyStreak)
                case .leaderboard: LeaderboardSheet()
                case .milestones: MilestonesSheet()
                case .editProfile: EditProfileSheet()
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
            .task {
                // Teasers on the locked cards need real counts even for free
                // users, so load regardless of Pro status (just not when
                // monetization is off entirely and the cards never render).
                guard subscriptions.monetizationEnabled else { return }
                await store.loadMilestoneUnlocks()
            }
        }
    }

    /// Pull-to-refresh: re-fetches everything on-screen that's server-backed.
    /// (Rivals/insights/weekly-wrap/records are computed client-side from
    /// `mySessions`, so refreshing that covers them too.)
    private func refresh() async {
        guard let uid = profile?.id else { return }
        async let profileLoad: AppStore.ProfileLoad = store.loadProfile(userId: uid)
        async let sessions: Void = store.loadMySessions(userId: uid)
        async let gear: Void = store.loadGear(userId: uid)
        _ = await (profileLoad, sessions, gear)
        if subscriptions.monetizationEnabled {
            await store.loadMilestoneUnlocks()
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
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                profilePhotoError = "That photo couldn't be read. Choose another image and try again."
                Haptics.warning()
                return
            }

            guard await store.uploadProfilePhoto(image) else {
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
                        Text("piclr")
                            .font(.subheadline.weight(.heavy))
                            .tracking(-0.4)
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
    /// photo) count toward "finished" — weight is an optional extra and was
    /// nagging users forever.
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
        // Keep the CTA on the leading edge: a trailing arrow sat a few points
        // from the ✕, and aiming for it dismissed the banner for good instead.
        HStack(spacing: 20) {
            Button {
                Haptics.tap()
                activeSheet = .editProfile
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your profile is \(Int(completion * 100))% finished")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Add your court, rating, side, and photo")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 4) {
                        Text("Finish setup")
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                withAnimation(.snappy) { dismissedCompletion = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceElevated, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
                Image(systemName: "bolt.fill")
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

    // MARK: Insights (Pro)

    /// Locked-but-visible Pro insights. Hidden entirely when monetization is off
    /// (Release) via `showsLockedFeatures`/`showsProStatus`, and only once there
    /// are enough decided matches to say something (`isReady`).
    private var playInsights: PlayInsights {
        PlayInsights(sessions: store.mySessions, playerID: profile?.id)
    }

    @ViewBuilder
    private var insightsCard: some View {
        if subscriptions.showsLockedFeatures || subscriptions.showsProStatus {
            let insights = playInsights
            if insights.isReady {
                InsightsCard(
                    insights: insights,
                    locked: subscriptions.showsLockedFeatures,
                    onOpen: { activeSheet = .insights }
                )
            }
        }
    }

    /// Pro "week in review" card — hidden in Release until monetization is on,
    /// and only when there's a session logged this week.
    @ViewBuilder
    private var weeklyWrapCard: some View {
        if subscriptions.showsLockedFeatures || subscriptions.showsProStatus {
            let wrap = WeekWrap(allSessions: store.mySessions, playerID: profile?.id)
            if wrap.hasData {
                WeeklyWrapCard(
                    wrap: wrap,
                    locked: subscriptions.showsLockedFeatures,
                    onOpen: { activeSheet = .weeklyWrap }
                )
            }
        }
    }

    /// Pro achievement shelf — hidden in Release until monetization is on.
    @ViewBuilder
    private var milestonesCard: some View {
        if subscriptions.showsLockedFeatures || subscriptions.showsProStatus {
            // Free users "own" only the starter badges; the rest they've earned
            // count as sealed — the card advertises exactly that split.
            let locked = subscriptions.showsLockedFeatures
            let earnedLocked = locked ? store.milestoneUnlocks.subtracting(Milestone.freeIDs).count : 0
            MilestonesCard(
                unlockedCount: store.milestoneUnlocks.count - earnedLocked,
                locked: locked,
                earnedLockedCount: earnedLocked,
                onOpen: { activeSheet = .milestones }
            )
        }
    }

    /// Weekly-goal + streak-save card. Free for everyone.
    private var goalsCard: some View {
        GoalsCard(
            sessionsThisWeek: sessionsThisWeek,
            weeklyStreak: stats.weeklyStreak,
            onOpen: { activeSheet = .goals }
        )
    }

    /// Sessions logged in the current (Monday-based) week — for the goal card.
    private var sessionsThisWeek: Int {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return store.mySessions.filter { $0.workoutDate >= start }.count
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
            let totalMinutes = mine.reduce(0) { $0 + $1.durationMinutes }
            if usesMinutes {
                return ("\(totalMinutes)", "min")
            }
            let hrs = Double(totalMinutes) / 60
            return (String(format: "%.1f", hrs), "hours")
        case .sessions:
            return ("\(mine.count)", mine.count == 1 ? "session" : "sessions")
        }
    }

    /// When the largest bucket in the selected range is under an hour, minutes
    /// read far better than fractional hours (e.g. "18 min" vs "0.3 hours"),
    /// and the y-axis gets whole-number gridlines (5/10/15) instead of 0.1/0.2/0.3.
    private var usesMinutes: Bool {
        (buckets.map(\.hours).max() ?? 0) < 1
    }

    /// A free user has a Pro range selected: the chart renders their real data
    /// blurred behind an unlock overlay — the tease *is* the chart.
    private var rangeIsSealed: Bool {
        range.isPro && subscriptions.showsLockedFeatures
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                (Text(rangeValue.0).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                + Text("  \(rangeValue.1)").font(.subheadline).foregroundStyle(Theme.textSecondary))
                    .proLocked(rangeIsSealed)
                Spacer()
                Text(range.caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            rangeSelector

            Chart(buckets) { b in
                BarMark(
                    x: .value("Period", b.day, unit: chartUnit),
                    y: .value(metric.rawValue, durationBarValue(for: b))
                )
                .foregroundStyle(Theme.accent)
                .cornerRadius(4)
            }
            .proLocked(rangeIsSealed)
            .overlay {
                if rangeIsSealed {
                    Button {
                        subscriptions.presentPaywall(.unlimitedHistory)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open.fill").font(.footnote.weight(.bold))
                            Text("Unlock \(range.caption.lowercased())").font(.subheadline.weight(.bold))
                        }
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                        .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 170)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.textTertiary)
                }
            }
            .chartXAxis {
                if range.granularity == .day, spansAtMostTwoWeeks {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: xAxisFormat).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    AxisMarks { _ in
                        AxisValueLabel(format: xAxisFormat).foregroundStyle(Theme.textTertiary)
                    }
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

    private func durationBarValue(for bucket: ActivityBucket) -> Double {
        guard metric == .duration else { return Double(bucket.sessions) }
        return usesMinutes ? bucket.hours * 60 : bucket.hours
    }

    /// Day-granularity ranges spanning ≤14 days (1W, 2W, short custom ranges)
    /// get every day labeled; 1M and longer keep automatic, decimated marks.
    private var spansAtMostTwoWeeks: Bool {
        let (start, end) = range.interval
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return days <= 14
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
    /// so the chart quietly stays on the free week view there. When on, Pro
    /// ranges still *select* for free users — the chart teases that range
    /// blurred with an unlock overlay (see `rangeIsSealed`) instead of
    /// dead-ending in the paywall.
    @ViewBuilder
    private var rangeSelector: some View {
        if subscriptions.monetizationEnabled {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HistoryRange.presets) { preset in
                        rangeChip(label: preset.shortLabel, locked: preset.isPro && !subscriptions.isPro,
                                  selected: range == preset) {
                            if preset.isPro && !subscriptions.isPro {
                                Analytics.capture(.proTeaserViewed, [Analytics.Property.context: PaywallContext.unlimitedHistory.id])
                            }
                            withAnimation(.snappy(duration: 0.2)) { range = preset }
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
            DashboardTile(icon: "scalemass.fill", label: "Weight") { activeSheet = .weight }
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
    case stats, gear, weight, rivals, leaderboard, insights, weeklyWrap, goals, milestones
    case editProfile
    var id: String { rawValue }
}
