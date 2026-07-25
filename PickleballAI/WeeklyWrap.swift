import SwiftUI

/// This week's play, summarized. Computed client-side from logged sessions like
/// [[SessionStats]]. Powers the Pro "week in review" card + sheet (and, later,
/// the Sunday weekly-wrap push).
struct WeekWrap {
    let weekStart: Date
    let sessions: Int
    let minutes: Int
    let matches: Int
    let wins: Int
    let losses: Int
    /// Consistency streak (weeks in a row with a session), from all-time data.
    let weeklyStreak: Int
    /// The most notable rival on a run right now, for the recap highlight.
    let hotRival: Rivalry?

    var winRate: Int { (wins + losses) == 0 ? 0 : Int((Double(wins) / Double(wins + losses) * 100).rounded()) }
    var hours: Double { Double(minutes) / 60 }
    var hasData: Bool { sessions > 0 }

    var headline: String {
        if matches == 0 { return "\(sessions) session\(sessions == 1 ? "" : "s") in. Keep the streak alive." }
        if wins > losses { return "Winning week: \(wins)–\(losses) across \(matches) matches." }
        if wins == losses { return "Even week: \(wins)–\(losses). Settle it next time." }
        return "Tough week: \(wins)–\(losses). Bounce back next session."
    }

    /// Headline for free viewers: sells the week's outcome without giving away
    /// the record and win rate blurred right below it.
    var lockedHeadline: String {
        if matches == 0 { return headline }
        if wins > losses { return "A winning week is in the books." }
        if wins == losses { return "A week that came down to the wire." }
        return "A grinder of a week. The full story is inside."
    }

    init(allSessions: [FeedSession], playerID: UUID?) {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday, matching SessionStats.weeklyStreaks
        weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())

        let start = weekStart
        let week = allSessions.filter { $0.workoutDate >= start }
        sessions = week.count
        minutes = week.reduce(0) { $0 + $1.workoutDurationMinutes }

        let weekStats = SessionStats(sessions: week, playerID: playerID)
        matches = weekStats.matches
        wins = weekStats.wins
        losses = weekStats.losses

        let allStats = SessionStats(sessions: allSessions, playerID: playerID)
        weeklyStreak = allStats.weeklyStreak
        hotRival = allStats.heatingUp.first
    }
}

/// Profile entry point for the weekly wrap, set as a mini stat board: this
/// week's numbers are the card. Everyone taps into the recap sheet; free users
/// get the teaser treatment there (see `WeeklyWrapSheet`).
struct WeeklyWrapCard: View {
    let wrap: WeekWrap
    let locked: Bool
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                StatBoardHeader(title: "This week, wrapped", locked: locked)
                CourtLineRule()
                HStack(spacing: 0) {
                    StatSegment(value: "\(wrap.sessions)", label: wrap.sessions == 1 ? "Session" : "Sessions", size: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatSegment(value: "\(wrap.matches)", label: wrap.matches == 1 ? "Match" : "Matches", size: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatSegment(value: String(format: "%.1f", wrap.hours), label: "Hours", size: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

/// The recap sheet, set as a week board: one court-shaped 2×2 card split by
/// chalk lines, sessions and hours real for everyone, record and win rate
/// sealed behind Pro along with the streak and rival cards. The free numbers
/// roll up from zero on open — the sheet's one orchestrated moment.
struct WeeklyWrapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var shareItem: ShareImage?
    /// Drives the board's roll-up on appear. Starts true under Reduce Motion.
    @State private var boardSettled = false

    private var locked: Bool { subscriptions.showsLockedFeatures }

    private var wrap: WeekWrap {
        WeekWrap(allSessions: store.mySessions, playerID: store.currentProfile?.id)
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                let w = wrap
                VStack(spacing: 20) {
                    header(w)
                    board(w)
                    if w.weeklyStreak > 0 { streakCard(w) }
                    if let rival = w.hotRival { rivalCard(rival) }
                    if locked {
                        ProTeaserUnlockBar(
                            context: .weeklyWrap,
                            title: "Unlock your full wrap",
                            caption: w.matches > 0
                                ? "Your record and win rate for this week are in."
                                : "Your streak and full recap are waiting."
                        )
                    } else {
                        shareButton(w)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("This week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(item: $shareItem) { ActivityShareSheet(payload: $0) }
        .trackProTeaser(.weeklyWrap, locked: locked)
        .onAppear {
            if reduceMotion {
                boardSettled = true
            } else {
                withAnimation(.snappy(duration: 0.8).delay(0.15)) { boardSettled = true }
            }
        }
    }

    private func shareButton(_ w: WeekWrap) -> some View {
        Button {
            Haptics.tap()
            guard let image = renderShareImage(for: w) else { return }
            shareItem = ShareImage(image: image, caption: w.headline)
        } label: {
            Label("Share this week", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func header(_ w: WeekWrap) -> some View {
        VStack(spacing: 8) {
            StatLabel("Week of \(w.weekStart.formatted(.dateTime.month(.abbreviated).day()))")
            Text(locked ? w.lockedHeadline : w.headline)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The week as a court: four quadrants split by chalk lines, the heavier
    /// center rule the net. Top half (played) is free; bottom half (results)
    /// is the Pro side.
    private func board(_ w: WeekWrap) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                quadrant(value: "\(boardSettled ? w.sessions : 0)", label: w.sessions == 1 ? "Session" : "Sessions")
                quadrantDivider
                quadrant(value: String(format: "%.1f", boardSettled ? w.hours : 0), label: "Hours")
            }
            CourtLineRule(weight: 2)
            HStack(spacing: 0) {
                quadrant(value: boardSettled ? "\(w.wins)–\(w.losses)" : "0–0", label: "Record",
                         sealed: locked)
                quadrantDivider
                quadrant(value: "\(boardSettled ? w.winRate : 0)%", label: "Win rate",
                         sealed: locked)
            }
        }
        .cardStyle(padding: 0)
    }

    private func quadrant(value: String, label: String, sealed: Bool = false) -> some View {
        StatSegment(value: value, label: label, sealed: sealed, sealedWidth: 56,
                    size: 30, alignment: .center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private var quadrantDivider: some View {
        Rectangle().fill(Theme.courtLine).frame(width: 1)
    }

    private func streakCard(_ w: WeekWrap) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                StatHeading("Weekly streak")
                Text(locked ? "Play every week to keep your run alive." : "Log a session next week to keep it going.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if locked {
                SealedStat(width: 44, size: 22)
            } else {
                Text("\(w.weeklyStreak) wk")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
        }
        .cardStyle()
    }

    /// Free users know a rival is on a run; who it is stays sealed — the name
    /// slot is the tease.
    @ViewBuilder
    private func rivalCard(_ rival: Rivalry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatHeading("Watch out for")
            if locked {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 40, height: 40)
                        .background(Theme.surfaceElevated, in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        SealedStat(width: 110, size: 15, showsLock: false)
                        Text("Someone's on a run against you.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rival locked. Unlock with Pro.")
            } else {
                HeatingUpRow(rivalry: rival)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
