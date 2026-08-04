import SwiftUI

// MARK: - Statistics

struct StatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    private var totalMinutes: Int { store.mySessions.reduce(0) { $0 + $1.workoutDurationMinutes } }
    private var avgMinutes: Int { store.mySessions.isEmpty ? 0 : totalMinutes / store.mySessions.count }
    private var longest: Int { store.mySessions.map(\.workoutDurationMinutes).max() ?? 0 }
    private var stats: SessionStats { SessionStats(sessions: store.mySessions, playerID: store.currentProfile?.id) }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    let s = stats

                    if s.matches > 0 {
                        RecordHero(stats: s)
                        MatchFormatBreakdown(singles: s.singles, doubles: s.doubles)
                    }

                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            StatPill(title: "Total Sessions", value: "\(store.mySessions.count)", systemImage: "figure.pickleball")
                            StatPill(title: "Total Hours", value: String(format: "%.1f", Double(totalMinutes) / 60), systemImage: "clock")
                        }
                        HStack(spacing: 12) {
                            StatPill(title: "Avg Session", value: "\(avgMinutes) min", systemImage: "timer")
                            StatPill(title: "Longest", value: "\(longest) min", systemImage: "flame")
                        }
                        if s.longestWeeklyStreak > 0 {
                            HStack(spacing: 12) {
                                StatPill(title: "Weekly Streak", value: "\(s.weeklyStreak) wk\(s.weeklyStreak == 1 ? "" : "s")", systemImage: "calendar")
                                StatPill(title: "Best Streak", value: "\(s.longestWeeklyStreak) wk\(s.longestWeeklyStreak == 1 ? "" : "s")", systemImage: "trophy.fill")
                            }
                        }
                    }

                    if !s.opponents.isEmpty {
                        RecordSection(title: "Head-to-Head", caption: "vs.", records: s.opponents)
                    }
                    if !s.partners.isEmpty {
                        RecordSection(title: "Partners", caption: "with", records: s.partners)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct MatchFormatBreakdown: View {
    let singles: MatchFormatRecord
    let doubles: MatchFormatRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By format")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 12) {
                FormatRecordCard(record: singles, systemImage: "person.fill")
                FormatRecordCard(record: doubles, systemImage: "person.2.fill")
            }
        }
    }
}

private struct FormatRecordCard: View {
    let record: MatchFormatRecord
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(record.format.title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(record.recordLine)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(record.matches == 0 ? "No matches" : "\(record.winRate)% win rate")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }
}

private struct RecordHero: View {
    let stats: SessionStats

    @ScaledMetric(relativeTo: .largeTitle) private var recordSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var dashSize: CGFloat = 32

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(stats.wins)")
                    .font(.system(size: recordSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text("–")
                    .font(.system(size: dashSize, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(stats.losses)")
                    .font(.system(size: recordSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text("MATCH RECORD")
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                HeroStat(value: "\(stats.winRate)%", label: "Win rate")
                Divider().frame(height: 28).overlay(Theme.hairline)
                HeroStat(value: "\(stats.matches)", label: "Matches")
                Divider().frame(height: 28).overlay(Theme.hairline)
                HeroStat(value: stats.streakLabel, label: "Win streak")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardStyle()
    }
}

private struct HeroStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecordSection: View {
    let title: String
    let caption: String
    let records: [PlayerRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Divider().overlay(Theme.hairline).padding(.leading, 56)
                    }
                    PlayerRecordRow(record: record)
                }
            }
            .cardStyle(padding: 0)
        }
    }
}

private struct PlayerRecordRow: View {
    let record: PlayerRecord

    var body: some View {
        // Plain list row with no enclosing link, so default navigation is
        // correct: members tap through to their profile, guests stay inert.
        IdentityRow(person: record.person, avatarSize: 44) {
            HStack(spacing: 10) {
                if record.person.profileId == nil {
                    GuestInviteButton(guestName: record.person.displayName)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(record.recordLine)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(record.wins >= record.losses ? Theme.accent : Theme.textPrimary)
                    Text("\(record.winRate)%")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
