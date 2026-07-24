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
        if matches == 0 { return "\(sessions) session\(sessions == 1 ? "" : "s") in — keep the streak alive." }
        if wins > losses { return "Winning week — \(wins)–\(losses) across \(matches) matches." }
        if wins == losses { return "Even week — \(wins)–\(losses). Settle it next time." }
        return "Tough week — \(wins)–\(losses). Bounce back next session."
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

/// Profile entry point for the weekly wrap. Locked for free users (opens the
/// paywall); Pro users tap into the full recap sheet.
struct WeeklyWrapCard: View {
    let wrap: WeekWrap
    let locked: Bool
    var onUnlock: () -> Void = {}
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            if locked { onUnlock() } else { onOpen() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("This week, wrapped")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if locked { ProLockBadge() }
                    }
                    Text("\(wrap.sessions) session\(wrap.sessions == 1 ? "" : "s") · \(wrap.matches) match\(wrap.matches == 1 ? "" : "es")")
                        .font(.subheadline)
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
}

struct WeeklyWrapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var shareItem: ShareImage?

    private var wrap: WeekWrap {
        WeekWrap(allSessions: store.mySessions, playerID: store.currentProfile?.id)
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                let w = wrap
                VStack(spacing: 20) {
                    header(w)
                    tiles(w)
                    if w.weeklyStreak > 0 { streakCard(w) }
                    if let rival = w.hotRival { rivalCard(rival) }
                    shareButton(w)
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("This week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(item: $shareItem) { ActivityShareSheet(payload: $0) }
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
            Text("WEEK OF \(w.weekStart.formatted(.dateTime.month(.abbreviated).day()))".uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Text(w.headline)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func tiles(_ w: WeekWrap) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatPill(title: "Sessions", value: "\(w.sessions)", systemImage: "figure.pickleball")
                StatPill(title: "Hours", value: String(format: "%.1f", w.hours), systemImage: "clock")
            }
            HStack(spacing: 12) {
                StatPill(title: "Record", value: "\(w.wins)–\(w.losses)", systemImage: "flag.checkered")
                StatPill(title: "Win rate", value: "\(w.winRate)%", systemImage: "chart.line.uptrend.xyaxis")
            }
        }
    }

    private func streakCard(_ w: WeekWrap) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(w.weeklyStreak)-week streak")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Log a session next week to keep it going.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .cardStyle()
    }

    private func rivalCard(_ rival: Rivalry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Watch out for", systemImage: "flame.fill")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HeatingUpRow(rivalry: rival)
                .padding(.vertical, 4)
        }
        .cardStyle()
    }
}
