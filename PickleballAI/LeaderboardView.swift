import SwiftUI

/// Match window for the crew leaderboard. `.all` is free; `.month`/`.season`
/// are Pro-only filters layered on top of the same free board.
enum LeaderboardPeriod: String, CaseIterable, Identifiable {
    case all, month, season

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:    return "All-time"
        case .month:  return "This month"
        case .season: return "This season"
        }
    }
    /// Only the all-time view is free; narrower windows require Pro.
    var isPro: Bool { self != .all }
}

/// Crew leaderboard: you and everyone you follow, ranked by match record. The
/// thing the onboarding preview promised. Reachable from the Home header and the
/// Profile dashboard.
struct LeaderboardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var loaded = false
    @State private var period: LeaderboardPeriod = .all

    /// Only ranked players (those with matches) compete; winless-so-far crew are
    /// listed quietly below so the board still shows who's in.
    private var ranked: [LeaderboardEntry] { store.leaderboard.filter { $0.matches > 0 } }
    private var unranked: [LeaderboardEntry] { store.leaderboard.filter { $0.matches == 0 } }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    periodPicker
                    if !loaded && store.leaderboard.isEmpty {
                        SkeletonList(rows: 6)
                    } else if ranked.isEmpty && unranked.isEmpty {
                        emptyState
                    } else {
                        if !ranked.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                                    LeaderboardRow(rank: index + 1, entry: entry, isYou: isYou(entry))
                                }
                            }
                            .cardStyle(padding: 8)
                        }

                        if !unranked.isEmpty {
                            Text("NO MATCHES YET")
                                .font(.caption2.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.leading, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(unranked.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                                    LeaderboardRow(rank: nil, entry: entry, isYou: isYou(entry))
                                }
                            }
                            .cardStyle(padding: 8)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Crew Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await store.loadLeaderboard(period: period)
                loaded = true
            }
            .refreshable { await store.loadLeaderboard(period: period) }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 8) {
            ForEach(LeaderboardPeriod.allCases) { option in
                periodChip(option)
            }
            Spacer()
        }
    }

    private func periodChip(_ option: LeaderboardPeriod) -> some View {
        let locked = option.isPro && !subscriptions.isPro
        return Button {
            Haptics.tap()
            if locked {
                subscriptions.presentPaywall(.leaderboard)
            } else {
                period = option
                loaded = false
                Task { await store.loadLeaderboard(period: period); loaded = true }
            }
        } label: {
            HStack(spacing: 4) {
                Text(option.label)
                if locked { Image(systemName: "lock.fill").font(.caption2.weight(.bold)) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(period == option ? Theme.background : (locked ? Theme.textTertiary : Theme.textSecondary))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(period == option ? Theme.accent : Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func isYou(_ entry: LeaderboardEntry) -> Bool {
        entry.userId == store.currentProfile?.id
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("No crew yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Follow players and log matches. Your crew's rankings show up here.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct LeaderboardRow: View {
    let rank: Int?
    let entry: LeaderboardEntry
    var isYou: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            rankBadge
                .frame(width: 28)

            ProfileLink(userId: isYou ? nil : entry.userId) {
                HStack(spacing: 12) {
                    ProfileAvatar(url: entry.avatarURL, initials: entry.initials, size: 40, userId: entry.userId, unlinked: true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(isYou ? "You" : entry.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isYou ? Theme.accent : Theme.textPrimary)
                                .lineLimit(1)
                            ProBadge(isPro: entry.isPro)
                        }
                        Text("@\(entry.username)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.recordLine)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if entry.matches > 0 {
                    Text("\(entry.winRate)% win")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var rankBadge: some View {
        if let rank {
            if rank <= 3 {
                Text("\(rank)")
                    .font(.subheadline.weight(.heavy).monospacedDigit())
                    .foregroundStyle(rank == 1 ? Theme.background : Theme.textPrimary)
                    .frame(width: 26, height: 26)
                    .background(medalColor(rank), in: Circle())
            } else {
                Text("\(rank)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            Image(systemName: "minus")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func medalColor(_ rank: Int) -> Color {
        switch rank {
        case 1:  return Theme.accent
        case 2:  return Theme.surfaceElevated
        default: return Theme.loss.opacity(0.5)
        }
    }
}
