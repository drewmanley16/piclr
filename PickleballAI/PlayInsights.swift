import Foundation

/// One win/loss split along some dimension (a court, a time of day, …).
struct SplitRecord: Identifiable {
    let id: String
    let label: String
    var wins: Int
    var losses: Int

    var games: Int { wins + losses }
    var winRate: Int { games == 0 ? 0 : Int((Double(wins) / Double(games) * 100).rounded()) }
    var recordLine: String { "\(wins)–\(losses)" }
    var leading: Bool { wins >= losses }
}

/// Close-game / margin performance derived from final match scores.
struct ClutchStats {
    /// Wins / losses in matches decided by 2 points or fewer.
    let closeWins: Int
    let closeLosses: Int
    /// Signed mean point differential across all decided (non-tie) matches.
    let avgMargin: Double
    /// Count of decided matches the stats are built from.
    let decidedMatches: Int

    var closeGames: Int { closeWins + closeLosses }
    var closeRecord: String { "\(closeWins)–\(closeLosses)" }
    var closeWinRate: Int { closeGames == 0 ? 0 : Int((Double(closeWins) / Double(closeGames) * 100).rounded()) }
    var avgMarginLabel: String {
        let sign = avgMargin >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.1f", abs(avgMargin)))"
    }
    var hasData: Bool { decidedMatches > 0 }
}

/// One line in the Insights card. Plain data (no SwiftUI) so the same rows drive
/// both the locked teaser and the unlocked view.
struct InsightRow: Identifiable {
    let id: String
    let icon: String
    let title: String
    /// Shown to Pro users — may reveal specifics (a court name, a time of day).
    let subtitle: String
    /// Shown to free users — deliberately generic so the specifics stay locked.
    let lockedSubtitle: String
    let value: String
    let positive: Bool
}

/// Pro "Insights": deeper cuts on a player's match history — clutch record,
/// point margin, best court, best time of day. Computed client-side from logged
/// sessions, the same way `SessionStats` derives records. See [[SessionStats]].
struct PlayInsights {
    let clutch: ClutchStats
    /// Per-court records, most-played first.
    let courts: [SplitRecord]
    /// Per-time-of-day records, ordered morning → late night.
    let timeOfDay: [SplitRecord]

    init(sessions: [FeedSession], playerID: UUID?) {
        var closeWins = 0, closeLosses = 0, marginSum = 0, decided = 0
        var courtAgg: [String: SplitRecord] = [:]
        var timeAgg: [String: (order: Int, record: SplitRecord)] = [:]
        let cal = Calendar.current

        for session in sessions {
            let activities = playerID.map { session.workoutActivities(for: $0) } ?? session.sortedActivities
            let court = session.postLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bucket = Self.timeBucket(for: session.startedDate, calendar: cal)

            for activity in activities where activity.isMatch {
                // Derive from the score so ties are excluded, and margin is
                // player-relative (positive = the player outscored the opponent).
                guard let result = activity.matchResult, result != .tie,
                      let team = activity.teamScore, let opponent = activity.opponentScore else { continue }
                let won = result == .win
                let margin = team - opponent
                marginSum += margin
                decided += 1

                if abs(margin) <= 2 {
                    if won { closeWins += 1 } else { closeLosses += 1 }
                }

                if let court, !court.isEmpty {
                    var record = courtAgg[court] ?? SplitRecord(id: court, label: court, wins: 0, losses: 0)
                    if won { record.wins += 1 } else { record.losses += 1 }
                    courtAgg[court] = record
                }

                var entry = timeAgg[bucket.label]
                    ?? (bucket.order, SplitRecord(id: bucket.label, label: bucket.label, wins: 0, losses: 0))
                if won { entry.record.wins += 1 } else { entry.record.losses += 1 }
                timeAgg[bucket.label] = entry
            }
        }

        clutch = ClutchStats(
            closeWins: closeWins,
            closeLosses: closeLosses,
            avgMargin: decided == 0 ? 0 : Double(marginSum) / Double(decided),
            decidedMatches: decided
        )
        courts = courtAgg.values.sorted { $0.games != $1.games ? $0.games > $1.games : $0.winRate > $1.winRate }
        timeOfDay = timeAgg.values.sorted { $0.order < $1.order }.map(\.record)
    }

    /// Best court by win rate among courts with at least two games.
    var bestCourt: SplitRecord? { Self.best(among: courts) }
    /// Best time of day by win rate among buckets with at least two games.
    var bestTime: SplitRecord? { Self.best(among: timeOfDay) }

    /// The insight rows worth surfacing, each included only when it has data.
    var rows: [InsightRow] {
        var out: [InsightRow] = []
        if clutch.closeGames > 0 {
            out.append(InsightRow(
                id: "clutch", icon: "scope", title: "Clutch record",
                subtitle: "Games decided by 2 or fewer",
                lockedSubtitle: "Games decided by 2 or fewer",
                value: "\(clutch.closeRecord) · \(clutch.closeWinRate)%",
                positive: clutch.closeWinRate >= 50))
        }
        if clutch.hasData {
            out.append(InsightRow(
                id: "margin", icon: "plusminus.circle", title: "Point margin",
                subtitle: "Average per game", lockedSubtitle: "Average per game",
                value: clutch.avgMarginLabel, positive: clutch.avgMargin >= 0))
        }
        if let court = bestCourt {
            out.append(InsightRow(
                id: "court", icon: "mappin.and.ellipse", title: "Best court",
                subtitle: court.label, lockedSubtitle: "Where you win most",
                value: "\(court.recordLine) · \(court.winRate)%", positive: court.leading))
        }
        if let time = bestTime {
            out.append(InsightRow(
                id: "time", icon: "clock", title: "Best time",
                subtitle: time.label, lockedSubtitle: "When you win most",
                value: "\(time.recordLine) · \(time.winRate)%", positive: time.leading))
        }
        return out
    }

    /// Enough decided matches to say something meaningful, and at least one row.
    var isReady: Bool { clutch.decidedMatches >= 4 && !rows.isEmpty }

    private static func best(among records: [SplitRecord]) -> SplitRecord? {
        records.filter { $0.games >= 2 }.max {
            $0.winRate != $1.winRate ? $0.winRate < $1.winRate : $0.games < $1.games
        }
    }

    private static func timeBucket(for date: Date, calendar: Calendar) -> (label: String, order: Int) {
        switch calendar.component(.hour, from: date) {
        case 5..<12:  return ("Mornings", 0)
        case 12..<17: return ("Afternoons", 1)
        case 17..<22: return ("Evenings", 2)
        default:      return ("Late night", 3)
        }
    }
}
