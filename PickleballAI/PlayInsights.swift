import Foundation

/// One win/loss split along some dimension (a court, a time of day, a partner…).
struct SplitRecord: Identifiable {
    let id: String
    let label: String
    /// Set for person-based splits (partners) so rows can show an avatar.
    var person: PersonRef?
    var wins: Int
    var losses: Int

    init(id: String, label: String, person: PersonRef? = nil, wins: Int, losses: Int) {
        self.id = id
        self.label = label
        self.person = person
        self.wins = wins
        self.losses = losses
    }

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
/// point margin, best court/time, per-partner records, and first-game form.
/// Computed client-side from logged sessions, the same way `SessionStats`
/// derives records. See [[SessionStats]].
struct PlayInsights {
    let clutch: ClutchStats
    /// Per-court records, most-played first.
    let courts: [SplitRecord]
    /// Per-time-of-day records, ordered morning → late night.
    let timeOfDay: [SplitRecord]
    /// Per-partner records, most-played first.
    let partners: [SplitRecord]
    /// Record in the first decided match of each session (slow-starter signal).
    let firstGames: SplitRecord
    /// Record in every decided match after the first.
    let laterGames: SplitRecord

    init(sessions: [FeedSession], playerID: UUID?) {
        var closeWins = 0, closeLosses = 0, marginSum = 0, decided = 0
        var courtAgg: [String: SplitRecord] = [:]
        var timeAgg: [String: (order: Int, record: SplitRecord)] = [:]
        var partnerAgg: [String: SplitRecord] = [:]
        var firstWins = 0, firstLosses = 0, laterWins = 0, laterLosses = 0
        let cal = Calendar.current

        for session in sessions {
            let activities = playerID.map { session.workoutActivities(for: $0) } ?? session.sortedActivities
            let court = session.postLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bucket = Self.timeBucket(for: session.startedDate, calendar: cal)

            // Decided (non-tie, scored) matches in play order, so "first game" and
            // margins are well defined and ties don't skew win/loss.
            let matches = activities.filter {
                $0.isMatch && $0.teamScore != nil && $0.opponentScore != nil
                    && $0.matchResult != nil && $0.matchResult != .tie
            }.sorted { $0.position < $1.position }

            for (index, activity) in matches.enumerated() {
                let won = activity.matchResult == .win
                let margin = (activity.teamScore ?? 0) - (activity.opponentScore ?? 0)
                marginSum += margin
                decided += 1

                if abs(margin) <= 2 {
                    if won { closeWins += 1 } else { closeLosses += 1 }
                }
                if index == 0 {
                    if won { firstWins += 1 } else { firstLosses += 1 }
                } else {
                    if won { laterWins += 1 } else { laterLosses += 1 }
                }
                if let court, !court.isEmpty {
                    var record = courtAgg[court] ?? SplitRecord(id: court, label: court, wins: 0, losses: 0)
                    if won { record.wins += 1 } else { record.losses += 1 }
                    courtAgg[court] = record
                }
                var timeEntry = timeAgg[bucket.label]
                    ?? (bucket.order, SplitRecord(id: bucket.label, label: bucket.label, wins: 0, losses: 0))
                if won { timeEntry.record.wins += 1 } else { timeEntry.record.losses += 1 }
                timeAgg[bucket.label] = timeEntry

                for partner in activity.partners {
                    let key = Self.key(for: partner)
                    var record = partnerAgg[key]
                        ?? SplitRecord(id: key, label: partner.displayName, person: Self.person(for: partner), wins: 0, losses: 0)
                    if won { record.wins += 1 } else { record.losses += 1 }
                    partnerAgg[key] = record
                }
            }
        }

        clutch = ClutchStats(
            closeWins: closeWins,
            closeLosses: closeLosses,
            avgMargin: decided == 0 ? 0 : Double(marginSum) / Double(decided),
            decidedMatches: decided
        )
        courts = courtAgg.values.sorted(by: Self.byGamesThenRate)
        timeOfDay = timeAgg.values.sorted { $0.order < $1.order }.map(\.record)
        partners = partnerAgg.values.sorted(by: Self.byGamesThenRate)
        firstGames = SplitRecord(id: "first", label: "First game of a session", wins: firstWins, losses: firstLosses)
        laterGames = SplitRecord(id: "later", label: "After warming up", wins: laterWins, losses: laterLosses)
    }

    /// Best court by win rate among courts with at least two games.
    var bestCourt: SplitRecord? { Self.best(among: courts) }
    /// Best time of day by win rate among buckets with at least two games.
    var bestTime: SplitRecord? { Self.best(among: timeOfDay) }
    /// Highest-win-rate partner with at least two games together.
    var bestPartner: SplitRecord? { Self.best(among: partners) }

    /// The teaser rows for the profile card, each included only when it has data.
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
        if let partner = bestPartner {
            out.append(InsightRow(
                id: "partner", icon: "person.2.fill", title: "Best partner",
                subtitle: partner.label, lockedSubtitle: "Who you win most with",
                value: "\(partner.recordLine) · \(partner.winRate)%", positive: partner.leading))
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

    private static func byGamesThenRate(_ lhs: SplitRecord, _ rhs: SplitRecord) -> Bool {
        lhs.games != rhs.games ? lhs.games > rhs.games : lhs.winRate > rhs.winRate
    }

    private static func key(for participant: ActivityParticipant) -> String {
        participant.profile?.id.uuidString ?? "guest:\(participant.guestName ?? participant.id.uuidString)"
    }

    private static func person(for participant: ActivityParticipant) -> PersonRef {
        if let profile = participant.profile { return PersonRef(participant: profile) }
        return PersonRef(guestName: participant.displayName)
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
